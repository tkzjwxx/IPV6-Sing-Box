#!/bin/bash

# 1. 强制创建目录
mkdir -p /etc/sing-box

# 2. 安装 Sing-box (抛弃失效链接，改用直接下载 deb 包)
if [ ! -f "/usr/bin/sing-box" ]; then
    echo "正在安装 Sing-box..."
    # 自动识别架构 (amd64 或 arm64)
    ARCH=$(uname -m)
    if [ "$ARCH" == "x86_64" ]; then ARCH="amd64"; elif [ "$ARCH" == "aarch64" ]; then ARCH="arm64"; fi
    
    # 自动获取最新版本号
    LAST_VER=$(curl -Ls https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    if [ -z "$LAST_VER" ]; then LAST_VER="1.13.11"; fi # 若API失效则强制指定版本
    
    echo "检测到最新版本: $LAST_VER"
    # 下载并安装
    wget -O sing-box.deb "https://github.com/SagerNet/sing-box/releases/download/v${LAST_VER}/sing-box_${LAST_VER}_linux_${ARCH}.deb"
    dpkg -i sing-box.deb
    rm -f sing-box.deb
fi

# 3. 自动从系统现有的 WARP 配置中“偷”数据
WARP_CONF="/etc/wireguard/warp.conf"
if [ ! -f "$WARP_CONF" ]; then
    echo "❌ 错误：未发现 $WARP_CONF，请先运行 WARP 脚本 (选项3) 安装双栈！"
    exit 1
fi

echo "正在从 $WARP_CONF 提取配置数据..."
# 提取私钥、V4/V6 地址
PK=$(grep "PrivateKey" $WARP_CONF | awk -F' = ' '{print $2}')
V4=$(grep "Address" $WARP_CONF | grep "\." | awk -F' = ' '{print $2}')
V6=$(grep "Address" $WARP_CONF | grep ":" | awk -F' = ' '{print $2}')
# 提取 Reserved (即便被 # 注释掉也能精准抓取)
RES_VAL=$(grep -i "Reserved" $WARP_CONF | awk -F'=' '{print $2}' | tr -d ' #[]')
if [ -z "$RES_VAL" ]; then RES="[0,0,0]"; else RES="[${RES_VAL}]"; fi

# 4. 交互输入 Argo 变量
echo "-------------------------------------------------------"
read -p "请输入你的 Argo Tunnel Token: " ARGO_TOKEN
read -p "请输入你的 Argo 域名 (例如 hx.abc.com): " ARGO_DOMAIN
echo "-------------------------------------------------------"

# 5. 自动生成 UUID
MY_UUID=$(cat /proc/sys/kernel/random/uuid)

# 6. 生成 Sing-box 配置文件 (双栈 WARP + 6优先)
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

# 7. 配置 cloudflared 服务 (强制 IPv6 连接)
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

# 8. 启动并验收
systemctl daemon-reload
systemctl enable --now sing-box cloudflared
systemctl restart sing-box cloudflared

echo "-------------------------------------------------------"
echo "🎉 部署成功！"
echo "UUID: $MY_UUID"
echo "域名: $ARGO_DOMAIN"
echo "路径: /vless"
echo "协议: VLESS + WS + Argo"
echo "出站: 双栈 WARP (IPv6 优先)"
echo "-------------------------------------------------------"
systemctl status sing-box --no-pager
