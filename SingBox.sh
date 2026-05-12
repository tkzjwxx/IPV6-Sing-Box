#!/bin/bash

# 1. 强建目录
mkdir -p /etc/sing-box
mkdir -p /var/lib/sing-box

# 2. 自动提取 WARP 数据 (从你安装好的非全局 WARP 中提取)
WARP_CONF="/etc/wireguard/warp.conf"
if [ ! -f "$WARP_CONF" ]; then
    echo "❌ 错误：未发现 $WARP_CONF，说明你还没装 WARP。请先 bash menu.sh 选 3 安装双栈非全局！"
    exit 1
fi

PK=$(grep "PrivateKey" $WARP_CONF | awk -F' = ' '{print $2}')
V4=$(grep "Address" $WARP_CONF | grep "\." | awk -F' = ' '{print $2}')
V6=$(grep "Address" $WARP_CONF | grep ":" | awk -F' = ' '{print $2}')
RES_VAL=$(grep -i "Reserved" $WARP_CONF | awk -F'=' '{print $2}' | tr -d ' #[]')
[ -z "$RES_VAL" ] && RES="[0,0,0]" || RES="[${RES_VAL}]"

# 3. 交互输入
echo "--- 非全局模式配置 ---"
read -p "网页端填的本地端口 (默认 60001): " IN_PORT
IN_PORT=${IN_PORT:-60001}
read -p "Argo Token: " ARGO_TOKEN
read -p "Argo 域名: " ARGO_DOMAIN

# 4. 生成配置 (严格对齐 1.13.11 语法)
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
    "rules": [
      { "inbound": "vless-in", "outbound": "warp-out" }
    ],
    "final": "warp-out"
  }
}
EOF

# 5. 安装/启动服务 (保持 cloudflared 走原生网络)
systemctl stop cloudflared 2>/dev/null
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

echo "--- 验收自检 ---"
/usr/bin/sing-box check -C /etc/sing-box
systemctl status sing-box --no-pager
