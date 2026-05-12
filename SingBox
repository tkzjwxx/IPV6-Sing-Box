#!/bin/bash
clear
echo "===================================================="
echo "    HAX VPS 终极防关联部署脚本 (极客交互版)"
echo "===================================================="
echo ""

# 交互式获取关键参数
read -p "1. 请输入 VLESS UUID (不填则自动生成): " UUID
if [ -z "$UUID" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "   -> 已自动生成 UUID: $UUID"
fi

read -p "2. 请输入 Cloudflare Argo Token: " ARGO_TOKEN
read -p "3. 请输入 WARP IPv6 地址 (带 /128): " WARP_V6
read -p "4. 请输入 WARP 私钥 (PrivateKey): " WARP_KEY
read -p "5. 请输入绑定的 Argo 隧道域名 (如 us3.989269.xyz): " ARGO_DOMAIN
read -p "6. 请输入你的优选域名 (如 sub.danfeng.eu.org): " OPT_DOMAIN

echo ""
echo "===================================================="
echo "参数收集完毕，开始无人值守施工..."
echo "===================================================="

# 1. 物理锁死 DNS64
echo "[1/6] 打破 IPv6 孤岛 (配置 DNS64)..."
rm -f /etc/resolv.conf
echo -e "nameserver 2001:67c:2b0::4\nnameserver 2001:67c:2b0::6\nnameserver 2606:4700:4700::1111" > /etc/resolv.conf

# 2. 突破系统并发限制
echo "[2/6] 注入底层性能优化参数..."
sed -i '/soft nofile/d' /etc/security/limits.conf
sed -i '/hard nofile/d' /etc/security/limits.conf
echo "* soft nofile 65535" >> /etc/security/limits.conf
echo "* hard nofile 65535" >> /etc/security/limits.conf
ulimit -n 65535
cat <<EOF > /etc/sysctl.d/99-hax-master.conf
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 10000
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.ipv4.tcp_mtu_probing = 1
EOF
sysctl -p /etc/sysctl.d/99-hax-master.conf 2>/dev/null

# 3. 安装工具组件
echo "[3/6] 拉取 Sing-box 与 Argo Tunnel..."
apt update && apt install -y curl wget tar
bash <(curl -fsSL https://sing-box.app/install.sh)
curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i cloudflared.deb

# 4. 写入 Sing-box 纯净配置
echo "[4/6] 正在写入 Sing-box 引擎配置..."
mkdir -p /etc/sing-box
cat <<EOF > /etc/sing-box/config.json
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": 12345,
      "users": [{ "uuid": "$UUID", "name": "hax-user" }],
      "transport": { "type": "ws", "path": "/vless" }
    }
  ],
  "outbounds": [
    {
      "type": "wireguard",
      "tag": "warp-out",
      "server": "engage.cloudflareclient.com",
      "server_port": 2408,
      "local_address": ["172.16.0.2/32", "$WARP_V6"],
      "private_key": "$WARP_KEY",
      "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
      "mtu": 1280,
      "udp_fragment": true
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [{ "domain_strategy": "prefer_ipv6", "outbound": "warp-out" }],
    "final": "warp-out"
  }
}
EOF

# 5. 配置 Argo 隧道补丁
echo "[5/6] 注入 Argo Tunnel 防卡死补丁..."
cloudflared service uninstall 2>/dev/null
cloudflared service install $ARGO_TOKEN
mkdir -p /etc/systemd/system/cloudflared.service.d
echo -e "[Service]\nEnvironment=\"TUNNEL_PROTOCOL=http2\"" > /etc/systemd/system/cloudflared.service.d/override.conf

# 6. 点火
echo "[6/6] 引擎点火中..."
systemctl daemon-reload
systemctl enable --now sing-box
systemctl restart cloudflared

echo ""
echo "===================================================="
echo " 施工完毕！状态检查："
echo "===================================================="
systemctl status sing-box --no-pager | grep Active
systemctl status cloudflared --no-pager | grep Active

echo ""
echo "===================================================="
echo " 你的 Windows 客户端配置如下 (直接复制到客户端) :"
echo "===================================================="
echo "{
  \"type\": \"vless\",
  \"tag\": \"Argo-VLESS-HAX\",
  \"server\": \"$OPT_DOMAIN\",
  \"server_port\": 443,
  \"uuid\": \"$UUID\",
  \"tls\": {
    \"enabled\": true,
    \"server_name\": \"$ARGO_DOMAIN\"
  },
  \"transport\": {
    \"type\": \"ws\",
    \"path\": \"/vless\",
    \"headers\": {
      \"Host\": \"$ARGO_DOMAIN\"
    }
  }
}"
echo "===================================================="
