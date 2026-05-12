#!/bin/bash

# 1. 强建目录 (包含服务需要的 Data 目录)
mkdir -p /etc/sing-box
mkdir -p /var/lib/sing-box

# 2. 安装 cloudflared
if [ ! -f "/usr/local/bin/cloudflared" ]; then
    echo "正在安装 cloudflared..."
    ARCH=$(uname -m)
    [ "$ARCH" == "x86_64" ] && ARCH="amd64" || ARCH="arm64"
    wget -O /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH
    chmod +x /usr/local/bin/cloudflared
fi

# 3. 安装 Sing-box
if [ ! -f "/usr/bin/sing-box" ]; then
    echo "正在安装 Sing-box..."
    LAST_VER=$(curl -Ls https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    [ -z "$LAST_VER" ] && LAST_VER="1.13.11"
    ARCH=$(uname -m)
    [ "$ARCH" == "x86_64" ] && ARCH="amd64" || ARCH="arm64"
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

# 5. 交互输入 (直接对齐网页端)
echo "-------------------------------------------------------"
read -p "请输入网页端设置的本地端口 (默认 60001): " IN_PORT
IN_PORT=${IN_PORT:-60001}
read -p "请输入你的 Argo Tunnel Token: " ARGO_TOKEN
read -p "请输入你的 Argo 域名: " ARGO_DOMAIN
echo "-------------------------------------------------------"

# 6. 生成配置 (核心修复：server -> address, server_port -> port)
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
      "local_address": ["$V4", "$V6"],
      "private_key": "$PK",
      "peers": [
        {
          "address": "2606:4700:d0::a29f:c001",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowed_ips": ["0.0.0.0/0", "::/0"]
        }
      ],
      "reserved": $RES,
      "mtu": 1280
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [{ "inbound": "vless-in", "outbound": "warp-out" }],
    "final": "warp-out"
  }
}
EOF

# 7. 配置 cloudflared
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

# 8. 强力重启
systemctl daemon-reload
systemctl enable --now sing-box cloudflared
systemctl restart sing-box cloudflared

# 9. 验收自检 (如果还报错，这行能看到具体是哪行写错了)
/usr/bin/sing-box check -C /etc/sing-box
echo "-------------------------------------------------------"
systemctl status sing-box --no-pager
