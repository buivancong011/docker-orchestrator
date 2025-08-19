sudo bash -c '
set -Eeuo pipefail

# ===== Config =====
IFACE="${IFACE:-ens5}"
NET1="my_network_1"; SUBNET1="192.168.33.0/24"
NET2="my_network_2"; SUBNET2="192.168.34.0/24"
START_SH="/usr/local/bin/docker-apps-start.sh"
REFRESH_SH="/usr/local/bin/apps-daily-refresh.sh"
UNIT="/etc/systemd/system/docker-apps.service"

# ===== Check deps =====
need(){ command -v "$1" >/dev/null || { echo "Thiếu lệnh: $1"; exit 1; }; }
need ip; need iptables
command -v docker >/dev/null || { echo "Docker chưa có, hãy cài trước."; exit 1; }

# Bật docker khi khởi động & đảm bảo đang chạy
systemctl enable docker --now >/dev/null 2>&1 || true

# ===== Helper lấy IP ổn định =====
get_ip_secondary(){ ip -4 addr show dev "$IFACE" | awk "/inet .*noprefixroute/ {print \$2}" | sed "s#/.*##" | head -n1; }
get_ip_primary()  { ip -4 addr show dev "$IFACE" | awk "/inet .*dynamic/      {print \$2}" | sed "s#/.*##" | head -n1; }
IP_ALLA="$(get_ip_secondary || true)"
IP_ALLB="$(get_ip_primary   || true)"
if [[ -z "$IP_ALLA" || -z "$IP_ALLB" ]]; then
  mapfile -t IP_LINES < <(ip -4 -o addr show dev "$IFACE" | awk "{print \$4}" | sed "s#/.*##")
  IP_ALLA="${IP_ALLA:-${IP_LINES[0]:-}}"
  IP_ALLB="${IP_ALLB:-${IP_LINES[1]:-${IP_LINES[0]:-}}}"
fi
[[ -n "$IP_ALLA" && -n "$IP_ALLB" ]] || { echo "Không lấy được IP trên $IFACE"; exit 1; }
echo "[INFO] Sẽ dùng IP_ALLA=$IP_ALLA (secondary) | IP_ALLB=$IP_ALLB (primary)"

# ===== /usr/local/bin/docker-apps-start.sh =====
cat > "$START_SH" << "EOSH"
#!/usr/bin/env bash
set -Eeuo pipefail
log(){ echo "[`date +%F_%T`] $*"; }

# Khớp cấu hình
IFACE="${IFACE:-ens5}"
NET1="my_network_1"; SUBNET1="192.168.33.0/24"
NET2="my_network_2"; SUBNET2="192.168.34.0/24"

# ⚠ Secrets (khuyến nghị tách .env nếu public)
TM_TOKEN="JoaF9KjqyUjmIUCOMxx6W/6rKD0Q0XTHQ5zlqCEJlXM="
RP_EMAIL="nguyenvinhson000@gmail.com"
RP_KEY="cad6dcce-d038-4727-969b-d996ed80d3ef"
EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb"
UR_USER="nguyenvinhcao123@gmail.com"
UR_PASS="CAOcao123CAO@"
URN_IMAGE="ghcr.io/techroy23/docker-urnetwork:2025.8.11-701332070@sha256:9feae0bfb50545b310bedae8937dc076f1d184182f0c47c14b5ba2244be3ed7a"

# IP helpers
get_ip_secondary(){ ip -4 addr show dev "$IFACE" | awk "/inet .*noprefixroute/ {print \$2}" | sed "s#/.*##" | head -n1; }
get_ip_primary()  { ip -4 addr show dev "$IFACE" | awk "/inet .*dynamic/      {print \$2}" | sed "s#/.*##" | head -n1; }

IP_ALLA="$(get_ip_secondary || true)"
IP_ALLB="$(get_ip_primary   || true)"
if [[ -z "$IP_ALLA" || -z "$IP_ALLB" ]]; then
  mapfile -t IP_LINES < <(ip -4 -o addr show dev "$IFACE" | awk "{print \$4}" | sed "s#/.*##")
  IP_ALLA="${IP_ALLA:-${IP_LINES[0]:-}}"
  IP_ALLB="${IP_ALLB:-${IP_LINES[1]:-${IP_LINES[0]:-}}}"
fi
[[ -n "$IP_ALLA" && -n "$IP_ALLB" ]] || { log "Không lấy được IP"; exit 1; }
log "IP_ALLA=$IP_ALLA  IP_ALLB=$IP_ALLB"

# Networks (idempotent)
docker network inspect "$NET1" >/dev/null 2>&1 || docker network create --driver bridge --subnet "$SUBNET1" "$NET1"
docker network inspect "$NET2" >/dev/null 2>&1 || docker network create --driver bridge --subnet "$SUBNET2" "$NET2"

# iptables NAT (idempotent)
iptables -t nat -C POSTROUTING -s "$SUBNET1" -j SNAT --to-source "$IP_ALLA" 2>/dev/null || \
iptables -t nat -A POSTROUTING -s "$SUBNET1" -j SNAT --to-source "$IP_ALLA"
iptables -t nat -C POSTROUTING -s "$SUBNET2" -j SNAT --to-source "$IP_ALLB" 2>/dev/null || \
iptables -t nat -A POSTROUTING -s "$SUBNET2" -j SNAT --to-source "$IP_ALLB"

# Dọn containers cũ
docker rm -f myst1 myst2 tm1 tm2 repocket1 repocket2 earnfm1 earnfm2 packetsdk1 packetsdk2 ur1 ur2 >/dev/null 2>&1 || true

# Pull images
docker pull mysteriumnetwork/myst:latest
docker pull traffmonetizer/cli_v2:arm64v8
docker pull repocket/repocket:latest
docker pull earnfm/earnfm-client:latest
docker pull packetsdk/packetsdk:latest
docker pull "$URN_IMAGE"

# Myst (map port 4449 theo IP host tương ứng)
docker run -d --network "$NET1" --cap-add NET_ADMIN -p "${IP_ALLA}:4449:4449" \
  --name myst1 -v myst-data1:/var/lib/mysterium-node --restart unless-stopped \
  mysteriumnetwork/myst:latest service --agreed-terms-and-conditions
docker run -d --network "$NET2" --cap-add NET_ADMIN -p "${IP_ALLB}:4449:4449" \
  --name myst2 -v myst-data2:/var/lib/mysterium-node --restart unless-stopped \
  mysteriumnetwork/myst:latest service --agreed-terms-and-conditions

# TraffMonetizer
docker run -d --network "$NET1" --restart=always --name tm1 \
  traffmonetizer/cli_v2:arm64v8 start accept --token "$TM_TOKEN"
docker run -d --network "$NET2" --restart=always --name tm2 \
  traffmonetizer/cli_v2:arm64v8 start accept --token "$TM_TOKEN"

# Repocket
docker run -d --network "$NET1" --restart=always --name repocket1 \
  -e RP_EMAIL="$RP_EMAIL" -e RP_API_KEY="$RP_KEY" repocket/repocket:latest
docker run -d --network "$NET2" --restart=always --name repocket2 \
  -e RP_EMAIL="$RP_EMAIL" -e RP_API_KEY="$RP_KEY" repocket/repocket:latest

# EarnFM
docker run -d --network "$NET1" --restart=always --name earnfm1 \
  -e EARNFM_TOKEN="$EARNFM_TOKEN" earnfm/earnfm-client:latest
docker run -d --network "$NET2" --restart=always --name earnfm2 \
  -e EARNFM_TOKEN="$EARNFM_TOKEN" earnfm/earnfm-client:latest

# PacketSDK
docker run -d --network "$NET1" --restart unless-stopped --name packetsdk1 \
  packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj
docker run -d --network "$NET2" --restart unless-stopped --name packetsdk2 \
  packetsdk/packetsdk -appkey=BFwbNdFfwgcDdRmj

# URNetwork
docker run -d --network "$NET1" --restart=always --cap-add NET_ADMIN --name ur1 \
  -e USER_AUTH="$UR_USER" -e PASSWORD="$UR_PASS" "$URN_IMAGE"
docker run -d --network "$NET2" --restart=always --cap-add NET_ADMIN --name ur2 \
  -e USER_AUTH="$UR_USER" -e PASSWORD="$UR_PASS" "$URN_IMAGE"

log "✅ All Docker apps started."
EOSH
chmod +x "$START_SH"

# ===== /usr/local/bin/apps-daily-refresh.sh =====
cat > "$REFRESH_SH" << "EOF"
#!/usr/bin/env bash
set -Eeuo pipefail
log(){ echo "[$(date +%F_%T)] $*"; }

NET1="my_network_1"
NET2="my_network_2"
RP_EMAIL="nguyenvinhson000@gmail.com"
RP_KEY="cad6dcce-d038-4727-969b-d996ed80d3ef"
EARNFM_TOKEN="50f04bbe-94d9-4f6a-82b9-b40016bd4bbb"
URN_IMAGE="ghcr.io/techroy23/docker-urnetwork:2025.8.11-701332070@sha256:9feae0bfb50545b310bedae8937dc076f1d184182f0c47c14b5ba2244be3ed7a"

log "Daily refresh: recreate Repocket/EarnFM, restart UR"

docker rm -f repocket1 repocket2 earnfm1 earnfm2 >/dev/null 2>&1 || true
docker pull repocket/repocket:latest >/dev/null || true
docker pull earnfm/earnfm-client:latest >/dev/null 2>&1 || true

docker run -d --network "$NET1" --name repocket1 \
  -e RP_EMAIL="$RP_EMAIL" -e RP_API_KEY="$RP_KEY" --restart=always repocket/repocket:latest
docker run -d --network "$NET2" --name repocket2 \
  -e RP_EMAIL="$RP_EMAIL" -e RP_API_KEY="$RP_KEY" --restart=always repocket/repocket:latest

docker run -d --network "$NET1" --restart=always \
  -e EARNFM_TOKEN="$EARNFM_TOKEN" --name earnfm1 earnfm/earnfm-client:latest
docker run -d --network "$NET2" --restart=always \
  -e EARNFM_TOKEN="$EARNFM_TOKEN" --name earnfm2 earnfm/earnfm-client:latest

docker pull "$URN_IMAGE" >/dev/null 2>&1 || true
docker restart ur1 >/dev/null 2>&1 || true
docker restart ur2 >/dev/null 2>&1 || true

log "Daily refresh done."
EOF
chmod +x "$REFRESH_SH"

# ===== docker-apps.service =====
cat > "$UNIT" <<EOF
[Unit]
Description=Docker Apps Auto Start
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$START_SH
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ===== Timer: delay 30s sau khi boot mới chạy docker-apps.service =====
cat > /etc/systemd/system/docker-apps-boot.timer <<EOF
[Unit]
Description=Delay 30s after boot then start docker-apps.service

[Timer]
OnBootSec=30s
Unit=docker-apps.service
Persistent=false
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

# ===== apps-daily-refresh.service + timer (03:20 UTC hàng ngày) =====
cat > /etc/systemd/system/apps-daily-refresh.service <<EOF
[Unit]
Description=Apps Daily Refresh (repocket/earnfm recreate, UR restart)
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$REFRESH_SH
StandardOutput=journal
StandardError=journal
EOF

cat > /etc/systemd/system/apps-daily-refresh.timer <<EOF
[Unit]
Description=Timer for Apps Daily Refresh (03:20 UTC daily)

[Timer]
OnCalendar=*-*-* 03:20:00 UTC
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

# ===== weekly-reboot.service + timer (03:10 UTC mỗi Thứ Hai) =====
cat > /etc/systemd/system/weekly-reboot.service <<EOF
[Unit]
Description=Weekly Reboot (03:10 UTC every Monday)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/reboot
EOF

cat > /etc/systemd/system/weekly-reboot.timer <<EOF
[Unit]
Description=Timer for Weekly Reboot (03:10 UTC every Monday)

[Timer]
OnCalendar=Mon *-*-* 03:10:00 UTC
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

# ===== Enable timers =====
systemctl daemon-reload
# Không enable docker-apps.service trực tiếp; để timer gọi sau boot 30s
systemctl enable --now docker-apps-boot.timer apps-daily-refresh.timer weekly-reboot.timer

echo "✅ Hoàn tất: tạo scripts, service, boot-delay 30s, daily refresh timer & weekly reboot timer."
echo "👉 Kiểm tra timers: systemctl list-timers --all | grep -E \"docker-apps-boot|apps-daily-refresh|weekly-reboot\""
echo "👉 Xem log khởi tạo apps: journalctl -u docker-apps.service -e --no-pager"
'
