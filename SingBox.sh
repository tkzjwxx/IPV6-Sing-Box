#!/bin/bash

# 1. 强制创建目录
mkdir -p /etc/sing-box

# 2. 安装 Sing-box (针对 HAX 纯 IPv6 优化的安装逻辑)
if [ ! -f "/usr/bin/sing-box" ]; then
    echo "正在安装 Sing-box..."
    ARCH=$(uname -m)
    if [ "$ARCH" == "x86_64" ]; then ARCH="amd64"; elif [ "$ARCH" == "aarch64" ]; then ARCH="arm64"; fi
    LAST_VER=$(curl -Ls https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    [ -z "$LAST_VER" ] && LAST_VER="1.13.11"
    wget -O sing-box.deb "https://github.com/SagerNet/sing-box/releases/download/v${LAST_VER}/sing-box_${LAST_VER}_linux_${ARCH}.deb"
    dpkg -i sing-box.deb
    rm -f sing-box.deb
fi

# 3. 自动从系统现有的 WARP 配置中提取数据
WARP_CONF="/etc/wireguard/warp.conf"
if [ ! -f "$WARP_CONF" ]; then
    echo "❌ 错误：未发现 $WARP_CONF，请先运行 WARP 脚本 (选项3) 安装双栈！"
    exit 1
fi

echo "正在提取 WARP 配置数据..."
PK=$(grep "PrivateKey" $WARP_CONF | awk -F' = ' '{print $2}')
V4=$(grep "Address" $WARP_CONF | grep "\." | awk -F' = ' '{print $2}')
V6=$(grep "Address" $WARP_CONF | grep ":" | awk -F' = ' '{print $2}')
RES_VAL=$(grep -i "Reserved" $WARP_CONF | awk -F'=' '{print $2}' | tr -d ' #[]')
if [ -z "$RES_VAL" ]; then RES="[0,0,0]"; else RES="[${RES_VAL}]"; fi

# 4. 关键交互：对齐网页端参数
echo "-------------------------------------------------------"
read -p "请输入你网页端设置的本地端口 (例如 60001): " IN_PORT
read -p "请输入你的 Argo Tunnel Token: " ARGO_TOKEN
read -p "请输入你的 Argo 域名 (例如 us3.989269.xyz): " ARGO_DOMAIN
echo "-------------------------------------------------------"

# 5. 自动生成 UUID (如需指定也可改为 read 输入)
MY_UUID="c0f17c8d-1bc7-4df1-b354-f62b818e5175" # 这里固定为你刚才给的那个

# 6. 生成 Sing-box 配置文件
cat <<EOF > /etc/sing-box/config.json
{
  "log": { "level": "info", "timestamp": true },
  "dns": { "strategy": "prefer_ipv6" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $IN_PORT,
      "users": [{ "uuid": "$MY_UUID" }],
      "transport": { "type": "ws", "path": "/vless" }
    }
  ],
  "outbounds": [
    {
      "type": "wireguard",
      "tag": "warp-out",
      "local_address": ["$V4", "$V6"],
      "private_key": "$PK",
      "peers": [
        {
          "server": "2606:4700:d0::a29f:c001",
          "server_port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "reserved": $RES,
          "allowed_ips": ["0.0.0.0/0", "::/0"]
        }
      ],
      "mtu": 1280
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": { "final": "warp-out" }
}
EOF

# 7. 配置 cloudflared 服务
cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=cloudflared
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --protocol http2 --edge-ip-version 6 run --token $ARGO_TOKEN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 8. 启动并验收
systemctl daemon-reload
systemctl enable --now sing-box cloudflared
systemctl restart sing-box cloudflared

echo "-------------------------------------------------------"
echo "🎉 交付成功！"
echo "本地监听端口: $IN_PORT (已对齐网页端)"
echo "UUID: $MY_UUID"
echo "域名: $ARGO_DOMAIN"
echo "-------------------------------------------------------"
systemctl status sing-box --no-pager
