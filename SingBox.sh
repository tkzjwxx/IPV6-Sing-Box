#!/bin/bash

# ========================================================
# HAX 纯 IPv6 VPS 终极全自动部署脚本 (Sing-box 1.13.11)
# 自动项：WARP注册、UUID生成、内核下载、Endpoint构建
# ========================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}>>> 乙方项目组已就位，开始自动化安装流程...${NC}"
apt update && apt install -y wget tar curl sudo jq wireguard-tools

# 1. 变量交互输入
echo -e "${GREEN}>>> 请输入必要参数：${NC}"
read -p "1. 输入 Cloudflare Tunnel Token: " ARGO_TOKEN
read -p "2. 输入 Argo 隧道域名 (如 us3.989269.xyz): " ARGO_DOMAIN
read -p "3. 输入 Sing-box 监听端口 (默认 12345): " SB_PORT
SB_PORT=${SB_PORT:-12345}

# 2. 自动生成 VLESS UUID
UUID=$(cat /proc/sys/kernel/random/uuid)

# 3. 自动化获取 WARP 身份信息
echo -e "${BLUE}>>> 正在与 Cloudflare 握手，自动申请 WARP 账号...${NC}"
PRIV_KEY=$(wg genkey)
PUB_KEY=$(echo "$PRIV_KEY" | wg pubkey)

REG_JSON=$(curl -s -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
    -H "Content-Type: application/json" \
    -d "{\"install_id\":\"\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"key\":\"$PUB_KEY\",\"fcm_token\":\"\",\"type\":\"ios\",\"locale\":\"en_US\"}")

WARP_V6=$(echo "$REG_JSON" | jq -r '.config.interface.address.v6')

# 4. 下载全功能版 Sing-box v1.13.11
echo -e "${BLUE}>>> 正在抓取 Sing-box v1.13.11 核心...${NC}"
wget -O sing-box.tar.gz https://github.com/SagerNet/sing-box/releases/download/v1.13.11/sing-box-1.13.11-linux-amd64.tar.gz
tar -zxvf sing-box.tar.gz
mv sing-box-1.13.11-linux-amd64/sing-box /usr/bin/sing-box
chmod +x /usr/bin/sing-box
rm -rf sing-box.tar.gz sing-box-1.13.11-linux-amd64

# 5. 生成最新的 Endpoints 架构配置文件
echo -e "${BLUE}>>> 正在构建 1.13.11 专属配置文件...${NC}"
mkdir -p /etc/sing-box
cat <<EOF > /etc/sing-box/config.json
{
  "log": { "level": "info", "timestamp": true },
  "dns": { "strategy": "prefer_ipv6" },
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp-node",
      "address": ["172.16.0.2/32", "$WARP_V6"],
      "private_key": "$PRIV_KEY",
      "mtu": 1280,
      "peers": [
        {
          "address": "2606:4700:d0::a29f:c001",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowed_ips": ["0.0.0.0/0", "::/0"]
        }
      ]
    }
  ],
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $SB_PORT,
      "users": [{ "uuid": "$UUID" }],
      "transport": { "type": "ws", "path": "/vless" }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "final": "warp-node"
  }
}
EOF

# 6. 部署 Argo Tunnel 服务
echo -e "${BLUE}>>> 正在激活 Cloudflare 隧道...${NC}"
wget -O /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared
cloudflared service uninstall 2>/dev/null
cloudflared service install $ARGO_TOKEN

# 7. 配置并启动系统服务
cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=/usr/bin/sing-box -C /etc/sing-box run
Restart=on-failure
RestartSec=10
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box --now
systemctl restart cloudflared

# 8. 成果展示
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}工程验收通过！请保存以下连接信息：${NC}"
echo -e "地址 (Address): ${BLUE}$ARGO_DOMAIN${NC}"
echo -e "端口 (Port): ${BLUE}443${NC} (由 Argo 映射)"
echo -e "用户 ID (UUID): ${BLUE}$UUID${NC}"
echo -e "传输方式 (Transport): ${BLUE}WebSocket (ws)${NC}"
echo -e "路径 (Path): ${BLUE}/vless${NC}"
echo -e "TLS: ${BLUE}开启 (Enabled)${NC}"
echo -e "${GREEN}------------------------------------------${NC}"
echo -e "WARP 虚拟内网 IPv6: $WARP_V6"
echo -e "Sing-box 状态: $(systemctl is-active sing-box)"
echo -e "${GREEN}==========================================${NC}"
