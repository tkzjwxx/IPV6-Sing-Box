#!/bin/bash

# ========================================================
# HAX 纯 IPv6 VPS 自动化部署脚本 (V2 修正版)
# 针对 1.13.11 锁定语法 & 强制 WARP 注册修复
# ========================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}>>> 乙方项目组：正在进行系统环境初始化...${NC}"
# 预先杀掉可能存在的进程，解决 Text file busy
systemctl stop sing-box cloudflared 2>/dev/null
apt update && apt install -y wget tar curl sudo jq wireguard-tools

# 1. 变量交互输入
echo -e "${GREEN}>>> 参数配置阶段：${NC}"
read -p "1. 输入 Cloudflare Tunnel Token: " ARGO_TOKEN
read -p "2. 输入 Argo 隧道域名: " ARGO_DOMAIN
read -p "3. 输入 Sing-box 监听端口 (默认 12345): " SB_PORT
SB_PORT=${SB_PORT:-12345}

# 2. 自动生成 UUID
UUID=$(cat /proc/sys/kernel/random/uuid)

# 3. 自动化获取 WARP 身份 (修复注册 null 问题)
echo -e "${BLUE}>>> 正在尝试强制通过 IPv6 注册 WARP 账号...${NC}"
PRIV_KEY=$(wg genkey)
PUB_KEY=$(echo "$PRIV_KEY" | wg pubkey)

# 使用更稳定的注册接口，并增加错误重试
for i in {1..3}; do
    REG_JSON=$(curl -6 -s -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "Content-Type: application/json" \
        -d "{\"install_id\":\"\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"key\":\"$PUB_KEY\",\"fcm_token\":\"\",\"type\":\"ios\",\"locale\":\"en_US\"}")
    WARP_V6=$(echo "$REG_JSON" | jq -r '.config.interface.address.v6 // empty')
    if [ ! -z "$WARP_V6" ]; then break; fi
    echo "注册尝试 $i 失败，正在重试..."
    sleep 2
done

if [ -z "$WARP_V6" ]; then
    echo -e "${RED}致命错误：WARP 注册失败，请检查 VPS 的 IPv6 网络连通性！${NC}"
    exit 1
fi
echo -e "${GREEN}WARP 注册成功：$WARP_V6${NC}"

# 4. 安装 Sing-box v1.13.11
echo -e "${BLUE}>>> 安装核心组件 v1.13.11...${NC}"
wget -O sing-box.tar.gz https://github.com/SagerNet/sing-box/releases/download/v1.13.11/sing-box-1.13.11-linux-amd64.tar.gz
tar -zxvf sing-box.tar.gz
cp -f sing-box-1.13.11-linux-amd64/sing-box /usr/bin/sing-box
chmod +x /usr/bin/sing-box
rm -rf sing-box.tar.gz sing-box-1.13.11-linux-amd64

# 5. 生成配置文件 (Endpoints 架构)
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

# 6. 部署 Argo Tunnel (解决 Text file busy)
echo -e "${BLUE}>>> 激活 Argo 隧道...${NC}"
cloudflared service uninstall 2>/dev/null
wget -O /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared
cloudflared service install "$ARGO_TOKEN"

# 7. 系统服务配置
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

# 8. 验收输出
echo -e "${GREEN}==========================================${NC}"
echo -e "验收成功！请保存配置：${NC}"
echo -e "域名: ${BLUE}$ARGO_DOMAIN${NC} / 端口: ${BLUE}443${NC}"
echo -e "UUID: ${BLUE}$UUID${NC}"
echo -e "路径: ${BLUE}/vless${NC} / 传输: ${BLUE}ws${NC}"
echo -e "WARP IP: $WARP_V6"
echo -e "------------------------------------------${NC}"
echo -e "服务自检：Sing-box($(systemctl is-active sing-box)) | Argo($(systemctl is-active cloudflared))"
echo -e "${GREEN}==========================================${NC}"
