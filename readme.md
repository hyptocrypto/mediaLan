# Media Server Stack (Ubuntu 24.04 LTS in Proxmox LXC)

This repo sets up a full self-hosted media stack:

- **VPN + Port-Forwarding:** `ghcr.io/thrnz/docker-wireguard-pia` (PIA WireGuard + PF)
- **Downloader (behind VPN):** qBittorrent (LinuxServer.io) sharing the PIA network
- **Media managers:** Sonarr, Radarr
- **Indexers:** Prowlarr
- **Subtitles:** Bazarr
- **Media server:** Jellyfin
- **Requests:** Jellyseerr

All services are configured to avoid the pitfalls we hit (TUN device, PF port not applied, path mappings, “Forbidden” API calls, etc.).

---

## 0) Proxmox host prep (LXC only)

Use a **privileged** Ubuntu 24.04 container and enable:

```bash
# Replace <CTID> with your container ID
pct set <CTID> -features nesting=1,keyctl=1

# Enable /dev/net/tun
echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> /etc/pve/lxc/<CTID>.conf
echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" >> /etc/pve/lxc/<CTID>.conf

# (Optional) Pass through GPU for Jellyfin (VAAPI/AMF via /dev/dri)
echo "lxc.cgroup2.devices.allow: c 226:* rwm" >> /etc/pve/lxc/<CTID>.conf
echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir" >> /etc/pve/lxc/<CTID>.conf

# Restart the container after changing config
pct stop <CTID>; pct start <CTID>
