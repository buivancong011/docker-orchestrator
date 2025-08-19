#!/bin/bash
set -e

echo "=== 🚀 Docker Orchestrator Installer ==="

# =========================
# 1. Remove unwanted packages
# =========================
echo "[INFO] 🔄 Removing squid & httpd-tools if present..."
yum remove -y squid httpd-tools || true
apt remove -y squid httpd-tools || true

# =========================
# 2. Install Docker if missing
# =========================
if ! command -v docker &> /dev/null; then
  echo "[INFO] 🐳 Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
  echo "[INFO] 🔁 Rebooting system after Docker install..."
  reboot
  exit 0
else
  echo "[INFO] ✅ Docker already installed."
fi

# =========================
# 3. Create Docker networks
# =========================
echo "[INFO] 🌐 Creating Docker networks..."
docker network create my_network_1 --driver bridge --subnet 192.168.33.0/24 || true
docker network create my_network_2 --driver bridge --subnet 192.168.34.0/24 || true

# =========================
# 4. Setup iptables NAT + SNAT
# =========================
IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute | awk '{gsub(/\/.*/,"",$4); print $4; exit}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic | awk '{gsub(/\/.*/,"",$4); print $4; exit}')

echo "[INFO] 🔒 Setting iptables rules..."
iptables -t nat -C POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA} 2>/dev/null || \
iptables -t nat -I POSTROUTING -s 192.168.33.0/24 -j SNAT --to-source ${IP_ALLA}

iptables -t nat -C POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB} 2>/dev/null || \
iptables -t nat -I POSTROUTING -s 192.168.34.0/24 -j SNAT --to-source ${IP_ALLB}

# =========================
# 5. Create startup script
# =========================
echo "[INFO] 📝 Creating docker-apps-start.sh..."
cat >/usr/local/bin/docker-apps-start.sh <<'EOF'
#!/bin/bash
set -e
sleep 30
echo "[INFO] 🚀 Starting all containers..."

# Traffmonetizer
docker run -d --network my_network_1 --restart always --name tm1 traffmonetizer/cli_v2:arm64v8 start accept --token YOUR_TOKEN
docker run -d --network my_network_2 --restart always --name tm2 traffmonetizer/cli_v2:arm64v8 start accept --token YOUR_TOKEN

# Repocket
docker run -d --network my_network_1 --name repocket1 -e RP_EMAIL=your@email -e RP_API_KEY=your_key --restart=always repocket/repocket:latest
docker run -d --network my_network_2 --name repocket2 -e RP_EMAIL=your@email -e RP_API_KEY=your_key --restart=always repocket/repocket:latest

# Mysterium
IP_ALLA=$(/sbin/ip -4 -o addr show scope global noprefixroute | awk '{gsub(/\/.*/,"",$4); print $4; exit}')
IP_ALLB=$(/sbin/ip -4 -o addr show scope global dynamic | awk '{gsub(/\/.*/,"",$4); print $4; exit}')
docker run -d --network my_network_1 --cap-add NET_ADMIN -p ${IP_ALLA}:4449:4449 --name myst1 -v myst-data1:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
docker run -d --network my_network_2 --cap-add NET_ADMIN -p ${IP_ALLB}:4449:4449 --name myst2 -v myst-data2:/var/lib/mysterium-node --restart unless-stopped mysteriumnetwork/myst:latest service --agreed-terms-and-conditions

# EarnFM
docker run -d --network my_network_1 --restart=always -e EARNFM_TOKEN="YOUR_EARNFM_TOKEN" --name earnfm1 earnfm/earnfm-client:latest 
docker run -d --network my_network_2 --restart=always -e EARNFM_TOKEN="YOUR_EARNFM_TOKEN" --name earnfm2 earnfm/earnfm-client:latest 

# PacketSDK
docker run -d --network my_network_1 --restart unless-stopped --name packetsdk1 packetsdk/packetsdk -appkey=YOUR_APPKEY
docker run -d --network my_network_2 --restart unless-stopped --name packetsdk2 packetsdk/packetsdk -appkey=YOUR_APPKEY

# UR Network
docker run -d --network my_network_1 --restart=always --cap-add NET_ADMIN --platform linux/arm64 --name ur1 -e USER_AUTH="youruser" -e PASSWORD="yourpass" ghcr.io/techroy23/docker-urnetwork:latest
docker run -d --network my_network_2 --restart=always --cap-add NET_ADMIN --platform linux/arm64 --name ur2 -e USER_AUTH="youruser" -e PASSWORD="yourpass" ghcr.io/techroy23/docker-urnetwork:latest

echo "[INFO] ✅ All containers started."
EOF

chmod +x /usr/local/bin/docker-apps-start.sh

# =========================
# 6. Systemd service for Docker Apps
# =========================
cat >/etc/systemd/system/docker-apps.service <<'EOF'
[Unit]
Description=Docker Apps Auto Start
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docker-apps-start.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Timer để delay 30s
cat >/etc/systemd/system/docker-apps-boot.timer <<'EOF'
[Unit]
Description=Run docker-apps.service 30s after boot

[Timer]
OnBootSec=30
Unit=docker-apps.service

[Install]
WantedBy=timers.target
EOF

# =========================
# 7. Daily refresh service & timer
# =========================
curl -sSL https://raw.githubusercontent.com/buivancong011/docker-orchestrator/refs/heads/main/apps-daily-refresh.sh -o /usr/local/bin/apps-daily-refresh.sh
chmod +x /usr/local/bin/apps-daily-refresh.sh

cat >/etc/systemd/system/apps-daily-refresh.service <<'EOF'
[Unit]
Description=Apps Daily Refresh
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/apps-daily-refresh.sh
EOF

cat >/etc/systemd/system/apps-daily-refresh.timer <<'EOF'
[Unit]
Description=Run Apps Daily Refresh once per day

[Timer]
OnCalendar=*-*-* 03:20:00
Unit=apps-daily-refresh.service

[Install]
WantedBy=timers.target
EOF

# =========================
# 8. Weekly reboot service & timer
# =========================
cat >/etc/systemd/system/weekly-reboot.service <<'EOF'
[Unit]
Description=Weekly Reboot

[Service]
Type=oneshot
ExecStart=/sbin/reboot
EOF

cat >/etc/systemd/system/weekly-reboot.timer <<'EOF'
[Unit]
Description=Reboot every 7 days

[Timer]
OnCalendar=Mon *-*-* 03:10:00
Unit=weekly-reboot.service

[Install]
WantedBy=timers.target
EOF

# =========================
# 9. Enable all services & timers
# =========================
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable docker-apps.service
systemctl enable docker-apps-boot.timer
systemctl enable apps-daily-refresh.timer
systemctl enable weekly-reboot.timer

systemctl start docker-apps-boot.timer
systemctl start apps-daily-refresh.timer
systemctl start weekly-reboot.timer

echo "=== ✅ Install completed. Check with: systemctl list-timers ==="
