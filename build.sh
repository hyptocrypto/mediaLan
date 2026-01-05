---

# One-shot setup script: `make_media_stack.sh`

> Run as root inside the Ubuntu container: `sudo bash make_media_stack.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# ---------- sanity ----------
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

echo "==> Checking required devices"
[[ -e /dev/net/tun ]] || { echo "ERROR: /dev/net/tun missing. Fix LXC config on Proxmox and restart CT."; exit 1; }

# ---------- deps ----------
echo "==> Installing base packages & Docker"
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release jq

# Docker repo (Ubuntu 24.04)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
ARCH=$(dpkg --print-architecture)
CODENAME=$(source /etc/os-release && echo "$VERSION_CODENAME")
echo \
  "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl restart docker

# ---------- users/dirs ----------
echo "==> Ensuring media user (uid:1000 gid:1000) exists and folders are created"
if ! id -u media >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" --uid 1000 media || true
fi

mkdir -p /srv/config/{pia,pia-shared,pia-scripts,qbittorrent,sonarr,radarr,prowlarr,bazarr,jellyfin,jellyseerr}
mkdir -p /srv/data/{downloads,media}
chown -R 1000:1000 /srv/config /srv/data

# ---------- get inputs ----------
echo "==> Collecting configuration"
read -rp "Enter PIA username (format p1234567): " PIA_USER
read -rsp "Enter PIA password: " PIA_PASS; echo
echo "Valid PIA location IDs (examples: ca_toronto, ca_montreal, france, sweden, de_berlin, nl_amsterdam)"
echo "Tip: You can list from the container later with: docker exec -it pia /app/wg-gen.sh -a"
read -rp "Enter PIA location ID (e.g. ca_toronto): " PIA_LOC
read -rsp "Set qBittorrent WebUI password (user will be 'admin'): " QBT_PASS; echo

# ---------- write PF success script ----------
echo "==> Writing PIA port-forward success hook (auto-sets qBittorrent listen_port)"
cat >/srv/config/pia-scripts/pf_success.sh <<'EOS'
#!/bin/sh
# Runs inside the PIA container when a PF port is assigned.
# Requires env: QBT_USER, QBT_PASS, QBT_WEBUI_PORT (default 8080), PORT_FILE (default /pia-shared/port.dat)
set -eu
QBT_WEBUI_PORT="${QBT_WEBUI_PORT:-8080}"
PORT_FILE="${PORT_FILE:-/pia-shared/port.dat}"

if [ ! -f "$PORT_FILE" ]; then
  echo "pf_success.sh: port file not found: $PORT_FILE" >&2
  exit 0
fi
PORT="$(cat "$PORT_FILE" || true)"
[ -n "$PORT" ] || exit 0

if [ -n "${QBT_USER:-}" ] && [ -n "${QBT_PASS:-}" ]; then
  # Login (set cookie), include Referer to satisfy CSRF
  curl -s -D - -c /tmp/c -H "Referer: http://localhost:${QBT_WEBUI_PORT}" \
       -d "username=${QBT_USER}&password=${QBT_PASS}" \
       "http://localhost:${QBT_WEBUI_PORT}/api/v2/auth/login" >/dev/null 2>&1 || true

  # Apply port & set interface=Any, ensure DHT/PeX/LPD on, UPnP/NAT-PMP off
  curl -s -b /tmp/c -H "Referer: http://localhost:${QBT_WEBUI_PORT}" \
       --data-urlencode "json={\"listen_port\":${PORT},\"network_interface\":\"\",\
\"dht\":true,\"pex\":true,\"lsd\":true,\"upnp\":false,\"natpmp\":false,\"anonymous_mode\":false}" \
       "http://localhost:${QBT_WEBUI_PORT}/api/v2/app/setPreferences" >/dev/null 2>&1 || true
  echo "pf_success.sh: applied qBittorrent listen_port=${PORT}"
else
  echo "pf_success.sh: QBT_USER/PASS not set; only wrote ${PORT} to ${PORT_FILE}"
fi
EOS
chmod +x /srv/config/pia-scripts/pf_success.sh
chown -R 1000:1000 /srv/config/pia-scripts

# ---------- write compose ----------
echo "==> Writing docker compose file: /srv/media-stack.yml"
cat >/srv/media-stack.yml <<EOS
services:
  # --- VPN (PIA WireGuard + Port Forwarding) ---
  pia:
    image: ghcr.io/thrnz/docker-wireguard-pia:latest
    container_name: pia
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      USER: "${PIA_USER}"
      PASS: "${PIA_PASS}"
      LOC:  "${PIA_LOC}"
      PORT_FORWARDING: "1"
      PORT_FILE: "/pia-shared/port.dat"
      LOCAL_NETWORK: "192.168.7.0/24 172.18.0.0/16"
      KEEPALIVE: "25"
      VPNDNS: "1.1.1.1, 9.9.9.9"
      # For the PF success hook -> update qBittorrent automatically:
      QBT_USER: "admin"
      QBT_PASS: "${QBT_PASS}"
      QBT_WEBUI_PORT: "8080"
    volumes:
      - /srv/config/pia:/pia
      - /srv/config/pia-shared:/pia-shared
      - /srv/config/pia-scripts/pf_success.sh:/scripts/pf_success.sh:ro
    ports:
      - "8080:8080"  # qBittorrent WebUI (since qbittorrent shares this netns)

  # --- DOWNLOADER (tunneled through PIA) ---
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
    network_mode: "service:pia"
    depends_on:
      pia:
        condition: service_started
    environment:
      PUID: "1000"
      PGID: "1000"
      TZ: "America/New_York"
      WEBUI_PORT: "8080"
      QBT_WEBUI_USERNAME: "admin"
      QBT_WEBUI_PASSWORD: "${QBT_PASS}"
    volumes:
      - /srv/config/qbittorrent:/config
      - /srv/data/downloads:/downloads
      - /srv/config/pia-shared:/pia-shared:ro

  # --- SONARR (LAN visible) ---
  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    environment:
      PUID: "1000"
      PGID: "1000"
      TZ: "America/New_York"
    volumes:
      - /srv/config/sonarr:/config
      - /srv/data/media:/data/media
      - /srv/data/downloads:/data/downloads
    ports:
      - "8989:8989"

  # --- RADARR (LAN visible) ---
  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    environment:
      PUID: "1000"
      PGID: "1000"
      TZ: "America/New_York"
    volumes:
      - /srv/config/radarr:/config
      - /srv/data/media:/data/media
      - /srv/data/downloads:/data/downloads
    ports:
      - "7878:7878"

  # --- PROWLARR (indexers, off-VPN) ---
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    restart: unless-stopped
    environment:
      PUID: "1000"
      PGID: "1000"
      TZ: "America/New_York"
    volumes:
      - /srv/config/prowlarr:/config
    ports:
      - "9696:9696"

  # --- BAZARR (subtitles) ---
  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    restart: unless-stopped
    environment:
      PUID: "1000"
      PGID: "1000"
      TZ: "America/New_York"
    volumes:
      - /srv/config/bazarr:/config
      - /srv/data/media:/data/media
      - /srv/data/downloads:/data/downloads
    ports:
      - "6767:6767"

  # --- JELLYFIN (media server) ---
  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    environment:
      PUID: "1000"
      PGID: "1000"
      TZ: "America/New_York"
    volumes:
      - /srv/config/jellyfin:/config
      - /srv/data/media:/data/media
      # Uncomment if /dev/dri is passed into the container (Proxmox LXC step)
      # - /dev/dri:/dev/dri
    ports:
      - "8096:8096"

  # --- JELLYSEERR (requests) ---
  jellyseerr:
    image: fallenbagel/jellyseerr:latest
    container_name: jellyseerr
    restart: unless-stopped
    environment:
      TZ: "America/New_York"
    volumes:
      - /srv/config/jellyseerr:/app/config
    ports:
      - "5055:5055"
EOS

# ---------- bring it up ----------
echo "==> Bringing up PIA + qBittorrent first (to prime PF + port hook)"
docker compose -f /srv/media-stack.yml up -d pia qbittorrent

echo "==> Waiting ~8s for PIA to fetch PF port..."
sleep 8 || true

echo "PIA logs (tail):"
docker logs --tail=100 pia || true

if [[ -f /srv/config/pia-shared/port.dat ]]; then
  echo "PF port set to: $(cat /srv/config/pia-shared/port.dat)"
else
  echo "WARNING: PF port file not present yet. The container will retry; you can check later:"
  echo "  docker logs pia | tail -n 200"
  echo "  cat /srv/config/pia-shared/port.dat"
fi

echo "==> Bringing up the rest of the stack"
docker compose -f /srv/media-stack.yml up -d sonarr radarr prowlarr bazarr jellyfin jellyseerr

echo "==> Done."
echo "Open qBittorrent:  http://<container-ip>:8080  (admin / ${QBT_PASS})"
echo "Open Sonarr:       http://<container-ip>:8989"
echo "Open Radarr:       http://<container-ip>:7878"
echo "Open Prowlarr:     http://<container-ip>:9696"
echo "Open Bazarr:       http://<container-ip>:6767"
echo "Open Jellyfin:     http://<container-ip>:8096"
echo "Open Jellyseerr:   http://<container-ip>:5055"

echo
echo "Next steps in Sonarr/Radarr:"
echo "  Settings → Download Clients → qBittorrent:"
echo "    Host: pia    Port: 8080    User: admin    Pass: (what you set)"
echo "  Settings → Download Clients → Remote Path Mappings:"
echo "    Host: pia    Remote: /downloads    Local: /data/downloads"
