# Home Server — evan-server

Debian 13 (Trixie) server built from a hand-me-down PC (i5-6500, 8GB DDR3 RAM),
running Plex, file sharing, VPN, ad blocking, and dynamic DNS via Docker Compose.

## Services

| Service    | Purpose                              | Local URL / Address              |
|------------|---------------------------------------|-----------------------------------|
| Plex       | Media server (Quick Sync HW transcode) | http://plex.evan/web             |
| Samba      | File shares (media + general)          | smb://samba.evan/media, /general |
| WireGuard  | VPN (wg-easy)                          | http://wireguard.evan             |
| ddclient   | Keeps No-IP DDNS hostname updated      | evanlundell.ddns.net (n/a — background service) |
| Pi-hole    | Network-wide DNS ad blocking + local DNS | http://pihole.evan/admin        |
| Caddy      | Reverse proxy for clean .evan URLs     | (routes the above, no direct UI) |

All `.evan` names resolve via Pi-hole, which the router (Orbi) uses as its
primary DNS server. SSH access uses the static reserved IP directly (not a
`.evan` name) so it doesn't depend on Pi-hole being up.

## Setup from scratch (e.g. new hardware, disaster recovery)

1. Install Debian, Docker, Docker Compose (see project history / notes for
   full OS-level steps — kernel updates, sudo, Quick Sync drivers via
   `intel-media-va-driver-non-free`, NTFS mount for the media drive, etc.)
2. Clone this repo to `~/docker` on the server.
3. Copy each `.example` file and fill in real values:
   - `.env.example` → `.env`
   - `ddclient/ddclient.conf.example` → `ddclient/ddclient.conf`
4. Create required host directories (not tracked in git):
   ```
   mkdir -p ~/docker/plex/config ~/docker/plex/transcode
   mkdir -p ~/docker/wireguard
   mkdir -p ~/docker/pihole/etc-pihole ~/docker/pihole/etc-dnsmasq.d
   mkdir -p ~/docker/caddy/data ~/docker/caddy/config
   sudo mkdir -p /srv/general-share && sudo chown evan:evan /srv/general-share
   ```
5. Confirm `/mnt/media` is mounted (NTFS drive, see `/etc/fstab` entry —
   UUID-based, `uid=1000,gid=1000,windows_names`).
6. Get a fresh Plex claim token from https://plex.tv/claim (expires in 4 min)
   and set it in `.env` or directly in `compose.yaml` before first start.
7. `docker compose up -d`
8. In Pi-hole's admin UI, add local DNS records for each `.evan` hostname
   pointing at the server's static IP.
9. Point the router's DNS server setting at the server's IP (Pi-hole).
   Keep a public fallback (e.g. 1.1.1.1) as secondary DNS in case Pi-hole
   is ever down.

## Notes on specific services

**Plex**
- Quick Sync hardware transcoding requires `/dev/dri` passthrough (already
  in compose.yaml) and `intel-media-va-driver-non-free` installed on the host.
- USB device passthrough (`/dev/bus/usb`) is required to avoid a
  `libusb_init failed` crash loop on startup.
- Media paths: `/mnt/media/Plex/Movies` and `/mnt/media/Plex/Shows` on the
  host, mounted to `/data/movies` and `/data/shows` in the container.

**Samba**
- Custom `smb.conf` (not the image's auto-generated one) — the default
  config's `streams_xattr`/`fruit`/`catia` VFS modules broke large file
  writes over the NTFS-3G mount. Keep the custom config minimal; only add
  modules back deliberately if a specific need arises (e.g. macOS Time
  Machine support via `fruit`).
- Two shares: `[media]` (evan only, read/write) and `[general]` (evan +
  wife, read/write via `write list`).
- Multiple Samba users are added via repeated `-u "user;pass"` entries in
  the `command:` block, referencing `.env` variables.

**WireGuard (wg-easy)**
- Admin dashboard password is stored as a bcrypt hash (`PASSWORD_HASH`),
  not plaintext — generate with:
  `docker run --rm ghcr.io/wg-easy/wg-easy wgpw 'yourpassword'`
- If setting the hash directly in compose.yaml (not `.env`), every `$`
  must be escaped as `$$` or Compose will mangle it.
- Peers can be scoped via "Allowed IPs": `0.0.0.0/0, ::/0` for full-tunnel
  (routes all traffic through home), or a narrower subnet/single IP for
  home-network-only or single-service-only access.

**Pi-hole**
- Runs with `network_mode: host` — required because Docker's bridge
  network causes dnsmasq to reject queries as coming from a
  "non-local network."
- Web UI moved to port 8080 (via `FTLCONF_webserver_port`) since Caddy
  owns port 80/443 on the host.

**Caddy**
- Local `.evan` domains use `http://` explicitly in the Caddyfile (not
  bare domain names) — Caddy's automatic HTTPS/Let's Encrypt provisioning
  fails for non-public TLDs and will loop retrying certificate issuance
  otherwise.
- Plex needs `/web` appended (`plex.evan/web`), Pi-hole needs `/admin`
  (`pihole.evan/admin`) — Caddy's `redir` directive handles the bare-domain
  redirect, but some browser/extension combinations have been flaky about
  respecting `http://` on the redirect specifically. If a service seems to
  "not work" in one browser, try clearing that domain's history/cache or
  just bookmark the full path directly.

**ddclient**
- Only pushes an update to No-IP when the public IP actually changes —
  seeing "nochg" in the logs is success, not an error.

## Backup

Full state backups (secrets, Plex database, WireGuard keys, Pi-hole data)
are tarballs, not git — see `docker-backup-YYYYMMDD.tar.gz`. Git only
tracks the "recipe" (compose.yaml + plain-text configs with no secrets),
not runtime state.

```
sudo tar -czvf ~/docker-backup-$(date +%Y%m%d).tar.gz -C ~ docker
```

Store this off the server (another device, external drive) — a backup
sitting only on the server doesn't help if the server itself fails.

## Storage

- OS drive: 223.6GB SSD (also hosts `/srv/general-share` for the Samba
  `[general]` share).
- Media drive: currently a single 465.8GB NTFS drive (`/mnt/media`),
  originally used with a Raspberry Pi Plex setup. Planned: add a second
  drive, migrate this one to ext4 (using the new drive as staging), and
  pool both with mergerfs. Not yet started as of this writing.

## Planned / potential future additions

- *arr stack (Sonarr, Radarr, Prowlarr, Overseerr) + qBittorrent behind
  gluetun (ExpressVPN) for automated media management — qBittorrent only
  routes through the VPN via `network_mode: "service:gluetun"`; everything
  else stays on the normal network.
- Immich (self-hosted photos) — evaluated, decided to stick with iCloud
  for now given backup/redundancy tradeoffs.
- Monitoring/dashboard (Uptime Kuma or similar).
