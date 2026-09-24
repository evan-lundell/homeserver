# Home Server (Docker Compose Template)

A Docker Compose template for a self-hosted home server: media (Jellyfin),
file sharing (Samba), ad-blocking DNS (Pi-hole), a reverse proxy for clean
local hostnames (Caddy), remote access (WireGuard),
an optional automated media stack (Prowlarr/Radarr/Sonarr/qBittorrent behind
a VPN via gluetun), and optional game streaming (Sunshine + Moonlight), with
a dashboard (Homepage) tying it together.

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
| Jellyfin   | Media server                              | Nothing — admin account and libraries are set up in its own first-run wizard |
| Sunshine   | Game streaming host — play emulators (or anything else) from any device via a Moonlight client | Nothing external — pair via a one-time PIN in the Moonlight app. Significantly more host-dependent setup than everything else here; see notes below |
| Samba      | File shares over your LAN                 | Just usernames/passwords you pick |
| Pi-hole    | Network-wide DNS ad-blocking + local DNS  | Nothing external |
| Caddy      | Reverse proxy for clean local hostnames   | Nothing (works alongside Pi-hole) |
| WireGuard  | VPN for remote access (wg-easy)           | A domain (or subdomain) with an A record pointing at your static public IP — skip if you don't need remote access |
| gluetun + qBittorrent | Torrent client routed through a VPN | A VPN provider account that supports it (see [gluetun's wiki](https://github.com/qdm12/gluetun/wiki) for supported providers and credential format — varies by provider) |
| Prowlarr / Radarr / Sonarr | Automated media search & management | Nothing to start; each generates its own API key on first run |
| Bazarr     | Subtitle downloads for Radarr/Sonarr libraries (incl. forced/foreign-dialogue subs) | Nothing to start; subtitle providers (e.g. a free [OpenSubtitles](https://www.opensubtitles.com) account) are added in its UI |
| FlareSolverr | Solves Cloudflare challenges for Prowlarr indexers that need it | Nothing — no account, no config |
| Homepage   | Dashboard linking all of the above        | Nothing extra to start — reuses the above (optional: a free [Finnhub](https://finnhub.io/register) key for the stock widget, a Google Calendar ICS URL for the calendar widget) |
| Uptime Kuma | Uptime monitoring/alerting for your other services | Nothing external — admin account is created in its UI on first visit |

None of these depend on each other except: Caddy assumes you're using
Pi-hole (or some other local DNS) to resolve your chosen local hostnames;
qBittorrent, Prowlarr, and FlareSolverr depend on gluetun
(`network_mode: "service:gluetun"`); and Homepage's dashboard widgets need
whatever API keys/passwords the services they point at were given.

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

- **Jellyfin hardware transcoding**: if your CPU has Intel Quick Sync
  and you want hardware-accelerated transcoding, install
  `intel-media-va-driver-non-free` on the host (the `/dev/dri` device
  passthrough is already in `compose.yaml`). If not, either remove
  the `devices:` entry under `jellyfin` or leave it — it falls back
  to software transcoding if the device isn't usable.
- **Media storage**: mount your media drive(s) wherever makes sense for
  your setup, then update the volume paths in `compose.yaml` (`jellyfin`,
  `radarr`, `sonarr`, `qbittorrent`, `homepage`, and the `samba`
  `[media]` share) to match. There's nothing filesystem-specific required,
  but if you're on NTFS via NTFS-3G and Samba writes are misbehaving, see
  the Samba note below; if you're pooling drives with `mergerfs`, see the
  gotcha under Sunshine below (only relevant if you use Sunshine).
- **Sunshine game streaming**: needs a GPU with a hardware video encoder —
  `sunshine/Dockerfile` here is set up for Intel Quick Sync (VAAPI) on a
  headless host. See "Sunshine" under Notes below before enabling this one;
  it needs more host-specific tuning than anything else in this template.

### 2. Clone and configure

1. Clone this repo to wherever you want it on the server (e.g. `~/homeserver`).
2. Copy each `.example` file and fill in real values:
   - `.env.example` → `.env`
   - `samba/smb.conf.example` → `samba/smb.conf` (skip if you're not using
     Samba) — see "Setting up your own Samba users" below
   - `homepage/config/*.yaml.example` → strip the `.example` suffix from
     each (`services.yaml`, `widgets.yaml`, `bookmarks.yaml`, `settings.yaml`,
     `docker.yaml`) — the dashboard config; see "Homepage" below
3. Create the host directories each service you're keeping needs (these
   hold runtime state and aren't tracked in git). From inside the cloned
   repo directory, skipping any that belong to a service you removed:
   ```
   mkdir -p jellyfin/config
   mkdir -p wireguard
   mkdir -p pihole/etc-pihole pihole/etc-dnsmasq.d
   mkdir -p caddy/data caddy/config
   mkdir -p gluetun qbittorrent prowlarr radarr sonarr bazarr
   mkdir -p uptime-kuma
   mkdir -p speedtest-tracker
   mkdir -p sunshine/home
   sudo mkdir -p /srv/general-share && sudo chown "$(id -un):$(id -gn)" /srv/general-share
   ```

### 3. Fill in credentials as you go

- **Jellyfin**: no account needed — start it (`docker compose up -d
  jellyfin`), open its web UI, and complete the first-run setup wizard
  (admin user + media library paths). If you want it on Homepage's
  dashboard, generate an API key afterward in Dashboard → Advanced → API
  Keys, then put it in `.env` and restart Homepage.
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
  51821) is only needed on your LAN and should *not* be forwarded. Point
  an A record for your domain at your router's public IP (needs to be
  static, or reserved/static via your ISP) and set it as `PUBLIC_DOMAIN`
  in `.env` — and `SERVER_LAN_IP` to your server's static/reserved LAN IP
  (used for WireGuard's DNS setting and Homepage's allowed hosts).
- **gluetun**: configured for ProtonVPN over WireGuard with port forwarding
  on. Generate a WireGuard config at
  https://account.proton.me/u/0/vpn/WireGuard (check "NAT-PMP (Port
  Forwarding)" first) and put its private key in `.env` as
  `PROTONVPN_WIREGUARD_PRIVATE_KEY`. Also enable qBittorrent's WebUI setting
  "Bypass authentication for clients on localhost" — gluetun pushes the
  forwarded port to qBittorrent's API on that assumption. Switching to a
  different provider means changing `VPN_SERVICE_PROVIDER` (and likely
  `VPN_TYPE`/credentials) in `compose.yaml` — see gluetun's wiki linked
  above for that provider's format.
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

**Jellyfin**
- Media paths are whatever you mounted in step 1 — just keep the container
  paths (`/data/movies`, `/data/shows`, etc.) consistent with what Radarr/
  Sonarr expect if you're using those too.
- No official client app for Meta Quest (only community VR projects,
  sideloaded); Fire TV/Android TV has an official one from the Amazon
  Appstore.

**Sunshine**
- By far the most host-dependent service in this template — expect to tune
  things for your specific GPU/host rather than have it work unmodified.
  `sunshine/Dockerfile` and `sunshine/entrypoint.sh` are set up for an Intel
  iGPU (VAAPI, Mesa `iris`/Vulkan) on an otherwise headless Debian host with
  an **HDMI dummy plug** (a ~$5 EDID emulator) in the video output; adapt the
  driver packages/`LIBVA_DRIVER_NAME` for Nvidia (NVENC) or AMD. A host with a
  real monitor attached doesn't need the plug.
- **Capture needs a real Xorg server with the `modesetting` driver, not Xvfb
  and not the `dummy` video driver.** Xvfb has no input driver stack at all,
  so Sunshine's uinput-injected mouse/keyboard never reaches it — only a real
  Xorg session (with `xserver-xorg-input-libinput`) can pick those up. And the
  fake `dummy` *video* driver has no GPU path: OpenGL falls back to CPU
  `llvmpipe` (far too slow for 3DS emulation) and Vulkan fails at surface
  creation (`Failed to initialize Xlib surface: ErrorOutOfHostMemory`) because
  `dummy` can't back the DRI3/Present machinery. With a physical (dummy) plug
  connected, `modesetting` gets full hardware GL/Vulkan. The container also
  needs the host's `video` group (for `/dev/dri/card0` modesetting, not just
  `renderD128` for encoding) and `mesa-vulkan-drivers` (without a registered
  Vulkan ICD, Azahar segfaults on launch).
- That input path also needs, all at once: a udev rule loosening
  `/dev/uinput` permissions (`KERNEL=="uinput", GROUP="input", MODE="0660"`),
  a bind mount of the *whole* `/dev/input` directory (not just `devices:`,
  which only snapshots fixed paths — new virtual input devices are created
  dynamically per session), a `device_cgroup_rules` entry allowlisting Linux's
  input major number (`c 13:* rmw`, since bind-mounting a path doesn't grant
  cgroup device access on its own), a read-only mount of `/run/udev` (so the
  container can read the host's device database), and `network_mode: host`
  (udev hotplug notifications are a netlink broadcast scoped to the network
  namespace the device was created in — a container's own network namespace
  never sees them otherwise). Skipping any one of these results in video
  working fine but mouse/keyboard input silently doing nothing.
- If HEVC throws encoder errors on real frames (`Failed to end picture
  encode`) — seen on at least one Intel Skylake iGPU — force H.264-only via
  `hevc_mode = 1` in `sunshine.conf` (already done for you in
  `entrypoint.sh`, gated on nothing hardware-specific, so harmless to leave
  even if your GPU's HEVC encoder works fine).
- CSRF: Sunshine validates the browser `Origin` header against
  `csrf_allowed_origins` in its config. Whatever hostname(s)/IP:port you
  actually use to reach its web UI (LAN IP, and/or a Caddy hostname like
  `sunshine.evan`) need to be listed there or login fails with a CSRF error.
  `entrypoint.sh` seeds this from `SERVER_LAN_IP`; add further origins as a
  comma-separated list.
- If proxying through Caddy: Sunshine's web UI is HTTPS-only with a
  self-signed cert, so the reverse proxy needs
  `reverse_proxy https://localhost:47990 { transport http { tls_insecure_skip_verify } }`
  rather than a plain `reverse_proxy`.
- **If pooling media storage with `mergerfs`** (this template's example
  `/mnt/media` setup): its file-*creation* permission check only honors
  owner/group match, not "other" bits, even though `ls` shows them —
  confirmed by testing, not just a config quirk (writes to *existing*
  world-writable files work fine; only *creating new* files misbehaves). In
  practice this means a save file an emulator tries to create fresh (e.g. a
  DS `.sav`) can fail with a permission error despite `777` on the folder.
  The fix used here: match the container's user to your host UID/GID
  (`usermod -u 1000 lizard && groupmod -g 1000 lizard` in the Dockerfile,
  1000 being this template's assumed primary host user — adjust to your own
  `id -u`), not looser permissions.
- Bundles melonDS (DS), Azahar (3DS), and mGBA (GBA/GB/GBC) by default, installed as AppImages
  at build time — see `sunshine/Dockerfile` to swap in other
  emulators/systems. ROMs aren't included; point `sunshine/roms` (or
  wherever you mount `/roms`) at your own legally-owned dumps, and add each
  emulator as a Sunshine "Application" (web UI → Applications) pointing at
  its extracted `AppRun` binary.
- Both emulators run well with the plug + `modesetting` setup: melonDS
  (DS) trivially, Azahar (3DS) on Vulkan (`graphics_api=2` in its
  `qt-config.ini`) at full speed on an Intel HD 530. 3DS emulation is
  CPU-hungry though: pin the host CPU governor to `performance`
  (`sunshine/cpu-performance-governor.service` — copy it to
  `/etc/systemd/system/`, `daemon-reload`, `enable --now`). `powersave` held
  an i5-6500 near 2.7GHz instead of its 3.6GHz turbo and caused in-game
  stutter that looked like a network problem (it wasn't — interface
  error/drop counters were ~zero).
- **`/tmp` survives `docker restart`** (only a full recreate wipes it), so any
  stale runtime file in it breaks startup silently. The entrypoint clears the
  X lock/socket and PulseAudio's runtime dir for this reason: a killed
  PulseAudio leaves a `pid` file that makes `pulseaudio --start` think it's
  still running and start nothing — no stream audio, and Azahar segfaults
  when you open Emulation > Configure mid-game (cubeb audio-device
  enumeration against the dead server). If you add another daemon to the
  entrypoint, give it the same treatment.

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
- A service's redirect target (e.g. Pi-hole needing
  `/admin`) is handled by Caddy's `redir` directive, but some browser/
  extension combinations are flaky about respecting `http://` on the
  redirect specifically. If a service seems to "not work" in one browser,
  try clearing that domain's history/cache or just bookmark the full path.

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

**FlareSolverr**
- Only needed if a specific Prowlarr indexer starts failing with a
  Cloudflare challenge error. Runs behind gluetun
  (`network_mode: "service:gluetun"`) like Prowlarr/qBittorrent, so its
  solved-challenge traffic goes out the same VPN IP Prowlarr's own indexer
  requests use — running it outside gluetun risks an IP mismatch that makes
  Cloudflare re-challenge, and defeats the point of routing indexer traffic
  through the VPN.
- No web UI worth linking (hitting it returns raw JSON) and no widget type
  in Homepage, so it isn't on the dashboard.
- To wire it up: in Prowlarr, go to Settings → Indexers → Indexer Proxies,
  add a FlareSolverr proxy with host `http://localhost:8191` (shared
  network namespace with Prowlarr, so `localhost` — not a container name —
  is what resolves), then set the affected indexer(s) to use it.

**Uptime Kuma**
- On first visit to `http://uptime.evan` (or `localhost:3001`) you'll be
  prompted to create an admin account — this happens in its own UI, not via
  `.env`.
- Add a monitor for each service you want tracked (e.g. `http://jellyfin.evan`,
  `http://radarr.evan`).
- The Homepage widget reads from a **status page**, not raw monitors: in
  Uptime Kuma, go to Status Pages, add your monitors to the default page (or
  create a new one), and match its slug in `services.yaml`'s `uptimekuma`
  widget (defaults to `default` here). Skip the `widget:` block if you don't
  want this.

**Speedtest Tracker**
- Runs an Ookla speed test on the schedule in `compose.yaml`
  (`SPEEDTEST_SCHEDULE`, every 2 hours by default) and keeps the history.
- Before first start, fill in `SPEEDTEST_APP_KEY` (generate with
  `echo "base64:$(openssl rand -base64 32)"`), `SPEEDTEST_ADMIN_EMAIL` and
  `SPEEDTEST_ADMIN_PASSWORD` in `.env`. The admin values are only read when
  the database is first created; change them later in the UI.
- For the Homepage widget: log in at `http://speedtest.evan` (or
  `localhost:8765`), create an API token with read access (under your
  profile → API Tokens), put it in `.env` as `SPEEDTEST_API_KEY`, and
  recreate Homepage (`docker compose up -d homepage`).

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
