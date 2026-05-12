#!/bin/bash

# ========================================================
# HAX 纯 IPv6 VPS 自动化部署脚本 (V5 交付级)
# 针对 HAX 纯 IPv6 环境深度优化，解决 WARP 注册 Null 问题
# ========================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# 1. 环境自检
echo -e "${BLUE}>>> 正在清理环境并安装核心依赖...${NC}"
systemctl stop sing-box cloudflared 2>/dev/null
apt update && apt install -y wget tar curl sudo jq wireguard-tools

# 2. 变量交互
read -p "1. 输入 Argo Tunnel Token: " ARGO_TOKEN
read -p "2. 输入 Argo 隧道域名: " ARGO_DOMAIN
read -p "3. 输入 Sing-box 监听端口: " SB_PORT
SB_PORT=${SB_PORT:-12345}
UUID=$(cat /proc/sys/kernel/random/uuid)
INSTALL_ID=$(cat /proc/sys/kernel/random/uuid | cut -c1-22)

# 3. WARP 注册核心逻辑 (带深度伪装)
echo -e "${BLUE}>>> 正在预检网络连通性...${NC}"
if ! ping6 -c 3 api.cloudflareclient.com > /dev/null; then
    echo -e "${RED}致命错误：当前 VPS 无法连接 Cloudflare API 节点，请检查 IPv6 路由！${NC}"
    exit 1
fi

echo -e "${BLUE}>>> 正在向 Cloudflare 发起 WARP 注册请求...${NC}"
PRIV_KEY=$(wg genkey)
PUB_KEY=$(echo "$PRIV_KEY" | wg pubkey)

# 核心请求：加入 Cf-Client-Version 伪装官方客户端
RESPONSE=$(curl -6 -s -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
    -H "User-Agent: okhttp/3.12.1" \
    -H "Content-Type: application/json" \
    -H "Cf-Client-Version: i-2024.11.0" \
    -d "{
        \"install_id\": \"$INSTALL_ID\",
        \"tos\": \"$(date -u +%FT%T.000Z)\",
        \"key\": \"$PUB_KEY\",
        \"fcm_token\": \"\",
        \"type\": \"ios\",
        \"locale\": \"en_US\"
    }")

WARP_V6=$(echo "$RESPONSE" | jq -r '.config.interface.address.v6 // empty')

# 注册失败处理
if [ -z "$WARP_V6" ] || [ "$WARP_V6" == "null" ]; then
    echo -e "${RED}!!! 注册失败，Cloudflare 返回原始信息如下：${NC}"
    echo "$RESPONSE" | jq .
    echo -e "${GREEN}建议：如果之前有成功的机器，请手动输入那一台的密钥，账号是通用的：${NC}"
    read -p "请输入 WARP Private Key (私钥): " PRIV_KEY
    read -p "请输入 WARP 分配的 IPv6 (如 2606:4700.../128): " WARP_V6
    if [ -z "$WARP_V6" ]; then exit 1; fi
else
    echo -e "${GREEN}WARP 注册成功！分配 IP: $WARP_V6${NC}"
fi

# 4. Sing-box 1.13.11 部署
echo -e "${BLUE}>>> 部署 Sing-box 1.13.11 核心...${NC}"
wget -O sing-box.tar.gz https://github.com/SagerNet/sing-box/releases/download/v1.13.11/sing-box-1.13.11-linux-amd64.tar.gz
tar -zxvf sing-box.tar.gz
cp -f sing-box-1.13.11-linux-amd64/sing-box /usr/bin/sing-box
chmod +x /usr/bin/sing-box

# 5. 生成 Endpoints 配置
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
  "route": { "final": "warp-node" }
}
EOF

# 6. 激活 Argo Tunnel
echo -e "${BLUE}>>> 激活 Cloudflare 隧道...${NC}"
cloudflared service uninstall 2>/dev/null
wget -O /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared
cloudflared service install "$ARGO_TOKEN"

# 7. 启动服务
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

systemctl daemon-reload && systemctl enable sing-box --now && systemctl restart cloudflared

echo -e "${GREEN}==========================================${NC}"
echo -e "部署成功！UUID: ${BLUE}$UUID${NC}"
echo -e "已通过 Sing-box 1.13.11 及 WARP 节点交付。"
echo -e "${GREEN}==========================================${NC}"
