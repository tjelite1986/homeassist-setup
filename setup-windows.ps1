# =============================================================================
# Home Assistant + Traefik — Automated Setup Script for Windows
# Requires: Docker Desktop with WSL2 backend
# Run in PowerShell as Administrator
# =============================================================================

$ErrorActionPreference = "Stop"

function Info    { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Green }
function Warn    { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Section { param($msg) Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Err     { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }

# =============================================================================
# ADMIN CHECK
# =============================================================================
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Err "Run this script as Administrator (right-click PowerShell -> Run as administrator)."
}

# =============================================================================
# WELCOME
# =============================================================================
Clear-Host
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     Home Assistant + Traefik — Setup Script         ║" -ForegroundColor Cyan
Write-Host "║                    (Windows)                        ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "This script will:"
Write-Host "  - Verify Docker Desktop is installed"
Write-Host "  - Create all required directories and config files"
Write-Host "  - Set up Traefik and Home Assistant via Docker Compose"
Write-Host "  - Configure SSL via Cloudflare DNS challenge"
Write-Host ""
Read-Host "Press ENTER to continue or Ctrl+C to abort"

# =============================================================================
# CHECK DOCKER
# =============================================================================
Section "Checking Docker Desktop"

try {
    $dockerVersion = docker --version
    Info "Docker found: $dockerVersion"
} catch {
    Err "Docker not found. Install Docker Desktop from https://www.docker.com/products/docker-desktop and re-run."
}

try {
    $composeVersion = docker compose version
    Info "Docker Compose: $composeVersion"
} catch {
    Err "Docker Compose not found. Make sure Docker Desktop is up to date."
}

# =============================================================================
# GATHER INPUT
# =============================================================================
Section "Configuration"

$defaultDockerDir = "$env:USERPROFILE\docker"
$defaultDataDir   = "$env:USERPROFILE\dockdata"

$inputDockerDir = Read-Host "Docker compose files directory [default: $defaultDockerDir]"
$DOCKERDIR = if ($inputDockerDir) { $inputDockerDir } else { $defaultDockerDir }

$inputDataDir = Read-Host "Persistent data directory [default: $defaultDataDir]"
$DATADIR = if ($inputDataDir) { $inputDataDir } else { $defaultDataDir }

do {
    $DOMAIN = Read-Host "Your domain (e.g. myhome.com)"
    if (-not $DOMAIN) { Warn "Domain cannot be empty." }
} while (-not $DOMAIN)

$inputSub = Read-Host "Subdomain for Home Assistant [default: home]"
$HA_SUB = if ($inputSub) { $inputSub } else { "home" }

$inputTZ = Read-Host "Timezone [default: Europe/London]"
$TZ = if ($inputTZ) { $inputTZ } else { "Europe/London" }

Write-Host ""
Write-Host "--- Cloudflare credentials ---"
do {
    $CF_EMAIL = Read-Host "Cloudflare account email"
    if (-not $CF_EMAIL) { Warn "Email cannot be empty." }
} while (-not $CF_EMAIL)

do {
    $CF_TOKEN_SEC = Read-Host "Cloudflare API token" -AsSecureString
    $CF_TOKEN = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($CF_TOKEN_SEC)
    )
    if (-not $CF_TOKEN) { Warn "Token cannot be empty." }
} while (-not $CF_TOKEN)

# Summary
Write-Host ""
Section "Summary"
Write-Host "  Docker dir  : $DOCKERDIR"
Write-Host "  Data dir    : $DATADIR"
Write-Host "  Domain      : $DOMAIN"
Write-Host "  HA URL      : https://${HA_SUB}.${DOMAIN}"
Write-Host "  Timezone    : $TZ"
Write-Host "  CF email    : $CF_EMAIL"
Write-Host "  CF token    : $($CF_TOKEN.Substring(0,6))************************"
Write-Host ""
Read-Host "Looks good? Press ENTER to start or Ctrl+C to abort"

# =============================================================================
# STEP 1 — DIRECTORIES
# =============================================================================
Section "Step 1 — Directories"

$dirs = @(
    "$DOCKERDIR\traefik",
    "$DOCKERDIR\smart-home\homeassistant",
    "$DOCKERDIR\logs\traefik",
    "$DATADIR\ha"
)
foreach ($d in $dirs) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

$acmeFile = "$DOCKERDIR\traefik\acme.json"
if (-not (Test-Path $acmeFile)) {
    New-Item -ItemType File -Path $acmeFile | Out-Null
}
# Windows doesn't have chmod — Traefik on Windows/Docker Desktop handles this internally

Info "Directories created."

# =============================================================================
# STEP 2 — DOCKER NETWORKS
# =============================================================================
Section "Step 2 — Docker networks"

$existingNetworks = docker network ls --format "{{.Name}}"
if ($existingNetworks -notcontains "traefik") {
    docker network create traefik | Out-Null
    Info "Created network: traefik"
} else {
    Info "Network traefik already exists."
}
if ($existingNetworks -notcontains "smart_home") {
    docker network create smart_home | Out-Null
    Info "Created network: smart_home"
} else {
    Info "Network smart_home already exists."
}

# =============================================================================
# STEP 3 — .env FILE
# =============================================================================
Section "Step 3 — Environment file"

$envContent = @"
PUID=1000
PGID=1000
TZ=$TZ
DOMAIN=$DOMAIN
DOCKERDIR=$DOCKERDIR
DATADIR=$DATADIR

# Cloudflare
CF_API_EMAIL=$CF_EMAIL
CF_DNS_API_TOKEN=$CF_TOKEN
"@

$envFile = "$DOCKERDIR\.env"
$envContent | Set-Content -Path $envFile -Encoding UTF8
Info ".env created at $envFile"

# =============================================================================
# STEP 4 — TRAEFIK CONFIG
# =============================================================================
Section "Step 4 — Traefik config"

@"
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
    endpoint: "npipe:////./pipe/docker_engine"
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
"@ | Set-Content -Path "$DOCKERDIR\traefik\traefik.yml" -Encoding UTF8

@'
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
'@ | Set-Content -Path "$DOCKERDIR\traefik\config.yml" -Encoding UTF8

Info "Traefik config files created."

# =============================================================================
# STEP 5 — TRAEFIK COMPOSE FILE
# =============================================================================
Section "Step 5 — Traefik compose"

# Convert Windows paths to Docker-compatible forward-slash paths
$DockerDirFwd = $DOCKERDIR.Replace("\", "/")

@"
services:
  traefik:
    image: traefik:latest
    container_name: traefik
    restart: unless-stopped
    networks:
      - traefik
      - smart_home
    ports:
      - 80:80
      - 443:443
    environment:
      - TZ=`${TZ}
      - CF_API_EMAIL=`${CF_API_EMAIL}
      - CF_DNS_API_TOKEN=`${CF_DNS_API_TOKEN}
    volumes:
      - type: npipe
        source: \\\\.\pipe\docker_engine
        target: /var/run/docker.sock
      - ${DockerDirFwd}/traefik/traefik.yml:/traefik.yml:ro
      - ${DockerDirFwd}/traefik/acme.json:/acme.json
      - ${DockerDirFwd}/traefik/config.yml:/config.yml:ro
      - ${DockerDirFwd}/logs/traefik:/var/log/traefik
    labels:
      - "traefik.enable=true"
      - "traefik.http.middlewares.traefik-https-redirect.redirectscheme.scheme=https"
      - "traefik.http.middlewares.sslheader.headers.customrequestheaders.X-Forwarded-Proto=https"
      - "traefik.http.routers.traefik-secure.tls.domains[0].main=`${DOMAIN}"
      - "traefik.http.routers.traefik-secure.tls.domains[0].sans=*.`${DOMAIN}"

networks:
  traefik:
    external: true
  smart_home:
    external: true
"@ | Set-Content -Path "$DOCKERDIR\traefik\docker-compose-traefik.yml" -Encoding UTF8

Info "Traefik compose file created."

# =============================================================================
# STEP 6 — HOME ASSISTANT COMPOSE FILE
# =============================================================================
Section "Step 6 — Home Assistant compose"

$DataDirFwd = $DATADIR.Replace("\", "/")

@"
services:
  homeassistant:
    container_name: homeassistant
    image: ghcr.io/home-assistant/home-assistant:stable
    restart: unless-stopped
    privileged: true
    network_mode: host
    volumes:
      - ${DataDirFwd}/ha:/config
    environment:
      TZ: `${TZ}
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.homeassistant-secure.rule=Host(\`${HA_SUB}.`${DOMAIN}\`)"
      - "traefik.http.routers.homeassistant-secure.entrypoints=https"
      - "traefik.http.routers.homeassistant-secure.tls=true"
      - "traefik.http.routers.homeassistant-secure.tls.certresolver=cloudflare"
      - "traefik.http.routers.homeassistant-secure.service=homeassistant-service"
      - "traefik.http.services.homeassistant-service.loadbalancer.server.port=8123"
      - "traefik.http.routers.homeassistant-secure.middlewares=sslheader@docker"
"@ | Set-Content -Path "$DOCKERDIR\smart-home\homeassistant\docker-compose-homeassistant.yml" -Encoding UTF8

@'
include:
  - ./homeassistant/docker-compose-homeassistant.yml

networks:
  smart_home:
    name: smart_home
    driver: bridge
  traefik:
    external: true
'@ | Set-Content -Path "$DOCKERDIR\smart-home\docker-compose.yml" -Encoding UTF8

Info "Home Assistant compose files created."

# =============================================================================
# STEP 7 — HA configuration.yaml
# =============================================================================
Section "Step 7 — Home Assistant configuration"

$haConfig = "$DATADIR\ha\configuration.yaml"
if (-not (Test-Path $haConfig)) {
    @'
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
'@ | Set-Content -Path $haConfig -Encoding UTF8

    "" | Set-Content -Path "$DATADIR\ha\automations.yaml" -Encoding UTF8
    "" | Set-Content -Path "$DATADIR\ha\scripts.yaml"     -Encoding UTF8
    "" | Set-Content -Path "$DATADIR\ha\scenes.yaml"      -Encoding UTF8
    New-Item -ItemType Directory -Force -Path "$DATADIR\ha\dashboard" | Out-Null

    @'
title: Home
views:
  - title: Home
    path: home
    type: masonry
    cards:
      - type: markdown
        content: "## Welcome home!"
'@ | Set-Content -Path "$DATADIR\ha\dashboard\dashboard.yaml" -Encoding UTF8

    Info "HA configuration files created."
} else {
    Warn "configuration.yaml already exists — skipping to avoid overwriting."
}

# =============================================================================
# STEP 8 — START CONTAINERS
# =============================================================================
Section "Step 8 — Starting containers"

Info "Starting Traefik..."
docker compose --env-file "$DOCKERDIR\.env" -f "$DOCKERDIR\traefik\docker-compose-traefik.yml" up -d

Info "Starting Home Assistant..."
docker compose --env-file "$DOCKERDIR\.env" -f "$DOCKERDIR\smart-home\docker-compose.yml" up -d

# =============================================================================
# DONE
# =============================================================================
Section "Setup complete"

$localIP = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -notlike "169.*" } |
    Select-Object -First 1).IPAddress

Write-Host ""
Write-Host "All done!" -ForegroundColor Green
Write-Host ""
Write-Host "  Home Assistant (local) : http://${localIP}:8123"
Write-Host "  Home Assistant (remote): https://${HA_SUB}.${DOMAIN}"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Open http://${localIP}:8123 and complete the HA onboarding"
Write-Host "  2. Make sure port 80 and 443 are forwarded to this machine in your router"
Write-Host "  3. In Cloudflare, set the DNS A record for ${HA_SUB}.${DOMAIN} to your public IP"
Write-Host "     and set the proxy to OFF (grey cloud)"
Write-Host "  4. Install HACS:"
Write-Host "     docker exec -i homeassistant bash -c `"wget -O - https://get.hacs.xyz | bash -`""
Write-Host "     docker restart homeassistant"
Write-Host ""
Write-Host "Useful commands:" -ForegroundColor Yellow
Write-Host "  docker logs homeassistant --tail 50"
Write-Host "  docker logs traefik --tail 50"
Write-Host "  docker restart homeassistant"
Write-Host ""
