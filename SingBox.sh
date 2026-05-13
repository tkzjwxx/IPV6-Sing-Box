#!/bin/bash

# ==========================================
# 1. 物理清场
# ==========================================
rm -rf /etc/sing-box/*.json
mkdir -p /etc/sing-box /var/lib/sing-box

# ==========================================
# 2. 提取非全局 WARP 数据
# ==========================================
WARP_CONF="/etc/wireguard/warp.conf"
if [ ! -f "$WARP_CONF" ]; then
    echo "❌ 错误：未发现 $WARP_CONF"
    exit 1
fi

PK=$(grep "PrivateKey" $WARP_CONF | awk -F' = ' '{print $2}')
V4=$(grep "Address" $WARP_CONF | grep "\." | awk -F' = ' '{print $2}')
V6=$(grep "Address" $WARP_CONF | grep ":" | awk -F' = ' '{print $2}')
RES_VAL=$(grep -i "Reserved" $WARP_CONF | awk -F'=' '{print $2}' | tr -d ' #[]')
[ -z "$RES_VAL" ] && RES="[0,0,0]" || RES="[${RES_VAL}]"

# ==========================================
# 3. 参数硬编码 (砍掉 read 交互，防终端错位)
# ==========================================
IN_PORT=60001
ARGO_TOKEN="eyJhIjoiMTMwZWI0NmFkMGQzNzdhN2Y3Mjk3MzEzNmZlOGM3ZDIiLCJ0IjoiYzU5NGUyZmYtZmE4NC00MGY5LTg3ZWQtYzJmNzAwMjU3NzMxIiwicyI6Ik9EZG1NREl6WWpjdFpHVTJNUzAwT1dFMUxXRXpZbVl0WXpVMVlqUmpNVFk1Wm1NMCJ9"

# ==========================================
# 4. 生成 1.13.0+ 官方严格标准配置
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
        "type": "udp",
        "server": "1.1.1.1",
        "detour": "warp-out"
      },
      {
        "tag": "dns_local",
        "type": "udp",
        "server": "2606:4700:4700::1111",
        "detour": "direct"
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
          "reserved": $RES,
          "allowed_ips": ["0.0.0.0/0", "::/0"]
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

# ==========================================
# 5. 重置服务与拉起
# ==========================================
cat <<EOF > /lib/systemd/system/sing-box.service
[Unit]
Description=sing-box service
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

systemctl daemon-reload
systemctl restart sing-box cloudflared

echo "======================================================="
echo "🎉 终极自检开始 (纯血 Endpoints 架构)"
/usr/bin/sing-box check -c /etc/sing-box/config.json

if [ $? -eq 0 ]; then
    echo "✅ 语法校验通过！"
    echo "======================================================="
    systemctl status sing-box --no-pager | grep "Active:"
else
    echo "❌ 语法校验失败！"
fi
