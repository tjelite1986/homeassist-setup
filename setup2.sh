#!/bin/bash
set -e

# =============================================================================
# Home Assistant — Post-setup Script
# Installs HACS, downloads frontend cards, theme and configures Lovelace
# Run this AFTER setup.sh and AFTER completing HA onboarding in the browser
# =============================================================================

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
RESET="\033[0m"

info()    { echo -e "${GREEN}[INFO]${RESET} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $1"; }
error()   { echo -e "${RED}[ERROR]${RESET} $1"; exit 1; }
section() { echo -e "\n${BOLD}=== $1 ===${RESET}"; }

# =============================================================================
# ROOT CHECK
# =============================================================================
if [ "$EUID" -eq 0 ]; then
  error "Do not run this script as root."
fi

# =============================================================================
# WELCOME
# =============================================================================
clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Home Assistant — Post-setup Script (step 2/2)     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo "This script will:"
echo "  - Install HACS"
echo "  - Download and install frontend cards"
echo "  - Install UI Lovelace Minimalist theme"
echo "  - Configure Lovelace dashboard resources"
echo ""
echo -e "${YELLOW}Requirement: HA onboarding must be completed in the browser first.${RESET}"
echo ""
read -rp "Have you completed the HA onboarding? (y/n): " ONBOARDED
if [[ ! "$ONBOARDED" =~ ^[Yy]$ ]]; then
  echo ""
  echo "Please complete the onboarding first:"
  echo "  1. Open http://$(hostname -I | awk '{print $1}'):8123"
  echo "  2. Create your account and follow the setup wizard"
  echo "  3. Run this script again"
  exit 0
fi

# =============================================================================
# FIND .env FILE
# =============================================================================
section "Configuration"

echo ""
read -rp "Docker compose directory from setup.sh [default: $HOME/docker]: " INPUT_DOCKERDIR
DOCKERDIR="${INPUT_DOCKERDIR:-$HOME/docker}"

ENV_FILE="$DOCKERDIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  error ".env not found at $ENV_FILE — make sure you ran setup.sh first and entered the correct directory."
fi

# Read values from .env
DATADIR=$(grep "^DATADIR=" "$ENV_FILE" | cut -d= -f2)
DOMAIN=$(grep "^DOMAIN=" "$ENV_FILE" | cut -d= -f2)

if [ -z "$DATADIR" ] || [ -z "$DOMAIN" ]; then
  error "Could not read DATADIR or DOMAIN from $ENV_FILE"
fi

HA_CONFIG="$DATADIR/ha"
HA_URL="http://localhost:8123"

echo ""
info "Using HA config dir: $HA_CONFIG"
info "Domain: $DOMAIN"

# =============================================================================
# WAIT FOR HA TO BE READY
# =============================================================================
section "Waiting for Home Assistant"

info "Checking HA API..."
ATTEMPTS=0
MAX_ATTEMPTS=30
until curl -sf "$HA_URL/api/" -o /dev/null 2>/dev/null; do
  ATTEMPTS=$((ATTEMPTS + 1))
  if [ $ATTEMPTS -ge $MAX_ATTEMPTS ]; then
    error "HA did not respond after ${MAX_ATTEMPTS} attempts. Is it running? Check: docker logs homeassistant --tail 30"
  fi
  echo -n "."
  sleep 3
done
echo ""
info "Home Assistant is up."

# =============================================================================
# INSTALL HACS
# =============================================================================
section "HACS Installation"

if [ -d "$HA_CONFIG/custom_components/hacs" ]; then
  info "HACS already installed — skipping."
else
  info "Installing HACS..."
  docker exec -it homeassistant bash -c "wget -q -O - https://get.hacs.xyz | bash -" || \
    error "HACS installation failed. Check docker logs homeassistant."
  info "HACS installed."
fi

# =============================================================================
# DOWNLOAD FRONTEND CARDS
# =============================================================================
section "Frontend cards"

COMMUNITY_DIR="$HA_CONFIG/www/community"
mkdir -p "$COMMUNITY_DIR"

download_card() {
  local NAME="$1"
  local DIR="$2"
  local URL="$3"
  local FILE="$4"

  mkdir -p "$COMMUNITY_DIR/$DIR"
  if [ -f "$COMMUNITY_DIR/$DIR/$FILE" ]; then
    info "$NAME already exists — skipping."
    return
  fi

  info "Downloading $NAME..."
  if wget -q -L "$URL" -O "$COMMUNITY_DIR/$DIR/$FILE"; then
    info "$NAME downloaded."
  else
    warn "$NAME download failed — you can install it manually via HACS later."
    rm -f "$COMMUNITY_DIR/$DIR/$FILE"
  fi
}

# button-card
download_card "button-card" \
  "button-card" \
  "https://github.com/custom-cards/button-card/releases/latest/download/button-card.js" \
  "button-card.js"

# mushroom
download_card "mushroom" \
  "lovelace-mushroom" \
  "https://github.com/piitaya/lovelace-mushroom/releases/latest/download/mushroom.js" \
  "mushroom.js"

# card-mod (no release binary — use jsdelivr CDN)
download_card "card-mod" \
  "lovelace-card-mod" \
  "https://cdn.jsdelivr.net/gh/thomasloven/lovelace-card-mod@master/card-mod.js" \
  "card-mod.js"

# mini-graph-card
download_card "mini-graph-card" \
  "mini-graph-card" \
  "https://github.com/kalkih/mini-graph-card/releases/latest/download/mini-graph-card-bundle.js" \
  "mini-graph-card-bundle.js"

# layout-card (no release binary — use jsdelivr CDN)
download_card "layout-card" \
  "lovelace-layout-card" \
  "https://cdn.jsdelivr.net/gh/thomasloven/lovelace-layout-card@master/layout-card.js" \
  "layout-card.js"

# expander-card
download_card "expander-card" \
  "lovelace-expander-card" \
  "https://github.com/MelleD/lovelace-expander-card/releases/latest/download/expander-card.js" \
  "expander-card.js"

# =============================================================================
# UI LOVELACE MINIMALIST
# =============================================================================
section "UI Lovelace Minimalist"

ULM_DIR="$HA_CONFIG/custom_components/ui_lovelace_minimalist"

if [ -d "$ULM_DIR" ]; then
  info "UI Lovelace Minimalist already installed — skipping."
else
  info "Downloading UI Lovelace Minimalist..."
  TMP_ZIP=$(mktemp /tmp/ulm_XXXXXX.zip)
  if wget -q "https://github.com/UI-Lovelace-Minimalist/UI/releases/latest/download/ui_lovelace_minimalist.zip" -O "$TMP_ZIP"; then
    info "Extracting..."
    mkdir -p "$ULM_DIR"
    unzip -q "$TMP_ZIP" -d "$HA_CONFIG/custom_components/"
    rm -f "$TMP_ZIP"
    info "UI Lovelace Minimalist installed."
  else
    warn "Download failed — install manually via HACS later."
    rm -f "$TMP_ZIP"
  fi
fi

# =============================================================================
# MINIMALIST CUSTOM THEME
# =============================================================================
section "Custom theme"

THEME_DIR="$HA_CONFIG/themes/minimalist-desktop"
mkdir -p "$THEME_DIR"

if [ -f "$THEME_DIR/minimalist-custom.yaml" ]; then
  info "Theme already exists — skipping."
else
  cat > "$THEME_DIR/minimalist-custom.yaml" <<'EOF'
---
minimalist-custom:
  border-radius: "20px"
  ha-card-border-radius: "var(--border-radius)"
  ha-card-border-width: "0px"
  text-divider-color: "rgba(var(--color-theme),.4)"
  text-divider-font-size: "17px"
  text-divider-line-size: "5px"
  text-divider-margin: "5px"
  accent-color: "var(--google-yellow)"
  divider-color: "rgba(var(--color-theme),.12)"

  card-mod-theme: "minimalist-desktop"
  modes:
    light:
      primary-text-color: "#212121"
      primary-color: "#434343"
      google-red: "#F54436"
      google-green: "#01C852"
      google-yellow: "#FF9101"
      google-blue: "#3D5AFE"
      color-theme: "51,51,51"
    dark:
      primary-text-color: "#e1e1e1"
      primary-color: "#c2c2c2"
      google-red: "#CF6679"
      google-green: "#01C852"
      google-yellow: "#FF9101"
      google-blue: "#3D5AFE"
      color-theme: "200,200,200"
EOF
  info "Theme written."
fi

# =============================================================================
# DASHBOARD RESOURCES
# =============================================================================
section "Lovelace dashboard resources"

DASHBOARD="$HA_CONFIG/dashboard/dashboard.yaml"
mkdir -p "$HA_CONFIG/dashboard"

# Only add resources block if not already present
if [ ! -f "$DASHBOARD" ] || ! grep -q "resources:" "$DASHBOARD"; then
  info "Adding Lovelace resources to dashboard.yaml..."

  # Prepend resources block to existing dashboard or create new one
  RESOURCES=$(cat <<'EOF'
resources:
  - url: /local/community/button-card/button-card.js
    type: module
  - url: /local/community/lovelace-mushroom/mushroom.js
    type: module
  - url: /local/community/lovelace-card-mod/card-mod.js
    type: module
  - url: /local/community/mini-graph-card/mini-graph-card-bundle.js
    type: module
  - url: /local/community/lovelace-layout-card/layout-card.js
    type: module
  - url: /local/community/lovelace-expander-card/expander-card.js
    type: module

EOF
)

  if [ -f "$DASHBOARD" ]; then
    # Prepend resources to existing file
    TMP=$(mktemp)
    echo "$RESOURCES" > "$TMP"
    cat "$DASHBOARD" >> "$TMP"
    mv "$TMP" "$DASHBOARD"
  else
    # Create new dashboard file
    cat > "$DASHBOARD" <<'YAML'
title: Home
views:
  - title: Home
    path: home
    type: masonry
    cards:
      - type: markdown
        content: "## Welcome home!"
YAML
    echo "$RESOURCES" | cat - "$DASHBOARD" > /tmp/dash_tmp && mv /tmp/dash_tmp "$DASHBOARD"
  fi

  info "Resources added."
else
  info "Resources already present in dashboard.yaml — skipping."
fi

# =============================================================================
# RESTART HA
# =============================================================================
section "Restarting Home Assistant"

info "Restarting HA to load HACS and new components..."
docker restart homeassistant

info "Waiting for HA to come back up..."
sleep 10
ATTEMPTS=0
until curl -sf "$HA_URL/api/" -o /dev/null 2>/dev/null; do
  ATTEMPTS=$((ATTEMPTS + 1))
  if [ $ATTEMPTS -ge 40 ]; then
    warn "HA is taking a long time to restart. Check: docker logs homeassistant --tail 30"
    break
  fi
  echo -n "."
  sleep 3
done
echo ""
info "Home Assistant is back up."

# =============================================================================
# DONE
# =============================================================================
section "Done"

echo ""
echo -e "${GREEN}${BOLD}Setup complete!${RESET}"
echo ""
echo -e "${CYAN}Cards installed:${RESET}"
echo "  - button-card"
echo "  - mushroom"
echo "  - card-mod"
echo "  - mini-graph-card"
echo "  - layout-card"
echo "  - expander-card"
echo ""
echo -e "${YELLOW}Remaining manual steps:${RESET}"
echo ""
echo -e "  ${BOLD}1. Activate HACS${RESET}"
echo "     Settings → Devices & Services → Add integration → HACS"
echo "     (requires GitHub account authentication)"
echo ""
echo -e "  ${BOLD}2. Activate UI Lovelace Minimalist${RESET}"
echo "     Settings → Devices & Services → Add integration → UI Lovelace Minimalist"
echo ""
echo -e "  ${BOLD}3. Install via HACS (no direct download available):${RESET}"
echo "     - mini-media-player"
echo "     - browser_mod"
echo ""
echo -e "  ${BOLD}4. Set theme${RESET}"
echo "     Profile → Theme → minimalist-custom"
echo ""
echo "  HA: http://$(hostname -I | awk '{print $1}'):8123"
echo ""
