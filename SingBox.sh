#!/bin/bash
clear
echo "===================================================="
echo "    HAX VPS 终极防关联部署脚本 (全自动 WARP 版)"
echo "===================================================="
echo ""

# 交互式获取关键参数 (已剔除手动 WARP 输入)
read -p "1. 请输入 VLESS UUID (不填则自动生成): " UUID
if [ -z "$UUID" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "   -> 已自动生成 UUID: $UUID"
fi

read -p "2. 请输入 Cloudflare Argo Token: " ARGO_TOKEN
read -p "3. 请输入绑定的 Argo 隧道域名 (如 us3.989269.xyz): " ARGO_DOMAIN
read -p "4. 请输入你的优选域名 (如 sub.danfeng.eu.org): " OPT_DOMAIN

echo ""
echo "===================================================="
echo "参数收集完毕，开始全自动施工..."
echo "===================================================="

# 1. 物理锁死 DNS64
echo "[1/7] 打破 IPv6 孤岛 (配置 DNS64)..."
rm -f /etc/resolv.conf
echo -e "nameserver 2001:67c:2b0::4\nnameserver 2001:67c:2b0::6\nnameserver 2606:4700:4700::1111" > /etc/resolv.conf

# 2. 自动获取 WARP 凭证 (核心升级)
echo "[2/7] 正在向 Cloudflare 自动申请 WARP 凭证 (请稍候 5-10 秒)..."
wget -q -O wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64
chmod +x wgcf
./wgcf register --accept-tos >/dev/null 2>&1
./wgcf generate >/dev/null 2>&1

WARP_KEY=$(grep '^PrivateKey' wgcf-profile.conf | awk '{print $3}')
WARP_V6=$(grep '^Address' wgcf-profile.conf | grep ':' | awk '{print $3}')

if [ -z "$WARP_KEY" ] || [ -z "$WARP_V6" ]; then
    echo -e "\e[31m[错误] WARP 自动申请失败！请检查网络或稍后重试。\e[0m"
    exit 1
fi
echo "   -> 成功获取 WARP 私钥与 IPv6 地址！"

# 3. 突破系统并发限制
echo "[3/7] 注入底层性能优化参数..."
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

# 4. 安装工具组件
echo "[4/7] 拉取 Sing-box 与 Argo Tunnel..."
apt update -y >/dev/null 2>&1 && apt install -y curl wget tar >/dev/null 2>&1
bash <(curl -fsSL https://sing-box.app/install.sh) >/dev/null 2>&1
curl -sL --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i cloudflared.deb >/dev/null 2>&1

# 5. 写入 Sing-box 纯净配置
echo "[5/7] 正在写入 Sing-box 引擎配置..."
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

# 6. 配置 Argo 隧道补丁
echo "[6/7] 注入 Argo Tunnel 防卡死补丁..."
cloudflared service uninstall 2>/dev/null
cloudflared service install $ARGO_TOKEN >/dev/null 2>&1
mkdir -p /etc/systemd/system/cloudflared.service.d
echo -e "[Service]\nEnvironment=\"TUNNEL_PROTOCOL=http2\"" > /etc/systemd/system/cloudflared.service.d/override.conf

# 7. 点火
echo "[7/7] 引擎点火中..."
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
