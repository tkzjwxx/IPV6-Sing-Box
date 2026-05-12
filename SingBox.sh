#!/bin/bash

# 1. 强建目录
mkdir -p /etc/sing-box

# 2. 安装 Sing-box (换成更稳的官方二进制下载逻辑)
if [ ! -f "/usr/bin/sing-box" ]; then
    echo "正在安装 Sing-box..."
    # 自动获取最新版本号并下载 deb 包安装
    LAST_VER=$(curl -Ls "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    ARCH=$(uname -m)
    if [ "$ARCH" == "x86_64" ]; then ARCH="amd64"; elif [ "$ARCH" == "aarch64" ]; then ARCH="arm64"; fi
    
    wget -O sing-box.deb "https://github.com/SagerNet/sing-box/releases/download/v${LAST_VER}/sing-box_${LAST_VER}_linux_${ARCH}.deb"
    dpkg -i sing-box.deb
    rm -f sing-box.deb
fi

# 3. 自动提取 WARP 核心数据 (针对 HAX 环境优化)
WARP_CONF="/etc/wireguard/warp.conf"
if [ ! -f "$WARP_CONF" ]; then
    echo "❌ 错误：未发现 $WARP_CONF，请先运行 WARP 脚本选择选项 3 安装双栈！"
    exit 1
fi

echo "正在提取 WARP 配置..."
# 提取私钥
PK=$(grep "PrivateKey" $WARP_CONF | awk -F' = ' '{print $2}')
# 提取 IPv4 地址
V4=$(grep "Address" $WARP_CONF | grep "\." | awk -F' = ' '{print $2}')
# 提取 IPv6 地址
V6=$(grep "Address" $WARP_CONF | grep ":" | awk -F' = ' '{print $2}')
# 提取 Reserved (处理 # 注释符号并转为 JSON 数组)
RES_VAL=$(grep -i "Reserved" $WARP_CONF | awk -F'=' '{print $2}' | tr -d ' #[]')
RES="[${RES_VAL}]"

# 4. 交互输入 Argo 变量
read -p "请输入你的 Argo Tunnel Token: " ARGO_TOKEN
read -p "请输入你的 Argo 域名 (例如: hx.abc.com): " ARGO_DOMAIN

# 5. 自动生成 UUID
MY_UUID=$(cat /proc/sys/kernel/random/uuid)

# 6. 生成 Sing-box 配置文件 (双栈 WARP + 6优先)
cat <<EOF > /etc/sing-box/config.json
{
  "log": { "level": "info", "timestamp": true },
  "dns": { "strategy": "prefer_ipv6" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": 60001,
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

# 7. 配置并启动 Argo Tunnel
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

systemctl daemon-reload
systemctl enable --now sing-box cloudflared
systemctl restart sing-box cloudflared

echo "-------------------------------------------------------"
echo "🎉 部署成功！"
echo "UUID: $MY_UUID"
echo "域名: $ARGO_DOMAIN"
echo "路径: /vless"
echo "-------------------------------------------------------"
systemctl status sing-box --no-pager
