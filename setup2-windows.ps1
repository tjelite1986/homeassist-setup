# =============================================================================
# Home Assistant — Post-setup Script for Windows
# Installs HACS, downloads frontend cards, theme and configures Lovelace
# Run AFTER setup-windows.ps1 and AFTER completing HA onboarding in the browser
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
Write-Host "║   Home Assistant — Post-setup Script (step 2/2)     ║" -ForegroundColor Cyan
Write-Host "║                    (Windows)                        ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "This script will:"
Write-Host "  - Install HACS"
Write-Host "  - Download and install frontend cards"
Write-Host "  - Install UI Lovelace Minimalist theme"
Write-Host "  - Configure Lovelace dashboard resources"
Write-Host ""
Write-Host "Requirement: HA onboarding must be completed in the browser first." -ForegroundColor Yellow
Write-Host ""
$onboarded = Read-Host "Have you completed the HA onboarding? (y/n)"
if ($onboarded -notmatch "^[Yy]$") {
    $localIP = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -notlike "169.*" } |
        Select-Object -First 1).IPAddress
    Write-Host ""
    Write-Host "Please complete the onboarding first:"
    Write-Host "  1. Open http://${localIP}:8123"
    Write-Host "  2. Create your account and follow the setup wizard"
    Write-Host "  3. Run this script again"
    exit 0
}

# =============================================================================
# FIND .env FILE
# =============================================================================
Section "Configuration"

$defaultDockerDir = "$env:USERPROFILE\docker"
$inputDockerDir = Read-Host "Docker compose directory from setup-windows.ps1 [default: $defaultDockerDir]"
$DOCKERDIR = if ($inputDockerDir) { $inputDockerDir } else { $defaultDockerDir }

$envFile = "$DOCKERDIR\.env"
if (-not (Test-Path $envFile)) {
    Err ".env not found at $envFile — make sure you ran setup-windows.ps1 first."
}

# Read values from .env
$envVars = @{}
Get-Content $envFile | Where-Object { $_ -match "^[^#]" } | ForEach-Object {
    $parts = $_ -split "=", 2
    if ($parts.Count -eq 2) { $envVars[$parts[0].Trim()] = $parts[1].Trim() }
}

$DATADIR = $envVars["DATADIR"]
$DOMAIN  = $envVars["DOMAIN"]

if (-not $DATADIR -or -not $DOMAIN) {
    Err "Could not read DATADIR or DOMAIN from $envFile"
}

$HA_CONFIG = "$DATADIR\ha"
$HA_URL    = "http://localhost:8123"

Write-Host ""
Info "Using HA config dir: $HA_CONFIG"
Info "Domain: $DOMAIN"

# =============================================================================
# WAIT FOR HA
# =============================================================================
Section "Waiting for Home Assistant"

Info "Checking HA API..."
$attempts = 0
$maxAttempts = 30
while ($true) {
    try {
        $resp = Invoke-WebRequest -Uri "$HA_URL/api/" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        if ($resp.StatusCode -lt 500) { break }
    } catch {}
    $attempts++
    if ($attempts -ge $maxAttempts) {
        Err "HA did not respond after $maxAttempts attempts. Check: docker logs homeassistant --tail 30"
    }
    Write-Host -NoNewline "."
    Start-Sleep -Seconds 3
}
Write-Host ""
Info "Home Assistant is up."

# =============================================================================
# INSTALL HACS
# =============================================================================
Section "HACS Installation"

$hacsDir = "$HA_CONFIG\custom_components\hacs"
if (Test-Path $hacsDir) {
    Info "HACS already installed — skipping."
} else {
    Info "Installing HACS..."
    docker exec -i homeassistant bash -c "wget -q -O - https://get.hacs.xyz | bash -"
    if ($LASTEXITCODE -ne 0) {
        Err "HACS installation failed. Check: docker logs homeassistant"
    }
    Info "HACS installed."
}

# =============================================================================
# DOWNLOAD FRONTEND CARDS
# =============================================================================
Section "Frontend cards"

$communityDir = "$HA_CONFIG\www\community"
New-Item -ItemType Directory -Force -Path $communityDir | Out-Null

function Download-Card {
    param($Name, $Dir, $Url, $File)

    $targetDir  = "$communityDir\$Dir"
    $targetFile = "$targetDir\$File"
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

    if (Test-Path $targetFile) {
        Info "$Name already exists — skipping."
        return
    }

    Info "Downloading $Name..."
    try {
        Invoke-WebRequest -Uri $Url -OutFile $targetFile -UseBasicParsing -ErrorAction Stop
        Info "$Name downloaded."
    } catch {
        Warn "$Name download failed — install it manually via HACS later. ($_)"
        Remove-Item -Path $targetFile -ErrorAction SilentlyContinue
    }
}

Download-Card "button-card" `
    "button-card" `
    "https://github.com/custom-cards/button-card/releases/latest/download/button-card.js" `
    "button-card.js"

Download-Card "mushroom" `
    "lovelace-mushroom" `
    "https://github.com/piitaya/lovelace-mushroom/releases/latest/download/mushroom.js" `
    "mushroom.js"

Download-Card "card-mod" `
    "lovelace-card-mod" `
    "https://cdn.jsdelivr.net/gh/thomasloven/lovelace-card-mod@master/card-mod.js" `
    "card-mod.js"

Download-Card "mini-graph-card" `
    "mini-graph-card" `
    "https://github.com/kalkih/mini-graph-card/releases/latest/download/mini-graph-card-bundle.js" `
    "mini-graph-card-bundle.js"

Download-Card "layout-card" `
    "lovelace-layout-card" `
    "https://cdn.jsdelivr.net/gh/thomasloven/lovelace-layout-card@master/layout-card.js" `
    "layout-card.js"

Download-Card "expander-card" `
    "lovelace-expander-card" `
    "https://github.com/MelleD/lovelace-expander-card/releases/latest/download/expander-card.js" `
    "expander-card.js"

# =============================================================================
# UI LOVELACE MINIMALIST
# =============================================================================
Section "UI Lovelace Minimalist"

$ulmDir = "$HA_CONFIG\custom_components\ui_lovelace_minimalist"
if (Test-Path $ulmDir) {
    Info "UI Lovelace Minimalist already installed — skipping."
} else {
    Info "Downloading UI Lovelace Minimalist..."
    $tmpZip = "$env:TEMP\ulm_setup.zip"
    try {
        Invoke-WebRequest -Uri "https://github.com/UI-Lovelace-Minimalist/UI/releases/latest/download/ui_lovelace_minimalist.zip" `
            -OutFile $tmpZip -UseBasicParsing -ErrorAction Stop
        Info "Extracting..."
        New-Item -ItemType Directory -Force -Path "$HA_CONFIG\custom_components" | Out-Null
        Expand-Archive -Path $tmpZip -DestinationPath "$HA_CONFIG\custom_components" -Force
        Remove-Item $tmpZip -ErrorAction SilentlyContinue
        Info "UI Lovelace Minimalist installed."
    } catch {
        Warn "Download failed — install manually via HACS later. ($_)"
        Remove-Item $tmpZip -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# CUSTOM THEME
# =============================================================================
Section "Custom theme"

$themeDir = "$HA_CONFIG\themes\minimalist-desktop"
New-Item -ItemType Directory -Force -Path $themeDir | Out-Null

$themeFile = "$themeDir\minimalist-custom.yaml"
if (Test-Path $themeFile) {
    Info "Theme already exists — skipping."
} else {
    @'
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
'@ | Set-Content -Path $themeFile -Encoding UTF8
    Info "Theme written."
}

# =============================================================================
# DASHBOARD RESOURCES
# =============================================================================
Section "Lovelace dashboard resources"

$dashboard = "$HA_CONFIG\dashboard\dashboard.yaml"
New-Item -ItemType Directory -Force -Path "$HA_CONFIG\dashboard" | Out-Null

$resourcesBlock = @'
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

'@

if (-not (Test-Path $dashboard) -or -not (Select-String -Path $dashboard -Pattern "resources:" -Quiet)) {
    Info "Adding Lovelace resources to dashboard.yaml..."

    if (Test-Path $dashboard) {
        $existing = Get-Content $dashboard -Raw
        ($resourcesBlock + $existing) | Set-Content -Path $dashboard -Encoding UTF8
    } else {
        $newDash = @'
title: Home
views:
  - title: Home
    path: home
    type: masonry
    cards:
      - type: markdown
        content: "## Welcome home!"
'@
        ($resourcesBlock + $newDash) | Set-Content -Path $dashboard -Encoding UTF8
    }
    Info "Resources added."
} else {
    Info "Resources already present in dashboard.yaml — skipping."
}

# =============================================================================
# RESTART HA
# =============================================================================
Section "Restarting Home Assistant"

Info "Restarting HA to load HACS and new components..."
docker restart homeassistant

Info "Waiting for HA to come back up..."
Start-Sleep -Seconds 10
$attempts = 0
while ($true) {
    try {
        $resp = Invoke-WebRequest -Uri "$HA_URL/api/" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        if ($resp.StatusCode -lt 500) { break }
    } catch {}
    $attempts++
    if ($attempts -ge 40) {
        Warn "HA is taking a long time to restart. Check: docker logs homeassistant --tail 30"
        break
    }
    Write-Host -NoNewline "."
    Start-Sleep -Seconds 3
}
Write-Host ""
Info "Home Assistant is back up."

# =============================================================================
# DONE
# =============================================================================
Section "Done"

$localIP = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -notlike "169.*" } |
    Select-Object -First 1).IPAddress

Write-Host ""
Write-Host "Setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Cards installed:" -ForegroundColor Cyan
Write-Host "  - button-card"
Write-Host "  - mushroom"
Write-Host "  - card-mod"
Write-Host "  - mini-graph-card"
Write-Host "  - layout-card"
Write-Host "  - expander-card"
Write-Host ""
Write-Host "Remaining manual steps:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. Activate HACS"
Write-Host "     Settings -> Devices & Services -> Add integration -> HACS"
Write-Host "     (requires GitHub account authentication)"
Write-Host ""
Write-Host "  2. Activate UI Lovelace Minimalist"
Write-Host "     Settings -> Devices & Services -> Add integration -> UI Lovelace Minimalist"
Write-Host ""
Write-Host "  3. Install via HACS (no direct download available):"
Write-Host "     - mini-media-player"
Write-Host "     - browser_mod"
Write-Host ""
Write-Host "  4. Set theme"
Write-Host "     Profile -> Theme -> minimalist-custom"
Write-Host ""
Write-Host "  HA: http://${localIP}:8123"
Write-Host ""
