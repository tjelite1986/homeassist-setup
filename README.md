# Home Assistant på Raspberry Pi — Fullständig installationsguide

Denna guide sätter upp en Home Assistant-installation med:
- **Docker** (fristående, ingen supervisor)
- **Traefik** reverse proxy med SSL via Cloudflare
- **HACS** (custom cards & integrationer)
- **UI Lovelace Minimalist**-tema
- Struktur identisk med referensinstallationen

---

## Förutsättningar

| Krav | Detaljer |
|------|----------|
| Hårdvara | Raspberry Pi 4 (rekommenderat 4 GB RAM+) |
| OS | Raspberry Pi OS Lite 64-bit (Bookworm) |
| Domän | En domän du äger (ex: `mitthem.se`) |
| DNS-provider | Cloudflare (gratis, krävs för SSL) |
| Cloudflare API-token | Se steg 2 |

---

## Steg 1 — Installera Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
docker --version
```

Installera även Docker Compose plugin:

```bash
sudo apt-get install -y docker-compose-plugin
docker compose version
```

---

## Steg 2 — Cloudflare DNS & API-token

1. Registrera domänen på [cloudflare.com](https://cloudflare.com) och peka DNS-servrarna dit
2. Logga in → **My Profile** → **API Tokens** → **Create Token**
3. Välj mallen **Edit zone DNS**
4. Under *Zone Resources* välj din domän
5. Klicka **Continue to summary** → **Create Token**
6. Kopiera token — du ser den bara en gång

DNS-poster du behöver i Cloudflare (A-poster):
```
home.dindomän.se  →  din-publik-IP    (Proxy: OFF / grå moln)
```

**OBS:** Sätt proxyn till "DNS only" (grå moln) för Home Assistant. Cloudflare-proxy med orange moln blockerar WebSocket.

---

## Steg 3 — Mappstruktur

Skapa mapparna:

```bash
mkdir -p ~/docker/smart-home/homeassistant
mkdir -p ~/docker/traefik
mkdir -p ~/docker/logs/traefik
mkdir -p ~/dockdata/ha
touch ~/docker/traefik/acme.json
chmod 600 ~/docker/traefik/acme.json
```

Strukturen som används:
```
~/docker/                         ← compose-filer
  .env
  traefik/
    docker-compose-traefik.yml
    traefik.yml
    config.yml
    acme.json                     ← SSL-certifikat (chmod 600!)
  smart-home/
    docker-compose.yml
    homeassistant/
      docker-compose-homeassistant.yml

~/dockdata/                       ← persistent data
  ha/                             ← Home Assistant-konfiguration
```

---

## Steg 4 — Docker-nätverk

Skapa nätverken manuellt en gång:

```bash
docker network create traefik
docker network create smart_home
```

---

## Steg 5 — Miljövariabler (.env)

Skapa `~/docker/.env`:

```env
PUID=1000
PGID=1000
TZ=Europe/Stockholm
DOMAIN=dindomän.se
DOCKERDIR=/home/dittanvändarnamn/docker
DATADIR=/home/dittanvändarnamn/dockdata

# Cloudflare
CF_API_EMAIL=din-cloudflare-epost@exempel.se
CF_DNS_API_TOKEN=din-cloudflare-api-token-här
```

Ersätt:
- `dindomän.se` med din domän
- `dittanvändarnamn` med ditt Linux-användarnamn
- `CF_API_EMAIL` och `CF_DNS_API_TOKEN` med dina Cloudflare-uppgifter

---

## Steg 6 — Traefik

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
      email: din-cloudflare-epost@exempel.se    # samma som CF_API_EMAIL
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

Starta Traefik:

```bash
cd ~/docker/traefik
docker compose -f docker-compose-traefik.yml up -d
docker logs traefik --tail 20
```

---

## Steg 7 — Home Assistant

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

**OBS om du har Zigbee/Z-Wave USB-dongel:** Lägg till under `devices:`:
```yaml
    devices:
      - /dev/ttyUSB0:/dev/ttyUSB0
```

Kontrollera vilken port din dongel hamnar på: `ls /dev/serial/by-id/`

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

Starta Home Assistant:

```bash
cd ~/docker/smart-home
docker compose up -d
docker logs homeassistant --tail 30
```

HA är nu tillgänglig på `http://din-pi-ip:8123` och (när certifikat hämtats, tar ~1 minut) på `https://home.dindomän.se`.

---

## Steg 8 — Grundkonfiguration av HA

1. Öppna `http://din-pi-ip:8123` i webbläsaren
2. Skapa ditt konto
3. Ange hemort, tidzon och enhetstyp
4. Klart — HA-onboarding är klar

### `~/dockdata/ha/configuration.yaml`

Ersätt standard-`configuration.yaml` med detta (anpassa IP i `trusted_proxies` om din Docker-subnet skiljer sig):

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

# HTTP — krävs för att Traefik reverse proxy ska fungera
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 127.0.0.1
    - ::1
    - 172.16.0.0/12    # Docker bridge-nätverk
    - 192.168.0.0/16   # LAN

# Lovelace YAML-dashboards
lovelace:
  dashboards:
    lovelace-hem:
      mode: yaml
      title: Hem
      icon: mdi:home
      show_in_sidebar: true
      filename: dashboard/dashboard.yaml
```

Skapa tomma include-filer om de saknas:
```bash
touch ~/dockdata/ha/automations.yaml
touch ~/dockdata/ha/scripts.yaml
touch ~/dockdata/ha/scenes.yaml
mkdir -p ~/dockdata/ha/dashboard
```

Starta om HA:
```bash
docker restart homeassistant
```

---

## Steg 9 — HACS (custom cards & integrationer)

HACS installeras manuellt eftersom vi kör fristående Docker (ingen supervisor):

```bash
docker exec -it homeassistant bash -c \
  "wget -O - https://get.hacs.xyz | bash -"
```

Starta om HA efter installationen:
```bash
docker restart homeassistant
```

Aktivera HACS i HA:
1. **Inställningar** → **Enheter & tjänster** → **Lägg till integration** → sök "HACS"
2. Följ anvisningarna (GitHub-autentisering krävs)
3. Klart

---

## Steg 10 — UI Lovelace Minimalist

Installera via HACS:
1. HACS → **Integrations** → sök "UI Lovelace Minimalist" → Installera
2. Gå till **Inställningar** → **Enheter & tjänster** → **Lägg till integration** → "UI Lovelace Minimalist"
3. Välj tema och konfigurera

### Anpassat tema (valfritt)

Skapa `~/dockdata/ha/themes/minimalist-desktop/minimalist-custom.yaml`:

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

## Steg 11 — Viktiga HACS-kort att installera

Gå till **HACS → Frontend** och installera dessa:

| Kort | Används till |
|------|-------------|
| `button-card` | Anpassade knappar och dividers |
| `mushroom` | Snygga entitetskort |
| `card-mod` | CSS-modifiering av kort |
| `mini-media-player` | Mediaspelarkort |
| `mini-graph-card` | Grafkort |
| `layout-card` | Grid-layout för dashboards |
| `expander-card` | Expanderbara sektioner |
| `browser_mod` | Browser-integration |

Starta om HA efter installation av frontend-resurser.

---

## Steg 12 — Grundläggande dashboard

Skapa `~/dockdata/ha/dashboard/dashboard.yaml`:

```yaml
title: Hem
views:
  - title: Hem
    path: home
    type: masonry
    cards:
      - type: markdown
        content: "## Välkommen hem!"
```

---

## Routerkonfiguration (port forwarding)

För extern åtkomst behöver du öppna portar i routern:

| Port | Protokoll | Destination |
|------|-----------|-------------|
| 80   | TCP | Pi:ns IP:80 |
| 443  | TCP | Pi:ns IP:443 |

Ge Pi:n en statisk LAN-IP (DHCP reservation) i routerns inställningar.

---

## Felsökning

### Kontrollera loggar
```bash
docker logs homeassistant --tail 50
docker logs traefik --tail 50
```

### SSL-certifikat fastnar
- Kontrollera att `acme.json` har `chmod 600`
- Kontrollera att DNS A-posten pekar rätt (`dig home.dindomän.se`)
- Cloudflare-proxy måste vara **avstängd** (grå moln) för HA

### HA startar inte
```bash
docker exec homeassistant cat /config/home-assistant.log | tail -30
```

### Trusted proxies-fel (kan ej logga in)
Lägg till Traefik-containerns IP i `trusted_proxies` i `configuration.yaml`. Kör:
```bash
docker inspect traefik | grep -i "ipaddress"
```

### Kontrollera att HA är igång
```bash
curl -s http://localhost:8123/api/ | python3 -m json.tool
```

---

## Snabbkommandon

```bash
# Starta om HA
docker restart homeassistant

# Se loggar live
docker logs homeassistant -f

# Starta om Traefik
docker restart traefik

# Uppdatera HA till senaste version
cd ~/docker/smart-home
docker compose pull
docker compose up -d

# Kolla alla containers
docker ps
```

---

## Säkerhet

- Byt aldrig ut `acme.json` utan att stänga Traefik först
- Spara aldrig tokens, lösenord eller API-nycklar i git
- Använd `secrets.yaml` i HA för känsliga värden:
  ```yaml
  # secrets.yaml
  min_api_token: tokenvärdethär
  ```
  Referera i konfiguration: `!secret min_api_token`
- Exponera **aldrig** HA direkt utan Traefik (dvs bind inte port 8123 externt)

---

## Nästa steg

- Lägg till integrationer via **Inställningar → Enheter & tjänster** (Zigbee2MQTT, Google Home, Spotify, etc.)
- Konfigurera mobil-appen (Home Assistant för Android/iOS) — anslut via `https://home.dindomän.se`
- Utforska automatiseringar via **Inställningar → Automatiseringar**
