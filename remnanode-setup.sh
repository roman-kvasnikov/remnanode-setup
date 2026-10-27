#!/usr/bin/env bash
#
# ╔══════════════════════════════════════════════════════════╗
# ║      Remnanode VPS Setup + Steal-from-Yourself Site      ║
# ║                                                          ║
# ║   Docker · Remnanode · Kernel tuning · Nginx · LE cert   ║
# ╚══════════════════════════════════════════════════════════╝
#
# Layout:
#   :80 (public)              nginx: ACME webroot challenge + redirect to HTTPS
#   127.0.0.1:NGINX_PORT      nginx: HTTPS camouflage site (Reality target)
#   NODE_PORT                 remnanode API (open it for the panel IP only)
#
# Certificates are issued/renewed by acme.sh in webroot mode, so nginx keeps
# port 80 and renewals do not need to stop anything.
#
# Optional env overrides: NGINX_PORT (default 7443), NODE_PORT (default 2222)
#

set -euo pipefail

NGINX_PORT="${NGINX_PORT:-7443}"
NODE_PORT="${NODE_PORT:-2222}"

TEMPLATES_URL="https://github.com/GFW4Fun/randomfakehtml/archive/refs/heads/master.zip"
ACME_ROOT="/var/www/acme"
NODE_DIR="/opt/remnanode"
NODE_LOG_DIR="/var/log/remnanode"
SYSCTL_CONF="/etc/sysctl.d/99-optimal-vless.conf"

# ── Colors & helpers ───────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

step_current=0
step_total=7

info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
die()   { error "$1"; exit 1; }

step() {
    step_current=$((step_current + 1))
    echo ""
    echo -e "${BOLD}${CYAN}═══ [${step_current}/${step_total}] $1 ═══${NC}"
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

# ── Pre-flight checks ─────────────────────────────────────
[[ $EUID -eq 0 ]] || die "This script must be run as root (sudo bash $0)"

# acme.sh refuses to install when launched via plain "sudo bash script",
# and must live in root's home regardless of how the script was started.
export HOME=/root
unset SUDO_USER SUDO_UID SUDO_GID SUDO_COMMAND

valid_port "$NGINX_PORT" || die "Invalid NGINX_PORT: $NGINX_PORT"
valid_port "$NODE_PORT"  || die "Invalid NODE_PORT: $NODE_PORT"
[[ "$NGINX_PORT" != "$NODE_PORT" ]] || die "NGINX_PORT and NODE_PORT must differ"

echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║       Remnanode VPS Setup — Starting...    ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════╝${NC}"

# ── Interactive input (everything asked up front) ─────────
echo ""
read -rp "$(echo -e "${BOLD}Domain name (e.g. your.domain.com):${NC} ")" DOMAIN
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN%%/*}"
DOMAIN="${DOMAIN,,}"
[[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] \
    || die "Invalid domain: '${DOMAIN}'"

read -rp "$(echo -e "${BOLD}E-mail for Let's Encrypt (Enter to skip):${NC} ")" ACME_EMAIL
read -rsp "$(echo -e "${BOLD}Remnanode SECRET_KEY (Enter to set later):${NC} ")" SECRET_KEY
echo ""

WEB_ROOT="/var/www/${DOMAIN}"
CERT_DIR="/etc/ssl/${DOMAIN}"
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
NGINX_LINK="/etc/nginx/sites-enabled/${DOMAIN}"
ACME="/root/.acme.sh/acme.sh"
ACME_DOMAIN_CONF="/root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.conf"

info "Domain:       ${DOMAIN}"
info "Nginx (TLS):  127.0.0.1:${NGINX_PORT}"
info "Node port:    ${NODE_PORT}"

# ── Step 1: Packages ──────────────────────────────────────
step "Installing packages"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates unzip cron logrotate nginx > /dev/null
systemctl enable --now cron > /dev/null 2>&1
ok "curl, unzip, cron, logrotate, nginx installed"

# ── Step 2: Kernel tuning ─────────────────────────────────
step "Applying kernel parameters"

cat > "$SYSCTL_CONF" << 'EOF'
# ---- Congestion control ----
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ---- TCP buffers (16 MB max) ----
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 262144 16777216

# ---- Latency & stability ----
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1

# ---- Keepalive for long-lived proxy connections ----
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

# ---- Hardening ----
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# ---- Memory ----
vm.swappiness = 10
EOF

modprobe tcp_bbr 2>/dev/null || true
echo tcp_bbr > /etc/modules-load.d/bbr.conf

sysctl --system > /dev/null || warn "Some sysctl keys were not applied (see errors above)"
if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]]; then
    ok "Kernel parameters applied (BBR active)"
else
    warn "Kernel parameters applied, but BBR is NOT active"
fi

# ── Step 3: Docker ────────────────────────────────────────
step "Installing Docker"

if command -v docker &>/dev/null; then
    ok "Docker already installed: $(docker --version)"
else
    curl -fsSL https://get.docker.com | sh
    ok "Docker installed: $(docker --version)"
fi
systemctl enable --now docker > /dev/null 2>&1

# ── Step 4: Camouflage website ────────────────────────────
step "Deploying random website template"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL -o "$TMP_DIR/templates.zip" "$TEMPLATES_URL"
unzip -q "$TMP_DIR/templates.zip" -d "$TMP_DIR"

shopt -s nullglob
templates=()
for dir in "$TMP_DIR"/randomfakehtml-master/*/; do
    [[ "$(basename "$dir")" == assets ]] && continue
    templates+=("$dir")
done
shopt -u nullglob
(( ${#templates[@]} > 0 )) || die "No templates found in archive"

template_dir="${templates[RANDOM % ${#templates[@]}]}"
TEMPLATE_NAME="$(basename "$template_dir")"

mkdir -p "$WEB_ROOT"
find "$WEB_ROOT" -mindepth 1 -delete
cp -a "${template_dir}." "$WEB_ROOT/"
chmod -R u=rwX,go=rX "$WEB_ROOT"
ok "Template '${TEMPLATE_NAME}' deployed to ${WEB_ROOT}"

# ── Nginx config renderer ─────────────────────────────────
# "http2 on;" exists only since nginx 1.25.1; older versions need "listen ... http2".
NGINX_VER="$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')"
if [[ "$(printf '%s\n' 1.25.1 "$NGINX_VER" | sort -V | head -n1)" == "1.25.1" ]]; then
    TLS_LISTEN="listen 127.0.0.1:${NGINX_PORT} ssl;
    http2 on;"
else
    TLS_LISTEN="listen 127.0.0.1:${NGINX_PORT} ssl http2;"
fi

# Listening on [::]:80 fails if IPv6 is disabled on the host.
LISTEN_V6=""
[[ -f /proc/net/if_inet6 ]] && LISTEN_V6="listen [::]:80;"

render_nginx_conf() {
    local with_tls="$1"

    cat > "$NGINX_CONF" << EOF
# Steal-from-Yourself: Reality target (managed by remnanode-setup.sh)

server {
    listen 80;
    ${LISTEN_V6}
    server_name ${DOMAIN};
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

    [[ "$with_tls" == yes ]] || return 0

    cat >> "$NGINX_CONF" << EOF

server {
    ${TLS_LISTEN}
    server_name ${DOMAIN};
    server_tokens off;

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/key.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;

    ssl_session_cache   shared:REALITY:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    root ${WEB_ROOT};
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
}
EOF
}

# ── Step 5: Certificate ───────────────────────────────────
step "Issuing Let's Encrypt certificate for ${DOMAIN}"

# Stage 1: HTTP-only config so nginx can serve the ACME challenge.
mkdir -p "$ACME_ROOT"
render_nginx_conf no
ln -sf "$NGINX_CONF" "$NGINX_LINK"
rm -f /etc/nginx/sites-enabled/default
nginx -t -q || die "nginx configuration test failed"
systemctl enable nginx > /dev/null 2>&1
systemctl restart nginx

if [[ ! -x "$ACME" ]]; then
    acme_install_args=()
    [[ -n "$ACME_EMAIL" ]] && acme_install_args=(-s "email=${ACME_EMAIL}")
    curl -fsSL https://get.acme.sh | sh "${acme_install_args[@]}"
    [[ -x "$ACME" ]] || die "acme.sh installation failed"
    ok "acme.sh installed"
else
    ok "acme.sh already installed"
fi

# Re-issue if the existing cert was obtained in another mode (e.g. standalone),
# otherwise renewals would try to bind port 80 that nginx now owns.
acme_force=()
if [[ -f "$ACME_DOMAIN_CONF" ]] && ! grep -q "^Le_Webroot='${ACME_ROOT}'" "$ACME_DOMAIN_CONF"; then
    warn "Existing certificate uses another validation mode, re-issuing in webroot mode"
    acme_force=(--force)
fi

acme_rc=0
"$ACME" --issue --server letsencrypt -d "$DOMAIN" -w "$ACME_ROOT" \
    --keylength ec-256 "${acme_force[@]}" || acme_rc=$?

case "$acme_rc" in
    0) ok "Certificate issued" ;;
    2) ok "Certificate is still valid, renewal not due" ;;
    *) die "Certificate issuance failed — check that the A record of ${DOMAIN} points to this server and port 80 is reachable" ;;
esac

mkdir -p "$CERT_DIR"
"$ACME" --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "$CERT_DIR/fullchain.pem" \
    --key-file "$CERT_DIR/key.pem" \
    --reloadcmd "systemctl reload nginx"
chmod 644 "$CERT_DIR/fullchain.pem"
chmod 600 "$CERT_DIR/key.pem"
ok "Certificate installed to ${CERT_DIR}"

# ── Step 6: Nginx HTTPS (Reality target) ──────────────────
step "Configuring nginx HTTPS"

render_nginx_conf yes
nginx -t -q || die "nginx configuration test failed"
systemctl reload nginx

http_code="$(curl -sk -o /dev/null -w '%{http_code}' \
    --resolve "${DOMAIN}:${NGINX_PORT}:127.0.0.1" "https://${DOMAIN}:${NGINX_PORT}/" || true)"
if [[ "$http_code" == 200 ]]; then
    ok "Site responds on 127.0.0.1:${NGINX_PORT} (HTTP ${http_code})"
else
    warn "Local check returned HTTP '${http_code}' — verify nginx manually"
fi

# ── Step 7: Remnanode ─────────────────────────────────────
step "Setting up Remnanode"

mkdir -p "$NODE_DIR" "$NODE_LOG_DIR"

# Keep an existing .env on re-run when no new key was entered.
if [[ -n "$SECRET_KEY" || ! -f "$NODE_DIR/.env" ]]; then
    umask 077
    printf 'NODE_PORT=%s\nSECRET_KEY=%s\n' "$NODE_PORT" "$SECRET_KEY" > "$NODE_DIR/.env"
    umask 022
fi

cat > "$NODE_DIR/docker-compose.yml" << EOF
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
    env_file: .env
    volumes:
      - ${NODE_LOG_DIR}:${NODE_LOG_DIR}:rw
      # Uncomment for TLS inbounds that need the certificate:
      # - ${CERT_DIR}/fullchain.pem:/etc/xray/certs/cert.crt:ro
      # - ${CERT_DIR}/key.pem:/etc/xray/certs/key.key:ro
EOF
ok "docker-compose.yml and .env written to ${NODE_DIR}"

cat > /etc/logrotate.d/remnanode << EOF
${NODE_LOG_DIR}/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF

if logrotate -d /etc/logrotate.d/remnanode > /dev/null 2>&1; then
    ok "Logrotate configured"
else
    warn "Logrotate configuration check failed"
fi

NODE_STARTED=no
if grep -q '^SECRET_KEY=.\+' "$NODE_DIR/.env"; then
    docker compose -f "$NODE_DIR/docker-compose.yml" up -d --pull always
    NODE_STARTED=yes
    ok "Remnanode started"
else
    warn "SECRET_KEY is empty — remnanode not started"
fi

# ── Summary ───────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║             Setup complete!                ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Domain:${NC}         ${DOMAIN}"
echo -e "  ${BOLD}Template:${NC}       ${TEMPLATE_NAME}"
echo -e "  ${BOLD}Web root:${NC}       ${WEB_ROOT}"
echo -e "  ${BOLD}Certificate:${NC}    ${CERT_DIR}/ (auto-renew via acme.sh cron)"
echo -e "  ${BOLD}Nginx config:${NC}   ${NGINX_CONF}"
echo -e "  ${BOLD}Remnanode:${NC}      ${NODE_DIR} (port ${NODE_PORT})"
echo ""
echo -e "  ${BOLD}${CYAN}Reality inbound settings:${NC}"
echo -e "    \"target\":      \"127.0.0.1:${NGINX_PORT}\""
echo -e "    \"serverNames\": [\"${DOMAIN}\"]"
echo ""
if [[ "$NODE_STARTED" == no ]]; then
    echo -e "  ${YELLOW}Set SECRET_KEY in ${NODE_DIR}/.env, then:${NC}"
    echo -e "    cd ${NODE_DIR} && docker compose up -d"
    echo ""
fi
echo -e "  ${BOLD}Re-randomize site:${NC} re-run this script (cert and .env are kept)"
echo ""
