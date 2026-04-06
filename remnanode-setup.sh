#!/usr/bin/env bash
#
# ╔══════════════════════════════════════════════════════════╗
# ║     Ubuntu VPS Initial Setup — Remnanode Deployment      ║
# ║                                                          ║
# ║         Docker · Geo databases · Kernel tuning           ║
# ╚══════════════════════════════════════════════════════════╝
#

set -euo pipefail

# ── Colors & helpers ───────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

step_current=0
step_total=4

info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

step() {
    step_current=$((step_current + 1))
    echo ""
    echo -e "${BOLD}${CYAN}═══ [${step_current}/${step_total}] $1 ═══${NC}"
}

# ── Pre-flight checks ─────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo bash $0)"
    exit 1
fi

echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║     Remnanode VPS Setup — Starting...      ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════╝${NC}"

# ── Step 1: Docker ─────────────────────────────────────────
step "Installing Docker"

if command -v docker &>/dev/null; then
    warn "Docker is already installed: $(docker --version)"
else
    curl -fsSL https://get.docker.com | sh
    ok "Docker installed: $(docker --version)"
fi

# ── Step 2: Remnanode directory & compose ──────────────────
step "Setting up Remnanode"

mkdir -p /opt/remnanode
info "Created /opt/remnanode"

cat > /opt/remnanode/docker-compose.yml << 'EOF'
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=""
    volumes:
      # - /dev/shm:/dev/shm:rw
      - ./geoip.dat:/usr/local/share/xray/geoip.dat:ro
      - ./geosite.dat:/usr/local/share/xray/geosite.dat:ro
      - ./ru-geoip.dat:/usr/local/share/xray/ru-geoip.dat:ro
      - ./ru-geosite.dat:/usr/local/share/xray/ru-geosite.dat:ro
      # - ./certs/cert.crt:/etc/xray/certs/cert.crt:ro
      # - ./certs/key.key:/etc/xray/certs/key.key:ro
EOF

ok "docker-compose.yml created"

# ── Step 3: Geo database update script & cron ──────────────
step "Configuring geo database updates"

cat > /opt/remnanode/update-geo.sh << 'SCRIPT'
#!/bin/bash

GEO_DIR="/opt/remnanode"
LOG_FILE="/var/log/xray-geo-update.log"

echo "$(date): Starting geo update" >> "$LOG_FILE"

# Download all files to temporary names first
if wget -q -O "$GEO_DIR/geoip.dat.new" \
     https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat && \
   wget -q -O "$GEO_DIR/geosite.dat.new" \
     https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat && \
   wget -q -O "$GEO_DIR/ru-geoip.dat.new" \
     https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat && \
   wget -q -O "$GEO_DIR/ru-geosite.dat.new" \
     https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat; then

  # All downloaded — atomic swap
  mv "$GEO_DIR/geoip.dat.new" "$GEO_DIR/geoip.dat"
  mv "$GEO_DIR/geosite.dat.new" "$GEO_DIR/geosite.dat"
  mv "$GEO_DIR/ru-geoip.dat.new" "$GEO_DIR/ru-geoip.dat"
  mv "$GEO_DIR/ru-geosite.dat.new" "$GEO_DIR/ru-geosite.dat"

  docker restart remnanode
  echo "$(date): Update successful, container restarted" >> "$LOG_FILE"
else
  # Download failed — clean up temp files
  rm -f "$GEO_DIR"/*.new
  echo "$(date): Download failed, no changes made" >> "$LOG_FILE"
fi
SCRIPT

chmod +x /opt/remnanode/update-geo.sh
ok "update-geo.sh created"

# Add to cron (daily at 04:00)
CRON_JOB="0 4 * * * /opt/remnanode/update-geo.sh"
(crontab -l 2>/dev/null | grep -v "update-geo.sh"; echo "$CRON_JOB") | crontab -
ok "Cron job added (daily at 04:00)"

# First run
info "Downloading geo databases (initial run)..."
/opt/remnanode/update-geo.sh
ok "Geo databases downloaded"

# ── Step 4: Kernel tuning ─────────────────────────────────
step "Applying kernel parameters"

cat > /etc/sysctl.d/99-optimal-vless.conf << 'EOF'
# ===== OPTIMAL VLESS SERVER CONFIG =====

fs.file-max=2097152
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# ---- Congestion Control (best for VLESS/YouTube) ----
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# ---- 4MB TCP Buffers = stable up to ~500 Mbps ----
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 262144 16777216

# ---- Fast Open ----
net.ipv4.tcp_fastopen = 3

# ---- Latency & stability improvements ----
net.ipv4.tcp_slow_start_after_idle = 0
# net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_ecn = 1

# ---- TIME-WAIT (optimal for 5-10 VLESS clients) ----
net.ipv4.tcp_max_tw_buckets = 20000

# ---- Queues (best for 1 CPU, low jitter) ----
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 2048
net.core.netdev_max_backlog = 2000

# ---- Keepalive for long VLESS connections ----
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 30

# ---- Security ----
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.log_martians = 0

# ---- TCP advanced ----
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

# ---- Memory tuning ----
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.max_map_count = 262144
EOF

sysctl --system > /dev/null 2>&1
ok "Kernel parameters applied"

# ── Summary ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║           Setup complete!                   ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Remnanode:${NC}      cd /opt/remnanode"
echo -e "  ${BOLD}Edit config:${NC}    nano /opt/remnanode/docker-compose.yml"
echo -e "  ${BOLD}Start:${NC}          docker compose up -d"
echo ""
echo -e "  ${YELLOW}Don't forget to set SECRET_KEY in docker-compose.yml${NC}"
echo ""
