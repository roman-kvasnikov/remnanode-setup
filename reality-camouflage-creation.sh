#!/usr/bin/env bash
#
# ╔══════════════════════════════════════════════════════════╗
# ║    Steal-from-Yourself — Reality Camouflage Website      ║
# ║                                                          ║
# ║    Nginx (localhost) · Let's Encrypt · Reality target    ║
# ╚══════════════════════════════════════════════════════════╝
#
# Nginx listens on 127.0.0.1:7443 (HTTPS) with a real LE certificate.
# Xray Reality forwards unauthenticated connections to this local nginx.
#
# Reality inbound config:
#   "target": "127.0.0.1:7443"
#   "serverNames": ["your.domain.com"]
#
# Port 80 is used temporarily by acme.sh for certificate issuance,
# then stays free (or you can optionally enable the redirect block).

set -euo pipefail

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
echo -e "${BOLD}${GREEN}║      Steal-from-Yourself — Starting...     ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════╝${NC}"

# ── Interactive input ──────────────────────────────────────
echo ""
read -rp "$(echo -e "${BOLD}Enter domain name (e.g. your.domain.com):${NC} ")" DOMAIN

if [[ -z "$DOMAIN" ]]; then
    error "Domain cannot be empty"
    exit 1
fi

DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN%%/*}"

info "Domain: ${DOMAIN}"

read -rp "$(echo -e "${BOLD}Enter E-Mail for Let's Encrypt (or press Enter to skip):${NC} ")" ACME_EMAIL
ACME_EMAIL="${ACME_EMAIL:-}"

# Internal port where nginx listens (localhost only)
NGINX_PORT=7443

read -rp "$(echo -e "${BOLD}Nginx internal HTTPS port [${NGINX_PORT}]:${NC} ")" CUSTOM_PORT
NGINX_PORT="${CUSTOM_PORT:-$NGINX_PORT}"

info "Nginx will listen on 127.0.0.1:${NGINX_PORT}"

REPO_DIR="$HOME/randomfakehtml-master"
WEB_ROOT="/var/www/${DOMAIN}"
INSTALL_CERT_DIR="/etc/ssl/${DOMAIN}"
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
NGINX_LINK="/etc/nginx/sites-enabled/${DOMAIN}"

# ── Step 1: Firewall (open port 80 early for acme.sh) ─────
step "Checking firewall"

if command -v ufw &>/dev/null && ufw status | grep -qw "active"; then
    ufw allow 80/tcp > /dev/null 2>&1
    ok "UFW: port 80 opened for certificate verification"
else
    info "UFW not active, make sure port 80 is reachable for certificate issuance"
fi

# ── Step 2: Dependencies ──────────────────────────────────
step "Installing dependencies"

apt update -qq
apt install -y -qq unzip wget curl socat nginx > /dev/null 2>&1

# Stop nginx so it does not occupy port 80
systemctl stop nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true

ok "nginx, unzip, wget, curl, socat installed"

# ── Step 3: Download templates ────────────────────────────
step "Preparing template repository"

if [[ -d "$REPO_DIR" ]]; then
    warn "Repository already exists, skipping download"
else
    info "Downloading template archive..."
    wget -q -O /tmp/randomfakehtml.zip \
        https://github.com/GFW4Fun/randomfakehtml/archive/refs/heads/master.zip
    unzip -q /tmp/randomfakehtml.zip -d "$HOME"
    rm -f /tmp/randomfakehtml.zip
    rm -rf "$REPO_DIR/assets"
    rm -f "$REPO_DIR/.gitattributes" "$REPO_DIR/README.md" "$REPO_DIR/_config.yml"
    ok "Templates downloaded and cleaned up"
fi

# ── Step 4: Deploy random template ────────────────────────
step "Deploying random template"

cd "$REPO_DIR"

templates=(*/)
if [[ ${#templates[@]} -eq 0 ]]; then
    error "No templates found in $REPO_DIR"
    exit 1
fi

random_template="${templates[$((RANDOM % ${#templates[@]}))]}"
random_template="${random_template%/}"
info "Selected template: ${random_template}"

mkdir -p "$WEB_ROOT"
rm -rf "${WEB_ROOT:?}"/*
cp -a "$REPO_DIR/$random_template/." "$WEB_ROOT/"
chmod 755 "$WEB_ROOT"
find "$WEB_ROOT" -type d -exec chmod 755 {} \;
find "$WEB_ROOT" -type f -exec chmod 644 {} \;
ok "Template deployed to $WEB_ROOT"

# ── Step 5: Install acme.sh ───────────────────────────────
step "Installing acme.sh"

if [[ -f "$HOME/.acme.sh/acme.sh" ]]; then
    warn "acme.sh is already installed"
else
    curl -fsSL https://get.acme.sh | sh
    ok "acme.sh installed"
fi

source "$HOME/.acme.sh/acme.sh.env" 2>/dev/null || true

if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
    error "acme.sh installation failed — binary not found"
    exit 1
fi

# ── Step 6: Issue certificate ─────────────────────────────
step "Issuing Let's Encrypt certificate for ${DOMAIN}"

ACME_ARGS=(
    --issue
    -d "$DOMAIN"
    --standalone
    --keylength ec-256
)

if [[ -n "$ACME_EMAIL" ]]; then
    ACME_ARGS+=(--accountemail "$ACME_EMAIL")
fi

# Only force re-issue if cert does not exist yet
if [[ ! -f "$HOME/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.cer" ]]; then
    ACME_ARGS+=(--force)
fi

if "$HOME/.acme.sh/acme.sh" "${ACME_ARGS[@]}"; then
    ok "Certificate issued successfully"
else
    warn "Certificate may already exist or issuance failed"
    warn "Make sure DNS A-record for ${DOMAIN} points to this server"
fi

# Install certificate to a stable path
mkdir -p "$INSTALL_CERT_DIR"

"$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "$INSTALL_CERT_DIR/fullchain.pem" \
    --key-file "$INSTALL_CERT_DIR/key.pem" \
    --reloadcmd "systemctl reload nginx || true"

ok "Certificate installed to $INSTALL_CERT_DIR"

# ── Step 7: Configure nginx ───────────────────────────────
step "Configuring nginx"

cat > "$NGINX_CONF" << NGINX
# ╔═══════════════════════════════════════════════════════╗
# ║  Steal-from-Yourself: Nginx for Reality target        ║
# ║  Listens on 127.0.0.1:${NGINX_PORT} only (not public) ║
# ╚═══════════════════════════════════════════════════════╝

# ── Local HTTPS for Reality target ─────────────────────
server {
    listen 127.0.0.1:${NGINX_PORT} ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     ${INSTALL_CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${INSTALL_CERT_DIR}/key.pem;

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

    # Security headers
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
}

# ── Optional: HTTP redirect to HTTPS (uncomment if needed) ──
# Useful if you want the domain to work in a browser via port 80.
# Note: port 80 must not conflict with other services.
#
# server {
#     listen 80;
#     listen [::]:80;
#     server_name ${DOMAIN};
#     return 301 https://\$host\$request_uri;
# }
NGINX

ok "Nginx config created: $NGINX_CONF"

# Enable site, disable default
ln -sf "$NGINX_CONF" "$NGINX_LINK"
rm -f /etc/nginx/sites-enabled/default

# Handle older nginx without standalone "http2 on"
if ! nginx -t 2>/dev/null; then
    warn "nginx does not support 'http2 on' directive, falling back to listen-level http2"
    sed -i 's/listen 127.0.0.1:'"${NGINX_PORT}"' ssl;/listen 127.0.0.1:'"${NGINX_PORT}"' ssl http2;/' "$NGINX_CONF"
    sed -i '/^\s*http2 on;/d' "$NGINX_CONF"
fi

if nginx -t 2>/dev/null; then
    systemctl enable nginx
    systemctl restart nginx
    ok "Nginx is running on 127.0.0.1:${NGINX_PORT}"
else
    error "Nginx configuration test failed:"
    nginx -t
    exit 1
fi

# Verify nginx is actually listening
sleep 1
if ss -tlnp | grep -q ":${NGINX_PORT}"; then
    ok "Confirmed: nginx listening on 127.0.0.1:${NGINX_PORT}"
else
    warn "Could not confirm nginx is listening — check manually"
fi

# ── Summary ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║           Deployment complete!             ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Domain:${NC}         ${DOMAIN}"
echo -e "  ${BOLD}Template:${NC}       ${random_template}"
echo -e "  ${BOLD}Web root:${NC}       ${WEB_ROOT}"
echo -e "  ${BOLD}Certificate:${NC}    ${INSTALL_CERT_DIR}/"
echo -e "  ${BOLD}Nginx config:${NC}   ${NGINX_CONF}"
echo -e "  ${BOLD}Nginx address:${NC}  127.0.0.1:${NGINX_PORT}"
echo ""
echo -e "  ${BOLD}${CYAN}Reality inbound settings:${NC}"
echo -e "    \"target\":      \"127.0.0.1:${NGINX_PORT}\""
echo -e "    \"serverNames\": [\"${DOMAIN}\"]"
echo ""
echo -e "  ${BOLD}Verify locally:${NC}"
echo -e "    curl -k https://127.0.0.1:${NGINX_PORT} --resolve ${DOMAIN}:${NGINX_PORT}:127.0.0.1"
echo ""
echo -e "  ${BOLD}Re-randomize:${NC}   bash $0  (picks new template, keeps cert)"
echo -e "  ${BOLD}Cert renewal:${NC}   automatic via acme.sh cron"
echo ""
