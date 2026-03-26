#!/bin/bash
set -e

# =============================================================================
# Home Assistant + Traefik — Automated Setup Script
# Usage: ./setup.sh [--dry-run]
# =============================================================================

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
RESET="\033[0m"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

info()    { echo -e "${GREEN}[INFO]${RESET} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $1"; }
error()   { echo -e "${RED}[ERROR]${RESET} $1"; exit 1; }
section() { echo -e "\n${BOLD}=== $1 ===${RESET}"; }
dryinfo() { echo -e "${CYAN}[DRY-RUN]${RESET} $1"; }

# Wrapper: run a command or print it in dry-run mode
run() {
  if $DRY_RUN; then
    dryinfo "Would run: $*"
  else
    "$@"
  fi
}

# Write a file or print its content in dry-run mode
writefile() {
  local dest="$1"
  local content="$2"
  if $DRY_RUN; then
    dryinfo "Would write file: $dest"
    echo -e "${CYAN}--- content ---${RESET}"
    echo "$content"
    echo -e "${CYAN}--- end ---${RESET}"
  else
    echo "$content" > "$dest"
  fi
}

# =============================================================================
# ROOT CHECK
# =============================================================================
if [ "$EUID" -eq 0 ]; then
  error "Do not run this script as root. Run as your normal user."
fi

# =============================================================================
# WELCOME
# =============================================================================
clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║     Home Assistant + Traefik — Setup Script         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo "This script will:"
echo "  - Install Docker (if not installed)"
echo "  - Create all required directories and config files"
echo "  - Set up Traefik and Home Assistant via Docker Compose"
echo "  - Configure SSL via Cloudflare DNS challenge"
echo ""
if $DRY_RUN; then
  echo -e "${CYAN}DRY-RUN MODE — no files will be written, no commands will be executed.${RESET}"
  echo ""
fi
read -rp "Press ENTER to continue or Ctrl+C to abort..."

# =============================================================================
# GATHER INPUT
# =============================================================================
section "Configuration"

# Docker directory
echo ""
read -rp "Docker compose files directory [default: $HOME/docker]: " INPUT_DOCKERDIR
DOCKERDIR="${INPUT_DOCKERDIR:-$HOME/docker}"

# Data directory
read -rp "Persistent data directory [default: $HOME/dockdata]: " INPUT_DATADIR
DATADIR="${INPUT_DATADIR:-$HOME/dockdata}"

# Domain
while true; do
  read -rp "Your domain (e.g. myhome.com): " DOMAIN
  [[ -n "$DOMAIN" ]] && break
  warn "Domain cannot be empty."
done

# Subdomain for HA
read -rp "Subdomain for Home Assistant [default: home]: " INPUT_SUB
HA_SUB="${INPUT_SUB:-home}"

# Timezone
read -rp "Timezone [default: Europe/London]: " INPUT_TZ
TZ="${INPUT_TZ:-Europe/London}"

# Cloudflare
echo ""
echo "--- Cloudflare credentials ---"
while true; do
  read -rp "Cloudflare account email: " CF_EMAIL
  [[ -n "$CF_EMAIL" ]] && break
  warn "Email cannot be empty."
done

while true; do
  read -rsp "Cloudflare API token: " CF_TOKEN
  echo ""
  [[ -n "$CF_TOKEN" ]] && break
  warn "Token cannot be empty."
done

# PUID/PGID
PUID=$(id -u)
PGID=$(id -g)
USERNAME=$(whoami)

# Summary
echo ""
section "Summary"
echo "  Docker dir  : $DOCKERDIR"
echo "  Data dir    : $DATADIR"
echo "  Domain      : $DOMAIN"
echo "  HA URL      : https://${HA_SUB}.${DOMAIN}"
echo "  Timezone    : $TZ"
echo "  CF email    : $CF_EMAIL"
echo "  CF token    : ${CF_TOKEN:0:6}************************"
echo "  PUID/PGID   : $PUID/$PGID"
echo ""
read -rp "Looks good? Press ENTER to start or Ctrl+C to abort..."

# =============================================================================
# STEP 1 — INSTALL DOCKER
# =============================================================================
section "Step 1 — Docker"

if command -v docker &>/dev/null; then
  info "Docker already installed: $(docker --version)"
else
  info "Installing Docker..."
  run curl -fsSL https://get.docker.com | sh
  run sudo usermod -aG docker "$USERNAME"
  info "Docker installed. NOTE: You may need to log out and back in for group changes to take effect."
fi

if ! docker compose version &>/dev/null; then
  info "Installing Docker Compose plugin..."
  run sudo apt-get install -y docker-compose-plugin
fi

if ! $DRY_RUN; then
  info "Docker Compose: $(docker compose version)"
fi

# =============================================================================
# STEP 2 — DIRECTORIES
# =============================================================================
section "Step 2 — Directories"

run mkdir -p "$DOCKERDIR/traefik"
run mkdir -p "$DOCKERDIR/smart-home/homeassistant"
run mkdir -p "$DOCKERDIR/logs/traefik"
run mkdir -p "$DATADIR/ha"

run touch "$DOCKERDIR/traefik/acme.json"
run chmod 600 "$DOCKERDIR/traefik/acme.json"

info "Directories created."

# =============================================================================
# STEP 3 — DOCKER NETWORKS
# =============================================================================
section "Step 3 — Docker networks"

if $DRY_RUN; then
  dryinfo "Would run: docker network create traefik (if not exists)"
  dryinfo "Would run: docker network create smart_home (if not exists)"
else
  docker network inspect traefik &>/dev/null || docker network create traefik
  docker network inspect smart_home &>/dev/null || docker network create smart_home
fi

info "Networks ready."

# =============================================================================
# STEP 4 — .env FILE
# =============================================================================
section "Step 4 — Environment file"

if $DRY_RUN; then
  dryinfo "Would write: $DOCKERDIR/.env"
  dryinfo "  PUID=$PUID PGID=$PGID TZ=$TZ DOMAIN=$DOMAIN"
else
  cat > "$DOCKERDIR/.env" <<EOF
PUID=$PUID
PGID=$PGID
TZ=$TZ
DOMAIN=$DOMAIN
DOCKERDIR=$DOCKERDIR
DATADIR=$DATADIR

# Cloudflare
CF_API_EMAIL=$CF_EMAIL
CF_DNS_API_TOKEN=$CF_TOKEN
EOF
  chmod 600 "$DOCKERDIR/.env"
fi
info ".env created."

# =============================================================================
# STEP 5 — TRAEFIK CONFIG FILES
# =============================================================================
section "Step 5 — Traefik config"

if $DRY_RUN; then
  dryinfo "Would write: $DOCKERDIR/traefik/traefik.yml"
  dryinfo "Would write: $DOCKERDIR/traefik/config.yml"
else
  cat > "$DOCKERDIR/traefik/traefik.yml" <<EOF
api:
  dashboard: false
  debug: false

entryPoints:
  http:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: https
          scheme: https
  https:
    address: ":443"

serversTransport:
  insecureSkipVerify: true

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: true
  file:
    filename: /config.yml

certificatesResolvers:
  cloudflare:
    acme:
      email: $CF_EMAIL
      storage: "acme.json"
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - "1.1.1.1:53"
          - "1.0.0.1:53"
EOF

  cat > "$DOCKERDIR/traefik/config.yml" <<'EOF'
http:
  middlewares:
    default-headers:
      headers:
        frameDeny: true
        sslRedirect: true
        browserXssFilter: true
        contentTypeNosniff: true
        forceSTSHeader: true
        stsIncludeSubdomains: true
        stsPreload: true
        stsSeconds: 15552000
        customFrameOptionsValue: SAMEORIGIN
        customRequestHeaders:
          X-Forwarded-Proto: https

    default-whitelist:
      ipAllowList:
        sourceRange:
          - "10.0.0.0/8"
          - "192.168.0.0/16"
          - "172.16.0.0/12"

    secured:
      chain:
        middlewares:
          - default-whitelist
          - default-headers
EOF
fi

info "Traefik config files created."

# =============================================================================
# STEP 6 — TRAEFIK COMPOSE FILE
# =============================================================================
section "Step 6 — Traefik compose"

if $DRY_RUN; then
  dryinfo "Would write: $DOCKERDIR/traefik/docker-compose-traefik.yml"
else
  cat > "$DOCKERDIR/traefik/docker-compose-traefik.yml" <<EOF
services:
  traefik:
    image: traefik:latest
    container_name: traefik
    restart: unless-stopped
    networks:
      - traefik
      - smart_home
    extra_hosts:
      - host.docker.internal:host-gateway
    ports:
      - 80:80
      - 443:443
    environment:
      - PUID=\$PUID
      - PGID=\$PGID
      - TZ=\$TZ
      - CF_API_EMAIL=\$CF_API_EMAIL
      - CF_DNS_API_TOKEN=\$CF_DNS_API_TOKEN
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - /etc/localtime:/etc/localtime:ro
      - \$DOCKERDIR/traefik/traefik.yml:/traefik.yml:ro
      - \$DOCKERDIR/traefik/acme.json:/acme.json
      - \$DOCKERDIR/traefik/config.yml:/config.yml:ro
      - \$DOCKERDIR/logs/traefik:/var/log/traefik
    labels:
      - "traefik.enable=true"
      - "traefik.http.middlewares.traefik-https-redirect.redirectscheme.scheme=https"
      - "traefik.http.middlewares.sslheader.headers.customrequestheaders.X-Forwarded-Proto=https"
      - "traefik.http.routers.traefik-secure.tls.domains[0].main=\$DOMAIN"
      - "traefik.http.routers.traefik-secure.tls.domains[0].sans=*.\$DOMAIN"

networks:
  traefik:
    external: true
  smart_home:
    external: true
EOF
fi

info "Traefik compose file created."

# =============================================================================
# STEP 7 — HOME ASSISTANT COMPOSE FILE
# =============================================================================
section "Step 7 — Home Assistant compose"

if $DRY_RUN; then
  dryinfo "Would write: $DOCKERDIR/smart-home/homeassistant/docker-compose-homeassistant.yml"
  dryinfo "Would write: $DOCKERDIR/smart-home/docker-compose.yml"
else
  cat > "$DOCKERDIR/smart-home/homeassistant/docker-compose-homeassistant.yml" <<EOF
services:
  homeassistant:
    container_name: homeassistant
    image: ghcr.io/home-assistant/home-assistant:stable
    restart: unless-stopped
    privileged: true
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      - \$DATADIR/ha:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:rw
    environment:
      PUID: \$PUID
      PGID: \$PGID
      TZ: \$TZ
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.homeassistant-secure.rule=Host(\`${HA_SUB}.\$DOMAIN\`)"
      - "traefik.http.routers.homeassistant-secure.entrypoints=https"
      - "traefik.http.routers.homeassistant-secure.tls=true"
      - "traefik.http.routers.homeassistant-secure.tls.certresolver=cloudflare"
      - "traefik.http.routers.homeassistant-secure.service=homeassistant-service"
      - "traefik.http.services.homeassistant-service.loadbalancer.server.port=8123"
      - "traefik.http.routers.homeassistant-secure.middlewares=sslheader@docker"
EOF

  cat > "$DOCKERDIR/smart-home/docker-compose.yml" <<'EOF'
include:
  - ./homeassistant/docker-compose-homeassistant.yml

networks:
  smart_home:
    name: smart_home
    driver: bridge
  traefik:
    external: true
EOF
fi

info "Home Assistant compose files created."

# =============================================================================
# STEP 8 — HA configuration.yaml
# =============================================================================
section "Step 8 — Home Assistant configuration"

# Only write if configuration.yaml doesn't already exist
if $DRY_RUN; then
  dryinfo "Would write: $DATADIR/ha/configuration.yaml (if not exists)"
  dryinfo "Would write: $DATADIR/ha/dashboard/dashboard.yaml"
  dryinfo "Would touch: automations.yaml, scripts.yaml, scenes.yaml"
  info "HA configuration files created."
elif [ ! -f "$DATADIR/ha/configuration.yaml" ]; then
  cat > "$DATADIR/ha/configuration.yaml" <<'EOF'
# Loads default set of integrations. Do not remove.
default_config:

frontend:
  themes: !include_dir_merge_named themes
  extra_module_url:
    - /hacsfiles/lovelace-card-mod/lovelace-card-mod.js?hacstag=v4.2.1

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml

homeassistant:
  debug: false

http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 127.0.0.1
    - ::1
    - 172.16.0.0/12
    - 192.168.0.0/16

lovelace:
  dashboards:
    lovelace-home:
      mode: yaml
      title: Home
      icon: mdi:home
      show_in_sidebar: true
      filename: dashboard/dashboard.yaml
EOF

  touch "$DATADIR/ha/automations.yaml"
  touch "$DATADIR/ha/scripts.yaml"
  touch "$DATADIR/ha/scenes.yaml"
  mkdir -p "$DATADIR/ha/dashboard"

  cat > "$DATADIR/ha/dashboard/dashboard.yaml" <<'EOF'
title: Home
views:
  - title: Home
    path: home
    type: masonry
    cards:
      - type: markdown
        content: "## Welcome home!"
EOF

  info "HA configuration files created."
else
  warn "configuration.yaml already exists — skipping to avoid overwriting."
fi

# =============================================================================
# STEP 9 — START CONTAINERS
# =============================================================================
section "Step 9 — Starting containers"

info "Starting Traefik..."
run docker compose --env-file "$DOCKERDIR/.env" -f "$DOCKERDIR/traefik/docker-compose-traefik.yml" up -d

info "Starting Home Assistant..."
run docker compose --env-file "$DOCKERDIR/.env" -f "$DOCKERDIR/smart-home/docker-compose.yml" up -d

# =============================================================================
# DONE
# =============================================================================
section "Setup complete"

PI_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}${BOLD}All done!${RESET}"
echo ""
echo "  Home Assistant (local) : http://${PI_IP}:8123"
echo "  Home Assistant (remote): https://${HA_SUB}.${DOMAIN}"
echo ""
echo -e "${YELLOW}Next steps:${RESET}"
echo "  1. Open http://${PI_IP}:8123 and complete the HA onboarding"
echo "  2. Make sure port 80 and 443 are forwarded to this machine in your router"
echo "  3. In Cloudflare, set the DNS A record for ${HA_SUB}.${DOMAIN} to your public IP"
echo "     and make sure the proxy is set to OFF (grey cloud)"
echo "  4. Install HACS:"
echo "     docker exec -it homeassistant bash -c \"wget -O - https://get.hacs.xyz | bash -\""
echo "     docker restart homeassistant"
echo ""
echo -e "${YELLOW}Useful commands:${RESET}"
echo "  docker logs homeassistant --tail 50"
echo "  docker logs traefik --tail 50"
echo "  docker restart homeassistant"
echo ""
