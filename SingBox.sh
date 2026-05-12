#!/bin/bash

# 1. 彻底清理环境 (解决 -C 参数加载旧文件的问题)
rm -rf /etc/sing-box/*
mkdir -p /etc/sing-box /var/lib/sing-box

# 2. 自动提取 WARP 数据
WARP_CONF="/etc/wireguard/warp.conf"
PK=$(grep "PrivateKey" $WARP_CONF | awk -F' = ' '{print $2}')
V4=$(grep "Address" $WARP_CONF | grep "\." | awk -F' = ' '{print $2}')
V6=$(grep "Address" $WARP_CONF | grep ":" | awk -F' = ' '{print $2}')
RES_VAL=$(grep -i "Reserved" $WARP_CONF | awk -F'=' '{print $2}' | tr -d ' #[]')
[ -z "$RES_VAL" ] && RES="[0,0,0]" || RES="[${RES_VAL}]"

# 3. 交互输入
read -p "网页端填的本地端口 (默认 60001): " IN_PORT
IN_PORT=${IN_PORT:-60001}
read -p "Argo Token: " ARGO_TOKEN
read -p "Argo 域名: " ARGO_DOMAIN

# 4. 生成 1.13.x 官方标准配置 (核心修复：DNS 和 WireGuard 结构)
cat <<EOF > /etc/sing-box/config.json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      { "tag": "dns-remote", "address": "https://8.8.8.8/dns-query", "detour": "warp-out" },
      { "tag": "dns-local", "address": "2606:4700:4700::1111", "detour": "direct" }
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

# 5. 配置 cloudflared
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

# 6. 重启服务并执行严格自检
systemctl daemon-reload
systemctl restart sing-box cloudflared

echo "--- 1.13.x 语法自检结果 ---"
/usr/bin/sing-box check -c /etc/sing-box/config.json
echo "-------------------------------------------------------"
systemctl status sing-box --no-pager
