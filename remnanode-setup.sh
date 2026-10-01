#!/usr/bin/env bash
#
# ╔══════════════════════════════════════════════════════════╗
# ║     Ubuntu VPS Initial Setup — Remnanode Deployment      ║
# ║                                                          ║
# ║                  Docker · Kernel tuning                  ║
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

mkdir -p /var/log/remnanode
info "Created /var/log/remnanode"

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
      - SECRET_KEY=
    volumes:
      # - /dev/shm:/dev/shm:rw
      - /var/log/remnanode:/var/log/remnanode:rw
      # - /etc/ssl/domain.com/fullchain.pem:/etc/xray/certs/cert.crt:ro
      # - /etc/ssl/domain.com/key.pem:/etc/xray/certs/key.key:ro
EOF

ok "docker-compose.yml created"

# ── Step 3: Configuring logrotate ──────────────────────────

step "Configuring logrotate"

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y logrotate

cat > /etc/logrotate.d/remnanode << 'EOF'
/var/log/remnanode/*.log {
      size 50M
      rotate 5
      compress
      missingok
      notifempty
      copytruncate
}
EOF

logrotate -d /etc/logrotate.d/remnanode > /dev/null 2>&1

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

# ---- 16MB TCP Buffers = stable up to ~500 Mbps ----
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 262144 16777216

# ---- Fast Open ----
net.ipv4.tcp_fastopen = 3

# ---- Latency & stability improvements ----
net.ipv4.tcp_slow_start_after_idle = 0
# net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 1

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

modprobe tcp_bbr 2>/dev/null || true
echo tcp_bbr > /etc/modules-load.d/bbr.conf

sysctl --system > /dev/null
if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == bbr ]]; then
   ok "Kernel parameters applied (BBR active)"
else
   warn "Kernel parameters applied, but BBR is NOT active"
fi

# ── Summary ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║           Setup complete!                  ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Remnanode:${NC}      cd /opt/remnanode"
echo -e "  ${BOLD}Edit config:${NC}    nano /opt/remnanode/docker-compose.yml"
echo -e "  ${BOLD}Start:${NC}          docker compose up -d"
echo ""
echo -e "  ${YELLOW}Don't forget to set SECRET_KEY in docker-compose.yml${NC}"
echo ""
