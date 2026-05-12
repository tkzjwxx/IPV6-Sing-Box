#!/bin/bash

# 1. 基础环境检查与安装
mkdir -p /etc/sing-box
if [ ! -f "/usr/bin/sing-box" ]; then
    echo "正在安装 Sing-box..."
    bash <(curl -Ls https://raw.githubusercontent.com/SagerNet/sing-box/main/install.sh)
fi

# 2. 自动提取 WARP 核心数据
WARP_CONF="/etc/wireguard/warp.conf"
if [ ! -f "$WARP_CONF" ]; then
    echo "错误：未发现 $WARP_CONF，请先运行 WARP 脚本安装双栈！"
    exit 1
fi

echo "正在提取 WARP 配置..."
PK=$(grep "PrivateKey" $WARP_CONF | awk -F' = ' '{print $2}')
V4=$(grep "Address" $WARP_CONF | grep "172.16" | awk -F' = ' '{print $2}')
V6=$(grep "Address" $WARP_CONF | grep ":" | awk -F' = ' '{print $2}')
# 提取 Reserved，兼容注释掉的情况
RES_RAW=$(grep "Reserved" $WARP_CONF | cut -d "[" -f 2 | cut -d "]" -f 1)
RES="[${RES_RAW}]"

# 3. 交互输入 Argo 变量
read -p "请输入你的 Argo Tunnel Token: " ARGO_TOKEN
read -p "请输入你的 Argo 域名 (例如: hx.abc.com): " ARGO_DOMAIN

# 4. 自动生成 UUID
MY_UUID=$(cat /proc/sys/kernel/random/uuid)

# 5. 生成 Sing-box 配置文件
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

# 6. 设置 Argo Tunnel 服务
echo "正在配置 Argo Tunnel..."
cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=cloudflared
After=network.target

[Service]
TimeoutStartSec=0
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --protocol http2 --edge-ip-version 6 run --token $ARGO_TOKEN
Restart=on-failure
RestartSec=5
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

# 7. 启动服务
systemctl daemon-reload
systemctl enable sing-box cloudflared
systemctl restart sing-box cloudflared

# 8. 输出客户端配置信息
echo "-------------------------------------------------------"
echo "🎉 部署成功！"
echo "UUID: $MY_UUID"
echo "端口: 443 (通过 Argo)"
echo "路径: /vless"
echo "域名: $ARGO_DOMAIN"
echo "传输协议: WebSocket"
echo "-------------------------------------------------------"
systemctl status sing-box --no-pager
