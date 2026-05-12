#!/bin/bash

# 1. 强制创建目录
mkdir -p /etc/sing-box

# 2. 安装 cloudflared (如果还没装)
if [ ! -f "/usr/local/bin/cloudflared" ]; then
    echo "正在安装 cloudflared..."
    ARCH=$(uname -m)
    if [ "$ARCH" == "x86_64" ]; then ARCH="amd64"; elif [ "$ARCH" == "aarch64" ]; then ARCH="arm64"; fi
    wget -O /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH
    chmod +x /usr/local/bin/cloudflared
fi

# 3. 安装 Sing-box
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

# 4. 自动提取 WARP 数据
WARP_CONF="/etc/wireguard/warp.conf"
PK=$(grep "PrivateKey" $WARP_CONF | awk -F' = ' '{print $2}')
V4=$(grep "Address" $WARP_CONF | grep "\." | awk -F' = ' '{print $2}')
V6=$(grep "Address" $WARP_CONF | grep ":" | awk -F' = ' '{print $2}')
RES_VAL=$(grep -i "Reserved" $WARP_CONF | awk -F'=' '{print $2}' | tr -d ' #[]')
[ -z "$RES_VAL" ] && RES="[0,0,0]" || RES="[${RES_VAL}]"

# 5. 交互输入
echo "-------------------------------------------------------"
read -p "请输入网页端设置的本地端口 (例如 60001): " IN_PORT
read -p "请输入你的 Argo Tunnel Token: " ARGO_TOKEN
read -p "请输入你的 Argo 域名 (例如 us3.989269.xyz): " ARGO_DOMAIN
echo "-------------------------------------------------------"

# 6. 生成“强制赛道”配置
cat <<EOF > /etc/sing-box/config.json
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "dns-remote", "address": "tls://1.1.1.1", "address_resolver": "dns-local" },
      { "tag": "dns-local", "address": "2001:4860:4860::8888", "detour": "direct" }
    ],
    "strategy": "prefer_ipv6"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $IN_PORT,
      "users": [{ "uuid": "c0f17c8d-1bc7-4df1-b354-f62b818e5175" }],
      "transport": { "type": "ws", "path": "/vless" }
    }
  ],
  "outbounds": [
    {
      "type": "wireguard",
      "tag": "warp-out",
      "server": "2606:4700:d0::a29f:c001",
      "server_port": 2408,
      "local_address": ["$V4", "$V6"],
      "private_key": "$PK",
      "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
      "reserved": $RES,
      "mtu": 1280
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "inbound": "vless-in", "outbound": "warp-out" }
    ],
    "final": "warp-out"
  }
}
EOF

# 7. 配置 cloudflared (强制 http2 和 v6 保证非全局下 Healthy)
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

# 8. 重启并验收
systemctl daemon-reload
systemctl enable --now sing-box cloudflared
systemctl restart sing-box cloudflared

echo "-------------------------------------------------------"
echo "🎉 强制赛道部署成功！"
echo "本地端口: $IN_PORT"
echo "出站规则: vless-in -> warp-out (强制)"
echo "-------------------------------------------------------"
systemctl status sing-box --no-pager
