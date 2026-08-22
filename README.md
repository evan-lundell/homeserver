# Home Server (Docker Compose Template)

A Docker Compose template for a self-hosted home server: media (Plex),
file sharing (Samba), ad-blocking DNS (Pi-hole), a reverse proxy for clean
local hostnames (Caddy), remote access (WireGuard), dynamic DNS (ddclient),
and an optional automated media stack (Prowlarr/Radarr/Sonarr/qBittorrent
behind a VPN via gluetun), with a dashboard (Homepage) tying it together.

**Every service below is independent and optional.** Nothing here requires
running the whole stack — remove any service block from `compose.yaml` (and
its related `.env` vars / config files) that you don't want.

## Setting this up with AI assistance

This repo is written to be easy to hand to an AI assistant (e.g. Claude) so
it can walk you through setup interactively — asking about your hardware,
network, and which services you actually want, rather than assuming a
specific setup. If you're using Claude, you can start with a prompt like:

```
I'm setting up my own home server using this Docker Compose template: https://github.com/evan-lundell/homeserver
(read the README and compose.yaml — fetch them if you can, otherwise I'll
paste the contents). Interview me first: what hardware/OS I'm running, my
network setup (router, whether I can set a static LAN IP, whether I want a
custom local domain, whether I want remote access from outside my home),
and which of the services in the README I actually want. Then walk me
through setup one step at a time, telling me exactly what to run or edit,
and what account/credentials to go get for each service I chose, before I
need them — don't assume I have accounts or hardware features (like Intel
Quick Sync) I haven't confirmed I have.
```

## Services

| Service    | Purpose                                | Needs an account/credential for |
|------------|------------------------------------------|-----------------------------------|
| Plex       | Media server                              | A free Plex account (claim token) |
| Samba      | File shares over your LAN                 | Just usernames/passwords you pick |
| Pi-hole    | Network-wide DNS ad-blocking + local DNS  | Nothing external |
| Caddy      | Reverse proxy for clean local hostnames   | Nothing (works alongside Pi-hole) |
| WireGuard  | VPN for remote access (wg-easy)           | Nothing external (self-contained) |
| ddclient   | Keeps a dynamic DNS hostname updated       | A DDNS provider account (e.g. No-IP) — skip if you have a static public IP or don't need remote access |
| gluetun + qBittorrent | Torrent client routed through a VPN | A VPN provider account that supports it (see [gluetun's wiki](https://github.com/qdm12/gluetun/wiki) for supported providers and credential format — varies by provider) |
| Prowlarr / Radarr / Sonarr | Automated media search & management | Nothing to start; each generates its own API key on first run |
| Homepage   | Dashboard linking all of the above        | Nothing extra to start — reuses the above (optional: a free [Finnhub](https://finnhub.io/register) key for the stock widget, a Google Calendar ICS URL for the calendar widget) |

None of these depend on each other except: Caddy assumes you're using
Pi-hole (or some other local DNS) to resolve your chosen local hostnames;
qBittorrent depends on gluetun (`network_mode: "service:gluetun"`); and
Homepage's dashboard widgets need whatever API keys/passwords the services
they point at were given.

## Setup walkthrough

### 0. Decide what you want

Read the table above and decide which services you actually want. For
anything you're skipping, you can delete that service's block from
`compose.yaml` (and skip its related `.env` vars and config files below) as
you go — none of this needs to happen up front.

### 1. Host prerequisites

You need a Linux host (this has been run on Debian; other distros work
similarly) with Docker and Docker Compose installed. Beyond that, a couple
of things are hardware/environment-dependent — check what applies to you:

- **Plex hardware transcoding**: if your CPU has Intel Quick Sync and you
  want hardware-accelerated transcoding, install
  `intel-media-va-driver-non-free` on the host (the `/dev/dri` device
  passthrough is already in `compose.yaml`). If not, either remove the
  `devices:` entry under `plex` or leave it — Plex falls back to software
  transcoding if the device isn't usable.
- **Plex + USB devices**: the `/dev/bus/usb` passthrough is there to avoid a
  `libusb_init failed` crash some setups hit; if you don't need it you can
  remove it.
- **Media storage**: mount your media drive(s) wherever makes sense for
  your setup, then update the volume paths in `compose.yaml` (`plex`,
  `radarr`, `sonarr`, `qbittorrent`, `homepage`, and the `samba` `[media]`
  share) to match. There's nothing filesystem-specific required, but if
  you're on NTFS via NTFS-3G and Samba writes are misbehaving, see the
  Samba note below.

### 2. Clone and configure

1. Clone this repo to wherever you want it on the server (e.g. `~/homeserver`).
2. Copy each `.example` file and fill in real values:
   - `.env.example` → `.env`
   - `ddclient/ddclient.conf.example` → `ddclient/ddclient.conf` (skip if
     you're not using ddclient)
   - `samba/smb.conf.example` → `samba/smb.conf` (skip if you're not using
     Samba) — see "Setting up your own Samba users" below
   - `homepage/config/*.yaml.example` → strip the `.example` suffix from
     each (`services.yaml`, `widgets.yaml`, `bookmarks.yaml`, `settings.yaml`,
     `docker.yaml`) — the dashboard config; see "Homepage" below
3. Create the host directories each service you're keeping needs (these
   hold runtime state and aren't tracked in git). From inside the cloned
   repo directory, skipping any that belong to a service you removed:
   ```
   mkdir -p plex/config plex/transcode
   mkdir -p wireguard
   mkdir -p pihole/etc-pihole pihole/etc-dnsmasq.d
   mkdir -p caddy/data caddy/config
   mkdir -p gluetun qbittorrent prowlarr radarr sonarr
   sudo mkdir -p /srv/general-share && sudo chown "$(id -un):$(id -gn)" /srv/general-share
   ```

### 3. Fill in credentials as you go

- **Plex**: get a fresh claim token from https://plex.tv/claim (expires in
  4 minutes) and set it right before first start.
- **Samba**: pick usernames/passwords — see "Setting up your own Samba
  users" below.
- **Pi-hole**: pick a password for `PIHOLE_PASSWORD` — no external account
  needed.
- **WireGuard (wg-easy)**: the admin dashboard password is a bcrypt hash,
  not plaintext — generate it with:
  `docker run --rm ghcr.io/wg-easy/wg-easy wgpw 'yourpassword'`
  If you set the hash directly in `compose.yaml` instead of `.env`, escape
  every `$` as `$$` or Compose will mangle it. For remote access to work at
  all, you also need to forward UDP port 51820 (WireGuard's default) on
  your router to the server's LAN IP — without that, peers can't reach the
  server from outside your home network. The admin dashboard itself (port
  51821) is only needed on your LAN and should *not* be forwarded.
- **ddclient**: sign up with a DDNS provider (e.g. No-IP), point a hostname
  at your public IP, and put the login/password/hostname in
  `ddclient/ddclient.conf`. Set that same hostname as `DDNS_HOSTNAME` in
  `.env` (used for WireGuard's public address) — and `SERVER_LAN_IP` to
  your server's static/reserved LAN IP (used for WireGuard's DNS setting
  and Homepage's allowed hosts).
- **gluetun**: set `VPN_SERVICE_PROVIDER` in `compose.yaml` to your
  provider and fill in whatever credentials that provider needs (varies —
  check gluetun's wiki linked above).
- **Radarr / Sonarr**: these generate their own API key on first run. Start
  them (`docker compose up -d radarr sonarr`), open their web UIs, copy the
  API key from Settings → General, then put it in `.env` and restart
  Homepage so its dashboard widgets can use it.

### 4. Start it

```
docker compose up -d
```

### 5. Local hostnames (only if using Pi-hole + Caddy)

1. In Pi-hole's admin UI, add a local DNS record for each hostname you used
   in your Caddyfile, pointing at the server's static IP.
2. Point your router's DNS server setting at the server's IP (Pi-hole).
   Keep a public fallback (e.g. `1.1.1.1`) as secondary DNS in case Pi-hole
   is ever down.
3. SSH access (and anything else you need available when Pi-hole is down)
   should use the server's static IP directly, not a Pi-hole-resolved name.

## Notes on specific services

**Plex**
- Media paths are whatever you mounted in step 1 — just keep the container
  paths (`/data/movies`, `/data/shows`, etc.) consistent with what Radarr/
  Sonarr expect if you're using those too.

**Samba**
- Ships with a custom `smb.conf` rather than the image's auto-generated
  one, with a minimal set of VFS modules. If you hit failures writing large
  files (this is a known issue with the `streams_xattr`/`fruit`/`catia`
  modules over an NTFS-3G mount specifically), trim modules back to what's
  in `smb.conf.example` and only add them back deliberately (e.g. `fruit`
  for macOS Time Machine support).
- `smb.conf` is gitignored (usernames/shares are setup-specific) — start
  from `smb.conf.example`.

**Setting up your own Samba users** (usernames appear in three places —
change all of them together, to whatever names/number of users you want):
1. `compose.yaml` — the samba `command:` block's `-u "name;${VAR}"` entries
   (add/remove lines for however many users you need)
2. `.env` — the `${VAR}` password variable(s) referenced above
3. `samba/smb.conf` (copied from `smb.conf.example`) — the `valid users` /
   `write list` entries in each share, which must match the usernames from
   step 1

**WireGuard (wg-easy)**
- Peers can be scoped via "Allowed IPs": `0.0.0.0/0, ::/0` for full-tunnel
  (routes all traffic through home), or a narrower subnet/single IP for
  home-network-only or single-service-only access.

**Pi-hole**
- Runs with `network_mode: host` — required because Docker's bridge
  network causes dnsmasq to reject queries as coming from a
  "non-local network."
- If Caddy is also running on the host and owns ports 80/443, move
  Pi-hole's web UI to another port via `FTLCONF_webserver_port` (already
  done here, port 8080).

**Caddy**
- If you're using made-up local domains (anything not a real public TLD),
  use `http://` explicitly for them in the Caddyfile — Caddy's automatic
  HTTPS/Let's Encrypt provisioning fails for non-public TLDs and will loop
  retrying certificate issuance otherwise.
- A service's redirect target (e.g. Plex needing `/web`, Pi-hole needing
  `/admin`) is handled by Caddy's `redir` directive, but some browser/
  extension combinations are flaky about respecting `http://` on the
  redirect specifically. If a service seems to "not work" in one browser,
  try clearing that domain's history/cache or just bookmark the full path.

**ddclient**
- Only pushes an update when your public IP actually changes — seeing
  "nochg" in the logs is success, not an error.

**Homepage**
- `homepage/config/{services,widgets,bookmarks,settings,docker}.yaml` are
  gitignored — this is where the dashboard actually gets personalized
  (weather location, stock watchlist, bookmarks, local hostnames) and tends
  to drift from anything worth committing. Start from the matching
  `.example` files; `kubernetes.yaml` and `proxmox.yaml` are unused
  generated stubs (this template doesn't run Kubernetes or Proxmox) and stay
  tracked as-is.
- The container needs `PUID=0`/`PGID=0` (root) to read the mounted
  `docker.sock` for per-service container stats — see the comment in
  `compose.yaml` for why (the image's entrypoint drops supplementary groups
  when switching to a non-root PUID/PGID, so `group_add` alone doesn't
  work). This is already set; no action needed unless you remove it.
- Stock widget: set `FINNHUB_API_KEY` in `.env` and list symbols under
  `widgets.yaml`'s `stocks.watchlist` (max 8). Finnhub's free tier covers
  regular stocks/ETFs but not mutual funds (a `403` on that symbol from
  their `/quote` endpoint means that's what you hit).
- Calendar widget: set `GCAL_ICS_URL` in `.env` to your calendar's secret
  iCal address (Google Calendar: Settings → your calendar → Integrate
  calendar → "Secret address in iCal format") to fold it in alongside the
  Sonarr/Radarr release calendars. Treat that URL like a password — it
  grants read access to your calendar.

## Backup

Full state backups (secrets, service databases, WireGuard keys, Pi-hole
data, etc.) should be tarballs, not git — git only tracks the "recipe"
(`compose.yaml` + plain-text configs with no secrets), not runtime state.

```
sudo tar -czvf ~/backup-$(date +%Y%m%d).tar.gz -C ~ <repo-directory-name>
```
(replace `<repo-directory-name>` with whatever you named the cloned repo
directory, e.g. `docker` or `homeserver`)

Store this off the server (another device, external drive) — a backup
sitting only on the server doesn't help if the server itself fails.

For an automated, much smaller alternative that only backs up hand-edited
config (not runtime state/databases) and a script that restores it onto a
fresh clone, see `scripts/README.md`.
