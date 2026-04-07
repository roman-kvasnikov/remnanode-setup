#!/usr/bin/env bash
#
# ╔══════════════════════════════════════════════════════════╗
# ║        Random Fake Website — Template Deployer           ║
# ║                                                          ║
# ║         Download · Randomize · Deploy to /var/www/html   ║
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
step_total=3

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
echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║   Random Fake Website — Starting...   ║${NC}"
echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════╝${NC}"

REPO_DIR="$HOME/randomfakehtml-master"
WEB_ROOT="/var/www/html"

# ── Step 1: Dependencies ──────────────────────────────────
step "Checking dependencies"

if command -v unzip &>/dev/null; then
    ok "unzip is already installed"
else
    apt install -y unzip
    ok "unzip installed"
fi

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

# Collect only directories (each directory = one template)
templates=(*/)
if [[ ${#templates[@]} -eq 0 ]]; then
    error "No templates found in $REPO_DIR"
    exit 1
fi

random_template="${templates[$((RANDOM % ${#templates[@]}))]}"
random_template="${random_template%/}"   # strip trailing slash
info "Selected template: ${random_template}"

if [[ ! -d "$WEB_ROOT" ]]; then
    mkdir -p "$WEB_ROOT"
    info "Created $WEB_ROOT"
fi

rm -rf "${WEB_ROOT:?}"/*
cp -a "$REPO_DIR/$random_template/." "$WEB_ROOT/"
ok "Template deployed to $WEB_ROOT"

# ── Summary ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║           Deployment complete!        ║${NC}"
echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Template:${NC}    ${random_template}"
echo -e "  ${BOLD}Web root:${NC}    ${WEB_ROOT}"
echo -e "  ${BOLD}Re-run:${NC}      bash $0  (to pick another random template)"
echo ""
