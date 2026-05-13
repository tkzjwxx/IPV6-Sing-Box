#!/bin/bash

# 1. 环境彻底清场 (防干扰)
rm -rf /etc/sing-box/*.json
mkdir -p /etc/sing-box /var/lib/sing-box

# 2. 自动提取非全局 WARP 数据
WARP_CONF="/etc/wireguard/warp.conf"
PK=$(grep "PrivateKey" $WARP_CONF | awk -F' = ' '{print $2}')
V4=$(grep "Address" $WARP_CONF | grep "\." | awk -F' = ' '{print $2}')
V6=$(grep "Address" $WARP_CONF | grep ":" | awk -F' = ' '{print $2}')
RES_VAL=$(grep -i "Reserved" $WARP_CONF | awk -F'=' '{print $2}' | tr -d ' #[]')
[ -z "$RES_VAL" ] && RES="[0,0,0]" || RES="[${RES_VAL}]"

# 3. 剥离交互坑：直接写死你的专属数据
IN_PORT=60001
ARGO_TOKEN="eyJhIjoiMTMwZWI0NmFkMGQzNzdhN2Y3Mjk3MzEzNmZlOGM3ZDIiLCJ0IjoiYzU5NGUyZmYtZmE4NC00MGY5LTg3ZWQtYzJmNzAwMjU3NzMxIiwicyI6Ik9EZG1NREl6WWpjdFpHVTJNUzAwT1dFMUxXRXpZbVl0WXpVMVlqUmpNVFk1Wm1NMCJ9"

# 4. 生成 1.13.x 官方最新版配置 (使用 Endpoints 管理 WireGuard)
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
        "type": "udp",
        "server": "1.1.1.1",
        "detour": "warp-out"
      },
      {
        "tag": "dns_local",
        "type": "local"
      }
    ],
    "rules": [
      { "outbound": "any", "server": "dns_remote" }
    ],
    "strategy": "prefer_ipv6"
  },
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp-out",
      "address": ["$V4", "$V6"],
      "private_key": "$PK",
      "peers": [
        {
          "address": "2606:4700:d0::a29f:c001",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "reserved": $RES
        }
      ],
      "mtu": 1280
    }
  ],
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

# 5. 还原 Sing-box 服务为单文件读取 (-c) 并配置 Argo
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

# 6. 一键自启动拉起
systemctl daemon-reload
systemctl restart sing-box cloudflared

echo "--- 真正的大结局：1.13.x 自检 ---"
/usr/bin/sing-box check -c /etc/sing-box/config.json
systemctl status sing-box --no-pager
