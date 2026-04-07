#!/usr/bin/env bash
#
# ╔═════════════════════════════════════════════════════════╗
# ║    Random Fake Website — Full Deployment                ║
# ║                                                         ║
# ║    Nginx · Let's Encrypt (acme.sh) · HTTPS on 443+8443  ║
# ╚═════════════════════════════════════════════════════════╝
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
echo -e "${BOLD}${GREEN}║   Random Fake Website — Full Deployment    ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════╝${NC}"

# ── Interactive input ──────────────────────────────────────
echo ""
read -rp "$(echo -e "${BOLD}Enter domain name (e.g. site.example.com):${NC} ")" DOMAIN

if [[ -z "$DOMAIN" ]]; then
    error "Domain cannot be empty"
    exit 1
fi

# Strip protocol prefix if user pasted a URL
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN%%/*}"

info "Domain: ${DOMAIN}"

read -rp "$(echo -e "${BOLD}Enter email for Let's Encrypt (or press Enter to skip):${NC} ")" ACME_EMAIL
ACME_EMAIL="${ACME_EMAIL:-}"

REPO_DIR="$HOME/randomfakehtml-master"
WEB_ROOT="/var/www/${DOMAIN}"
CERT_DIR="/root/.acme.sh/${DOMAIN}_ecc"
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
NGINX_LINK="/etc/nginx/sites-enabled/${DOMAIN}"

# ── Step 1: Dependencies ──────────────────────────────────
step "Installing dependencies"

apt update -qq
apt install -y -qq unzip wget curl socat nginx > /dev/null 2>&1
ok "nginx, unzip, wget, curl, socat installed"

# ── Step 2: Download templates ────────────────────────────
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

# ── Step 3: Deploy random template ────────────────────────
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
ok "Template deployed to $WEB_ROOT"

# ── Step 4: Install acme.sh ───────────────────────────────
step "Installing acme.sh"

if [[ -f "$HOME/.acme.sh/acme.sh" ]]; then
    warn "acme.sh is already installed"
else
    curl -fsSL https://get.acme.sh | sh
    ok "acme.sh installed"
fi

# Source acme.sh environment
source "$HOME/.acme.sh/acme.sh.env" 2>/dev/null || true

if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
    error "acme.sh installation failed — binary not found"
    exit 1
fi

# ── Step 5: Issue certificate ─────────────────────────────
step "Issuing Let's Encrypt certificate for ${DOMAIN}"

# Stop nginx temporarily so acme.sh can use port 80 (standalone mode)
systemctl stop nginx 2>/dev/null || true

ACME_ARGS=(
    --issue
    -d "$DOMAIN"
    --standalone
    --keylength ec-256
    --force
)

if [[ -n "$ACME_EMAIL" ]]; then
    ACME_ARGS+=(--accountemail "$ACME_EMAIL")
fi

if "$HOME/.acme.sh/acme.sh" "${ACME_ARGS[@]}"; then
    ok "Certificate issued successfully"
else
    error "Certificate issuance failed. Make sure DNS for ${DOMAIN} points to this server"
    systemctl start nginx 2>/dev/null || true
    exit 1
fi

# Install certificate to a stable path
INSTALL_CERT_DIR="/etc/ssl/${DOMAIN}"
mkdir -p "$INSTALL_CERT_DIR"

"$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "$INSTALL_CERT_DIR/fullchain.pem" \
    --key-file "$INSTALL_CERT_DIR/key.pem" \
    --reloadcmd "systemctl reload nginx"

ok "Certificate installed to $INSTALL_CERT_DIR"

# ── Step 6: Configure nginx ───────────────────────────────
step "Configuring nginx"

cat > "$NGINX_CONF" << NGINX
# ── HTTP → HTTPS redirect ─────────────────────────────────
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

# ── HTTPS on port 443 ─────────────────────────────────────
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     ${INSTALL_CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${INSTALL_CERT_DIR}/key.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;

    ssl_session_cache   shared:SSL:10m;
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

# ── HTTPS on port 8443 (mirror) ───────────────────────────
server {
    listen 8443 ssl;
    listen [::]:8443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     ${INSTALL_CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${INSTALL_CERT_DIR}/key.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;

    ssl_session_cache   shared:SSL_ALT:10m;
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
NGINX

ok "Nginx config created: $NGINX_CONF"

# Enable site, disable default if present
ln -sf "$NGINX_CONF" "$NGINX_LINK"
rm -f /etc/nginx/sites-enabled/default

# Test and start
if nginx -t 2>/dev/null; then
    systemctl enable nginx
    systemctl restart nginx
    ok "Nginx is running"
else
    error "Nginx configuration test failed:"
    nginx -t
    exit 1
fi

# ── Step 7: Firewall ──────────────────────────────────────
step "Checking firewall"

if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
    ufw allow 80/tcp   > /dev/null 2>&1
    ufw allow 443/tcp  > /dev/null 2>&1
    ufw allow 8443/tcp > /dev/null 2>&1
    ok "UFW rules added for ports 80, 443, 8443"
else
    info "UFW not active, skipping (make sure ports 80, 443, 8443 are open)"
fi

# ── Summary ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║           Deployment complete!             ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Domain:${NC}       ${DOMAIN}"
echo -e "  ${BOLD}Template:${NC}     ${random_template}"
echo -e "  ${BOLD}Web root:${NC}     ${WEB_ROOT}"
echo -e "  ${BOLD}Certificate:${NC}  ${INSTALL_CERT_DIR}/"
echo -e "  ${BOLD}Nginx config:${NC} ${NGINX_CONF}"
echo ""
echo -e "  ${BOLD}URLs:${NC}"
echo -e "    ${CYAN}https://${DOMAIN}${NC}       (port 443)"
echo -e "    ${CYAN}https://${DOMAIN}:8443${NC}  (port 8443)"
echo -e "    ${CYAN}http://${DOMAIN}${NC}        (redirects to HTTPS)"
echo ""
echo -e "  ${BOLD}Re-randomize:${NC} bash $0  (new template, same cert)"
echo -e "  ${BOLD}Cert renewal:${NC} automatic via acme.sh cron"
echo ""
