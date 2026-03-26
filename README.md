# Home Assistant Setup Guide — Linux & Windows

This guide sets up a Home Assistant installation with:
- **Docker** (standalone, no supervisor)
- **Traefik** reverse proxy with SSL via Cloudflare
- **HACS** (custom cards & integrations)
- **UI Lovelace Minimalist** theme

---

## Automated setup scripts

Run the scripts for a fully automated setup instead of following the manual steps below.

### Linux / Raspberry Pi

```bash
git clone https://github.com/tjelite1986/homeassist-setup.git
cd homeassist-setup
chmod +x setup.sh setup2.sh
./setup.sh        # Step 1: install Docker, Traefik, Home Assistant
# Complete HA onboarding at http://<your-ip>:8123
./setup2.sh       # Step 2: install HACS, frontend cards, theme
```

Run with `--dry-run` to preview all actions without making any changes:

```bash
./setup.sh --dry-run
```

### Windows (Docker Desktop required)

```powershell
git clone https://github.com/tjelite1986/homeassist-setup.git
cd homeassist-setup
# Run PowerShell as Administrator
.\setup-windows.ps1        # Step 1: Traefik + Home Assistant
# Complete HA onboarding at http://<your-ip>:8123
.\setup2-windows.ps1       # Step 2: HACS, frontend cards, theme
```

> **Windows requirement:** [Docker Desktop](https://www.docker.com/products/docker-desktop) with WSL2 backend must be installed before running the scripts.

---

## Test the script without installing anything

There are three ways to verify the scripts before running them for real.

### 1. Syntax check (bash -n)

Checks that the script has no syntax errors. Does not execute anything.

```bash
bash -n setup.sh && echo "OK"
bash -n setup2.sh && echo "OK"
```

### 2. Dry-run mode (--dry-run)

Runs the full script interactively but skips all file writes and command execution. Shows exactly what would happen with your inputs.

```bash
./setup.sh --dry-run
```

Example output:
```
=== Step 2 — Directories ===
[DRY-RUN] Would run: mkdir -p /home/user/docker/traefik
[DRY-RUN] Would run: mkdir -p /home/user/dockdata/ha
...
=== Step 4 — Environment file ===
[DRY-RUN] Would write: /home/user/docker/.env
[DRY-RUN]   PUID=1000 PGID=1000 TZ=Europe/London DOMAIN=myhome.com
```

### 3. Run in an isolated Ubuntu Docker container

Test the full script in a clean Ubuntu environment without touching your host system. Useful if you want to verify the complete install flow.

```bash
# Start a throwaway Ubuntu container with Docker socket access
docker run --rm -it \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)":/setup \
  ubuntu:22.04 bash

# Inside the container:
cd /setup
apt-get update -qq && apt-get install -y -qq git curl sudo
useradd -m testuser && echo "testuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
su - testuser -c "cd /setup && bash setup.sh"
```

> **Note:** The container shares your host's Docker socket, so any containers started by the script will run on your host. Use `--dry-run` inside the container if you only want to test without side effects.

---

## Platform support

| Platform | Script | Notes |
|----------|--------|-------|
| Raspberry Pi OS (Bookworm) | `setup.sh` | Recommended |
| Ubuntu / Debian | `setup.sh` | Fully supported |
| Windows 10/11 | `setup-windows.ps1` | Requires Docker Desktop + WSL2 |
| macOS | — | Manual setup only (see steps below) |

---

## Manual setup

Follow the steps below if you prefer to set everything up manually or if the automated scripts don't fit your environment.

### Prerequisites

| Requirement | Details |
|-------------|---------|
| Hardware | Raspberry Pi 4 (4 GB RAM+ recommended) or any Linux/Windows machine |
| OS | Raspberry Pi OS Lite 64-bit (Bookworm), Ubuntu/Debian, or Windows 10/11 |
| Domain | A domain you own (e.g. `myhome.com`) |
| DNS provider | Cloudflare (free, required for SSL) |
| Cloudflare API token | See step 2 |

---

## Step 1 — Install Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
docker --version
```

Install the Docker Compose plugin:

```bash
sudo apt-get install -y docker-compose-plugin
docker compose version
```

---

## Step 2 — Cloudflare DNS & API token

1. Register your domain on [cloudflare.com](https://cloudflare.com) and point the nameservers there
2. Log in → **My Profile** → **API Tokens** → **Create Token**
3. Select the **Edit zone DNS** template
4. Under *Zone Resources* select your domain
5. Click **Continue to summary** → **Create Token**
6. Copy the token — you will only see it once

DNS records needed in Cloudflare (A records):
```
home.yourdomain.com  →  your-public-IP    (Proxy: OFF / grey cloud)
```

**NOTE:** Set the proxy to "DNS only" (grey cloud) for Home Assistant. The Cloudflare orange-cloud proxy blocks WebSocket connections.

---

## Step 3 — Directory structure

Create the directories:

```bash
mkdir -p ~/docker/smart-home/homeassistant
mkdir -p ~/docker/traefik
mkdir -p ~/docker/logs/traefik
mkdir -p ~/dockdata/ha
touch ~/docker/traefik/acme.json
chmod 600 ~/docker/traefik/acme.json
```

Structure used:
```
~/docker/                         <- compose files
  .env
  traefik/
    docker-compose-traefik.yml
    traefik.yml
    config.yml
    acme.json                     <- SSL certificates (chmod 600!)
  smart-home/
    docker-compose.yml
    homeassistant/
      docker-compose-homeassistant.yml

~/dockdata/                       <- persistent data
  ha/                             <- Home Assistant configuration
```

---

## Step 4 — Docker networks

Create the networks once:

```bash
docker network create traefik
docker network create smart_home
```

---

## Step 5 — Environment variables (.env)

Create `~/docker/.env`:

```env
PUID=1000
PGID=1000
TZ=Europe/London
DOMAIN=yourdomain.com
DOCKERDIR=/home/yourusername/docker
DATADIR=/home/yourusername/dockdata

# Cloudflare
CF_API_EMAIL=your-cloudflare-email@example.com
CF_DNS_API_TOKEN=your-cloudflare-api-token-here
```

Replace:
- `yourdomain.com` with your domain
- `yourusername` with your Linux username
- `CF_API_EMAIL` and `CF_DNS_API_TOKEN` with your Cloudflare credentials

---

## Step 6 — Traefik

### `~/docker/traefik/traefik.yml`

```yaml
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
      email: your-cloudflare-email@example.com    # same as CF_API_EMAIL
      storage: "acme.json"
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - "1.1.1.1:53"
          - "1.0.0.1:53"
```

### `~/docker/traefik/config.yml`

```yaml
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
```

### `~/docker/traefik/docker-compose-traefik.yml`

```yaml
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
      - PUID=$PUID
      - PGID=$PGID
      - TZ=$TZ
      - CF_API_EMAIL=$CF_API_EMAIL
      - CF_DNS_API_TOKEN=$CF_DNS_API_TOKEN
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - /etc/localtime:/etc/localtime:ro
      - $DOCKERDIR/traefik/traefik.yml:/traefik.yml:ro
      - $DOCKERDIR/traefik/acme.json:/acme.json
      - $DOCKERDIR/traefik/config.yml:/config.yml:ro
      - $DOCKERDIR/logs/traefik:/var/log/traefik
    labels:
      - "traefik.enable=true"
      - "traefik.http.middlewares.traefik-https-redirect.redirectscheme.scheme=https"
      - "traefik.http.middlewares.sslheader.headers.customrequestheaders.X-Forwarded-Proto=https"
      - "traefik.http.routers.traefik-secure.tls.domains[0].main=$DOMAIN"
      - "traefik.http.routers.traefik-secure.tls.domains[0].sans=*.$DOMAIN"

networks:
  traefik:
    external: true
  smart_home:
    external: true
```

Start Traefik:

```bash
cd ~/docker/traefik
docker compose -f docker-compose-traefik.yml up -d
docker logs traefik --tail 20
```

---

## Step 7 — Home Assistant

### `~/docker/smart-home/homeassistant/docker-compose-homeassistant.yml`

```yaml
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
      - $DATADIR/ha:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:rw
    environment:
      PUID: $PUID
      PGID: $PGID
      TZ: $TZ
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.homeassistant-secure.rule=Host(`home.$DOMAIN`)"
      - "traefik.http.routers.homeassistant-secure.entrypoints=https"
      - "traefik.http.routers.homeassistant-secure.tls=true"
      - "traefik.http.routers.homeassistant-secure.tls.certresolver=cloudflare"
      - "traefik.http.routers.homeassistant-secure.service=homeassistant-service"
      - "traefik.http.services.homeassistant-service.loadbalancer.server.port=8123"
      - "traefik.http.routers.homeassistant-secure.middlewares=sslheader@docker"
```

**NOTE — Zigbee/Z-Wave USB dongle:** Add under `devices:`:
```yaml
    devices:
      - /dev/ttyUSB0:/dev/ttyUSB0
```

Check which port your dongle uses: `ls /dev/serial/by-id/`

### `~/docker/smart-home/docker-compose.yml`

```yaml
include:
  - ./homeassistant/docker-compose-homeassistant.yml

networks:
  smart_home:
    name: smart_home
    driver: bridge
  traefik:
    external: true
```

Start Home Assistant:

```bash
cd ~/docker/smart-home
docker compose up -d
docker logs homeassistant --tail 30
```

HA is now available at `http://your-pi-ip:8123` and (once the certificate is issued, ~1 minute) at `https://home.yourdomain.com`.

---

## Step 8 — Initial HA configuration

1. Open `http://your-pi-ip:8123` in your browser
2. Create your account
3. Set your location, timezone and unit system
4. Done — HA onboarding complete

### `~/dockdata/ha/configuration.yaml`

Replace the default `configuration.yaml` with this (adjust `trusted_proxies` if your Docker subnet differs):

```yaml
# Loads default set of integrations. Do not remove.
default_config:

# Load frontend themes from the themes folder
frontend:
  themes: !include_dir_merge_named themes
  extra_module_url:
    - /hacsfiles/lovelace-card-mod/lovelace-card-mod.js?hacstag=v4.2.1

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml

homeassistant:
  debug: false

# HTTP — required for Traefik reverse proxy to work
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 127.0.0.1
    - ::1
    - 172.16.0.0/12    # Docker bridge networks
    - 192.168.0.0/16   # LAN

# Lovelace YAML dashboards
lovelace:
  dashboards:
    lovelace-home:
      mode: yaml
      title: Home
      icon: mdi:home
      show_in_sidebar: true
      filename: dashboard/dashboard.yaml
```

Create empty include files if missing:
```bash
touch ~/dockdata/ha/automations.yaml
touch ~/dockdata/ha/scripts.yaml
touch ~/dockdata/ha/scenes.yaml
mkdir -p ~/dockdata/ha/dashboard
```

Restart HA:
```bash
docker restart homeassistant
```

---

## Step 9 — HACS (custom cards & integrations)

HACS is installed manually since we run standalone Docker (no supervisor):

```bash
docker exec -i homeassistant bash -c \
  "wget -O - https://get.hacs.xyz | bash -"
```

Restart HA after installation:
```bash
docker restart homeassistant
```

Enable HACS in HA:
1. **Settings** → **Devices & Services** → **Add integration** → search "HACS"
2. Follow the instructions (GitHub authentication required)
3. Done

---

## Step 10 — UI Lovelace Minimalist

Install via HACS:
1. HACS → **Integrations** → search "UI Lovelace Minimalist" → Install
2. Go to **Settings** → **Devices & Services** → **Add integration** → "UI Lovelace Minimalist"
3. Select a theme and configure

### Custom theme (optional)

Create `~/dockdata/ha/themes/minimalist-desktop/minimalist-custom.yaml`:

```yaml
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
```

---

## Step 11 — Recommended HACS frontend cards

Go to **HACS → Frontend** and install these:

| Card | Used for |
|------|----------|
| `button-card` | Custom buttons and dividers |
| `mushroom` | Clean entity cards |
| `card-mod` | CSS customization of cards |
| `mini-media-player` | Media player card |
| `mini-graph-card` | Graph card |
| `layout-card` | Grid layout for dashboards |
| `expander-card` | Expandable sections |
| `browser_mod` | Browser integration |

Restart HA after installing frontend resources.

---

## Step 12 — Basic dashboard

Create `~/dockdata/ha/dashboard/dashboard.yaml`:

```yaml
title: Home
views:
  - title: Home
    path: home
    type: masonry
    cards:
      - type: markdown
        content: "## Welcome home!"
```

---

## Router configuration (port forwarding)

For external access, open these ports in your router:

| Port | Protocol | Destination |
|------|----------|-------------|
| 80   | TCP | Pi IP:80 |
| 443  | TCP | Pi IP:443 |

Give the Pi a static LAN IP (DHCP reservation) in your router settings.

---

## Troubleshooting

### Check logs
```bash
docker logs homeassistant --tail 50
docker logs traefik --tail 50
```

### SSL certificate stuck
- Verify `acme.json` has `chmod 600`
- Verify the DNS A record resolves correctly (`dig home.yourdomain.com`)
- Cloudflare proxy must be **disabled** (grey cloud) for HA

### HA won't start
```bash
docker exec homeassistant cat /config/home-assistant.log | tail -30
```

### Trusted proxies error (can't log in)
Add the Traefik container IP to `trusted_proxies` in `configuration.yaml`:
```bash
docker inspect traefik | grep -i "ipaddress"
```

### Verify HA is running
```bash
curl -s http://localhost:8123/api/ | python3 -m json.tool
```

---

## Quick reference

```bash
# Restart HA
docker restart homeassistant

# Follow logs live
docker logs homeassistant -f

# Restart Traefik
docker restart traefik

# Update HA to latest version
cd ~/docker/smart-home
docker compose pull
docker compose up -d

# Check all containers
docker ps
```

---

## Security

- Never replace `acme.json` without stopping Traefik first
- Never commit tokens, passwords or API keys to git
- Use `secrets.yaml` in HA for sensitive values:
  ```yaml
  # secrets.yaml
  my_api_token: yourtokenhere
  ```
  Reference in config: `!secret my_api_token`
- Never expose HA directly without Traefik (do not bind port 8123 externally)

---

## Next steps

- Add integrations via **Settings → Devices & Services** (Zigbee2MQTT, Google Home, Spotify, etc.)
- Set up the mobile app (Home Assistant for Android/iOS) — connect via `https://home.yourdomain.com`
- Explore automations via **Settings → Automations**
