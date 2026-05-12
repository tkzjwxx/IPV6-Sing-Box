#!/bin/bash

# ========================================================
# HAX 纯 IPv6 VPS 自动化部署脚本 (V6 仓库交付版)
# 修复：JSON 数组格式、Argo 隧道强制 IPv6 协议
# ========================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# 1. 清理旧环境
echo -e "${BLUE}>>> 乙方项目组：正在清理旧服务并安装依赖...${NC}"
systemctl stop sing-box cloudflared 2>/dev/null
apt update && apt install -y wget tar curl sudo jq wireguard-tools

# 2. 收集变量
echo -e "${GREEN}>>> 请输入配置参数：${NC}"
read -p "1. 输入 Cloudflare Tunnel Token: " ARGO_TOKEN
read -p "2. 输入 Argo 隧道域名: " ARGO_DOMAIN
read -p "3. 输入 Sing-box 监听端口 (默认 12345): " SB_PORT
SB_PORT=${SB_PORT:-12345}
UUID=$(cat /proc/sys/kernel/random/uuid)

# 3. WARP 账号处理 (带手动回退)
echo -e "${BLUE}>>> 正在尝试自动注册 WARP...${NC}"
PRIV_KEY=$(wg genkey)
PUB_KEY=$(echo "$PRIV_KEY" | wg pubkey)
REG_JSON=$(curl -6 -s -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
    -H "User-Agent: okhttp/3.12.1" -H "Content-Type: application/json" \
    -d "{\"install_id\":\"\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"key\":\"$PUB_KEY\",\"fcm_token\":\"\",\"type\":\"ios\",\"locale\":\"en_US\"}")
WARP_V6=$(echo "$REG_JSON" | jq -r '.config.interface.address.v6 // empty')

if [ -z "$WARP_V6" ] || [ "$WARP_V6" == "null" ]; then
    echo -e "${RED}!!! 自动注册失败，请手动输入之前获取的信息：${NC}"
    read -p "请输入 WARP Private Key (私钥): " PRIV_KEY
    read -p "请输入 WARP IPv6 (格式如 2606:4700...): " WARP_V6
    # 自动补全 /128 掩码
    [[ $WARP_V6 != */128 ]] && WARP_V6="${WARP_V6}/128"
fi

# 4. 下载并安装 Sing-box 1.13.11
echo -e "${BLUE}>>> 下载核心组件...${NC}"
wget -O sing-box.tar.gz https://github.com/SagerNet/sing-box/releases/download/v1.13.11/sing-box-1.13.11-linux-amd64.tar.gz
tar -zxvf sing-box.tar.gz
cp -f sing-box-1.13.11-linux-amd64/sing-box /usr/bin/sing-box
chmod +x /usr/bin/sing-box
rm -rf sing-box.tar.gz sing-box-1.13.11-linux-amd64

# 5. 生成标准 JSON 配置 (修复数组格式问题)
mkdir -p /etc/sing-box
cat <<EOF > /etc/sing-box/config.json
{
  "log": { "level": "info", "timestamp": true },
  "dns": { "strategy": "prefer_ipv6" },
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp-node",
      "address": [
        "172.16.0.2/32",
        "$WARP_V6"
      ],
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

# 6. 安装 Argo 隧道并强制 IPv6 协议
echo -e "${BLUE}>>> 正在部署 Argo 隧道并设置 IPv6 优先级...${NC}"
wget -O /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared
cloudflared service uninstall 2>/dev/null

# 生成 cloudflared 服务文件，强制使用 http2 和 IPv6 边缘节点
cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=cloudflared
After=network.target

[Service]
TimeoutStartSec=0
Type=notify
ExecStart=/usr/local/bin/cloudflared tunnel --protocol http2 --edge-ip-version 6 run --token $ARGO_TOKEN
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 7. 配置 Sing-box 系统服务
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

# 8. 启动与验证
echo -e "${BLUE}>>> 启动服务...${NC}"
systemctl daemon-reload
systemctl enable sing-box cloudflared --now
systemctl restart sing-box cloudflared

echo -e "${GREEN}==========================================${NC}"
echo -e "部署成功！请保存验收单：${NC}"
echo -e "地址: ${BLUE}$ARGO_DOMAIN${NC} / 端口: ${BLUE}443${NC}"
echo -e "UUID: ${BLUE}$UUID${NC}"
echo -e "路径: ${BLUE}/vless${NC} / 传输: ${BLUE}ws${NC}"
echo -e "------------------------------------------${NC}"
echo -e "Sing-box 状态: \$(systemctl is-active sing-box)"
echo -e "Argo 隧道状态: \$(systemctl is-active cloudflared)"
echo -e "${GREEN}==========================================${NC}"
