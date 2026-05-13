#!/bin/bash

# ==========================================
# 1. 环境彻底清理 (防残留旧格式导致 FATAL)
# ==========================================
rm -rf /etc/sing-box/*.json
mkdir -p /etc/sing-box /var/lib/sing-box

# ==========================================
# 2. 提取非全局 WARP 双栈数据
# ==========================================
WARP_CONF="/etc/wireguard/warp.conf"
if [ ! -f "$WARP_CONF" ]; then
    echo "❌ 错误：未发现 $WARP_CONF，请先安装非全局双栈 WARP！"
    exit 1
fi

PK=$(grep "PrivateKey" $WARP_CONF | awk -F' = ' '{print $2}')
V4=$(grep "Address" $WARP_CONF | grep "\." | awk -F' = ' '{print $2}')
V6=$(grep "Address" $WARP_CONF | grep ":" | awk -F' = ' '{print $2}')
RES_VAL=$(grep -i "Reserved" $WARP_CONF | awk -F'=' '{print $2}' | tr -d ' #[]')
[ -z "$RES_VAL" ] && RES="[0,0,0]" || RES="[${RES_VAL}]"

# ==========================================
# 3. 交互确认 (已内置你的专属数据，直接回车即可)
# ==========================================
echo "-------------------------------------------------------"
read -p "本地监听端口 (默认 60001，直接回车): " IN_PORT
IN_PORT=${IN_PORT:-60001}

DEFAULT_TOKEN="eyJhIjoiMTMwZWI0NmFkMGQzNzdhN2Y3Mjk3MzEzNmZlOGM3ZDIiLCJ0IjoiYzU5NGUyZmYtZmE4NC00MGY5LTg3ZWQtYzJmNzAwMjU3NzMxIiwicyI6Ik9EZG1NREl6WWpjdFpHVTJNUzAwT1dFMUxXRXpZbVl0WXpVMVlqUmpNVFk1Wm1NMCJ9"
read -p "Argo Token (已填好，直接回车): " ARGO_TOKEN
ARGO_TOKEN=${ARGO_TOKEN:-$DEFAULT_TOKEN}

DEFAULT_DOMAIN="us3.989269.xyz"
read -p "Argo 域名 (已填好，直接回车): " ARGO_DOMAIN
ARGO_DOMAIN=${ARGO_DOMAIN:-$DEFAULT_DOMAIN}
echo "-------------------------------------------------------"

# ==========================================
# 4. 生成 Sing-box 1.13.x 官方标准语法配置
# ==========================================
cat <<EOF > /etc/sing-box/config.json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "dns_remote",
        "address": "https://1.1.1.1/dns-query",
        "detour": "warp-out"
      },
      {
        "tag": "dns_local",
        "address": "2001:4860:4860::1111",
        "detour": "direct"
      }
    ],
    "rules": [
      { "outbound": "any", "server": "dns_remote" }
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
          "server": "2606:4700:d0::a29f:c001",
          "server_port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "reserved": $RES
        }
      ],
      "mtu": 1280
    },
    { "type": "direct", "tag": "direct" },
    { "type": "dns", "tag": "dns-out" }
  ],
  "route": {
    "rules": [
      { "protocol": "dns", "outbound": "dns-out" },
      { "inbound": "vless-in", "outbound": "warp-out" }
    ],
    "final": "warp-out"
  }
}
EOF

# ==========================================
# 5. 覆盖重写服务守护进程 (强制使用单文件 -c 参数)
# ==========================================
cat <<EOF > /lib/systemd/system/sing-box.service
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run
Restart=on-failure
RestartSec=10
LimitNOFILE=Infinity

[Install]
WantedBy=multi-user.target
EOF

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

# ==========================================
# 6. 重新拉起所有服务
# ==========================================
systemctl daemon-reload
systemctl restart sing-box cloudflared

echo ""
echo "======================================================="
echo "🎉 终极自检开始..."
/usr/bin/sing-box check -c /etc/sing-box/config.json

if [ $? -eq 0 ]; then
    echo "✅ 语法校验通过！"
    echo "======================================================="
    systemctl status sing-box --no-pager | grep "Active:"
else
    echo "❌ 语法校验失败！"
fi
