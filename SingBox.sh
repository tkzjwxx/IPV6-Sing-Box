#!/bin/bash

# 1. 基础环境：创建目录并安装基础工具
mkdir -p /etc/sing-box
apt update && apt install -y wget curl tar

# 2. 安装 cloudflared (Argo Tunnel 核心)
if [ ! -f "/usr/local/bin/cloudflared" ]; then
    echo "正在安装 cloudflared..."
    ARCH=$(uname -m)
    if [ "$ARCH" == "x86_64" ]; then ARCH="amd64"; elif [ "$ARCH" == "aarch64" ]; then ARCH="arm64"; fi
    # 针对纯 IPv6 或已挂 WARP 的环境下载
    wget -O /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH
    chmod +x /usr/local/bin/cloudflared
    echo "cloudflared 安装完成！"
fi

# 3. 安装 Sing-box (二进制包安装，最稳)
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

# 4. 自动提取 WARP 配置
WARP_CONF="/etc/wireguard/warp.conf"
if [ ! -f "$WARP_CONF" ]; then
    echo "❌ 错误：未发现 $WARP_CONF，请先运行 WARP 脚本 (选项3) 安装双栈！"
    exit 1
fi

echo "正在提取 WARP 配置..."
PK=$(grep "PrivateKey" $WARP_CONF | awk -F' = ' '{print $2}')
V4=$(grep "Address" $WARP_CONF | grep "\." | awk -F' = ' '{print $2}')
V6=$(grep "Address" $WARP_CONF | grep ":" | awk -F' = ' '{print $2}')
RES_VAL=$(grep -i "Reserved" $WARP_CONF | awk -F'=' '{print $2}' | tr -d ' #[]')
if [ -z "$RES_VAL" ]; then RES="[0,0,0]"; else RES="[${RES_VAL}]"; fi

# 5. 交互输入
echo "-------------------------------------------------------"
read -p "请输入网页端设置的本地端口 (例如 60001): " IN_PORT
read -p "请输入你的 Argo Tunnel Token: " ARGO_TOKEN
read -p "请输入你的 Argo 域名 (例如 us3.989269.xyz): " ARGO_DOMAIN
echo "-------------------------------------------------------"

# 6. 固定 UUID
MY_UUID="c0f17c8d-1bc7-4df1-b354-f62b818e5175"

# 7. 生成 Sing-box 配置 (双栈 WARP + 6优先)
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

# 8. 配置 Argo 服务
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

# 9. 启动并验收
systemctl daemon-reload
systemctl enable --now sing-box cloudflared
systemctl restart sing-box cloudflared

echo "-------------------------------------------------------"
echo "🎉 部署完成！"
echo "Argo 客户端已安装，服务已启动"
echo "对齐端口: $IN_PORT"
echo "UUID: $MY_UUID"
echo "-------------------------------------------------------"
systemctl status cloudflared --no-pager
