#!/bin/bash
set -e

LOG_FILE="/var/log/apps-daily-refresh.log"
echo "[INFO] === Daily Refresh Started at $(date) ===" | tee -a $LOG_FILE

# =========================
# 1. Check iptables NAT + SNAT
# =========================
echo "[INFO] 🔍 Checking iptables NAT + SNAT..." | tee -a $LOG_FILE
for NET in "192.168.33.0/24" "192.168.34.0/24"; do
    if ! iptables -t nat -S POSTROUTING | grep -q $NET; then
        echo "[ERROR] ❌ Missing SNAT rule for $NET. Stopping refresh." | tee -a $LOG_FILE
        exit 1
    fi
done
echo "[INFO] ✅ iptables NAT + SNAT OK" | tee -a $LOG_FILE

# =========================
# 2. Refresh Repocket
# =========================
echo "[INFO] 🔄 Refreshing Repocket..." | tee -a $LOG_FILE
docker rm -f repocket1 repocket2 || true
docker run -d --network my_network_1 --name repocket1 -e RP_EMAIL=you@example.com -e RP_API_KEY=YOUR_KEY --restart always repocket/repocket:latest
docker run -d --network my_network_2 --name repocket2 -e RP_EMAIL=you@example.com -e RP_API_KEY=YOUR_KEY --restart always repocket/repocket:latest

# =========================
# 3. Refresh EarnFM
# =========================
echo "[INFO] 🔄 Refreshing EarnFM..." | tee -a $LOG_FILE
docker rm -f earnfm1 earnfm2 || true
docker run -d --network my_network_1 --name earnfm1 -e EARNFM_TOKEN=YOUR_EARNFM_TOKEN --restart always earnfm/earnfm-client:latest
docker run -d --network my_network_2 --name earnfm2 -e EARNFM_TOKEN=YOUR_EARNFM_TOKEN --restart always earnfm/earnfm-client:latest

# =========================
# 4. Restart UR containers
# =========================
echo "[INFO] 🔄 Restarting UR containers..." | tee -a $LOG_FILE
docker restart ur1 ur2 || true

echo "[INFO] ✅ Daily refresh finished at $(date)" | tee -a $LOG_FILE
