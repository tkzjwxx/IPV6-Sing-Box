#!/bin/bash
clear
echo "======================================================="
echo "🚀 Sing-box 1.13.x + Argo + WARP 纯净自动化部署脚本"
echo "======================================================="

# ==========================================
# 1. 检查并提取 WARP 数据
# ==========================================
WARP_CONF="/etc/wireguard/warp.conf"
if [ ! -f "$WARP_CONF" ]; then
    echo "❌ 致命错误：未发现 $WARP_CONF"
    echo "💡 请先确保你已经安装了非全局版的双栈 WARP！"
    exit 1
fi

echo "✅ 正在提取 WARP 配置数据..."
PK=$(grep "PrivateKey" $WARP_CONF | awk -F' = ' '{print $2}')
V4=$(grep "Address" $WARP_CONF | grep "\." | awk -F' = ' '{print $2}')
V6=$(grep "Address" $WARP_CONF | grep ":" | awk -F' = ' '{print $2}')
RES_VAL=$(grep -i "Reserved" $WARP_CONF | awk -F'=' '{print $2}' | tr -d ' #[]')
[ -z "$RES_VAL" ] && RES="[0,0,0]" || RES="[${RES_VAL}]"

# ==========================================
# 2. 自动安装依赖 (Sing-box & Cloudflared)
# ==========================================
ARCH=$(uname -m)
[ "$ARCH" == "x86_64" ] && ARCH_CF="amd64" || ARCH_CF="arm64"

if [ ! -f "/usr/local/bin/cloudflared" ]; then
    echo "📦 正在安装 Cloudflared..."
    wget -qO /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH_CF"
    chmod +x /usr/local/bin/cloudflared
fi

if [ ! -f "/usr/bin/sing-box" ]; then
    echo "📦 正在安装 Sing-box 最新版..."
    LAST_VER=$(curl -Ls https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    [ -z "$LAST_VER" ] && LAST_VER="1.13.11"
    wget -qO sing-box.deb "https://github.com/SagerNet/sing-box/releases/download/v${LAST_VER}/sing-box_${LAST_VER}_linux_${ARCH_CF}.deb"
    dpkg -i sing-box.deb >/dev/null 2>&1
    rm -f sing-box.deb
fi

# ==========================================
# 3. 核心参数交互与生成
# ==========================================
echo "-------------------------------------------------------"
# 自动生成随机 UUID
UUID=$(cat /proc/sys/kernel/random/uuid)
echo "🔑 已自动生成 UUID: $UUID"

read -p "🎯 请输入本地监听端口 (回车默认 60001): " IN_PORT
IN_PORT=${IN_PORT:-60001}

read -p "🛡️ 请输入 Argo Tunnel Token: " ARGO_TOKEN
if [ -z "$ARGO_TOKEN" ]; then
    echo "❌ Token 不能为空！退出部署。"
    exit 1
fi

read -p "🌐 请输入 Argo 绑定的域名 (例如 us3.989269.xyz): " ARGO_DOMAIN
if [ -z "$ARGO_DOMAIN" ]; then
    echo "❌ 域名不能为空！退出部署。"
    exit 1
fi
echo "-------------------------------------------------------"

# ==========================================
# 4. 物理清场并生成完美 JSON 图纸
# ==========================================
rm -rf /etc/sing-box/*.json
mkdir -p /etc/sing-box /var/lib/sing-box

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
        "server": "2606:4700:4700::1111"
      }
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
      "users": [{ "uuid": "$UUID" }],
      "transport": { "type": "ws", "path": "/vless" }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "default_domain_resolver": "dns_remote",
    "rules": [
      { "inbound": "vless-in", "outbound": "warp-out" }
    ],
    "final": "direct"
  }
}
EOF

# ==========================================
# 5. 配置系统服务进程
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

# ==========================================
# 6. 启动并输出节点链接
# ==========================================
echo "⚙️ 正在拉起后台服务..."
systemctl daemon-reload
systemctl enable --now sing-box cloudflared >/dev/null 2>&1
systemctl restart sing-box cloudflared

sleep 2

echo "======================================================="
if systemctl is-active --quiet sing-box; then
    echo "✅ 恭喜！Sing-box & Cloudflared 已成功平稳运行。"
    echo ""
    echo "🔗 请复制以下 VLESS 节点链接导入客户端 (v2rayN/v2rayNG)："
    echo ""
    echo -e "\033[32mvless://${UUID}@${ARGO_DOMAIN}:443?type=ws&security=tls&path=%2Fvless&sni=${ARGO_DOMAIN}#Argo-WARP-Node\033[0m"
    echo ""
    echo "======================================================="
else
    echo "❌ 启动异常！请运行 'journalctl -u sing-box -n 20' 查看系统日志。"
fi
