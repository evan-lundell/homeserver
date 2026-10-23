# Maintenance script

`maintenance.sh` is meant to run unattended (e.g. via cron): it backs up a
handful of hand-edited config files, then updates OS packages and Docker
images.

## One-time setup

1. Create your real sudoers rule from the example, filling in your actual
   Linux username (the one that owns this checkout and runs cron):

   ```sh
   sed "s/YOUR_USERNAME/$(whoami)/" homeserver-maintenance.sudoers.example > homeserver-maintenance.sudoers
   ```

   This file is gitignored (it contains your username) but is included in
   `maintenance.sh`'s own config backup, so `git clone` + your latest backup
   tarball is enough to recreate it if you ever rebuild or migrate hosts.

2. Validate and install it into `/etc/sudoers.d/` (a malformed sudoers file
   can break sudo entirely, hence `visudo -cf` before it's live):

   ```sh
   visudo -cf homeserver-maintenance.sudoers
   sudo install -o root -g root -m 0440 homeserver-maintenance.sudoers /etc/sudoers.d/homeserver-maintenance
   ```

   Without this, the `sudo apt-get update` / `sudo apt-get full-upgrade`
   steps in `maintenance.sh` will block on a password prompt under cron and
   the run will hang.

3. Add a crontab entry to actually run it on a schedule, e.g. nightly at
   3am:

   ```sh
   crontab -e
   # 0 3 * * * ~/homeserver/scripts/maintenance.sh
   ```

## Uptime Kuma push monitors (optional)

`maintenance.sh` pings `UPTIME_KUMA_PUSH_MAINTENANCE` from `.env` after a
completed run. Warnings (failed image pulls, reboot required) go in the
message. Create the matching Uptime Kuma **Push** monitor with a 25-hour
(90000s) heartbeat interval: a FATAL exit, or cron not running at all, then
shows up as an alert the next night.

`disk-check.sh` reports usage of `/` and `/mnt/media` to
`UPTIME_KUMA_PUSH_DISK`, and pushes "down" once any of them reaches 90%. Run it
every 30 minutes against a push monitor with a 60-minute (3600s) interval:

```sh
crontab -e
# */30 * * * * ~/homeserver/scripts/disk-check.sh
```

`indexer-check.sh` recovers indexers that Prowlarr has disabled after
repeated failures, and reports to `UPTIME_KUMA_PUSH_INDEXERS`. For each
disabled indexer it fetches the site from inside the VPN:

- a Cloudflare ban page (`error code: 1006`/`1015`/`1020`) means the VPN exit
  IP is banned, so it reconnects gluetun to a new random server, up to 3 tries
  and at most once every 6 hours (each reconnect briefly interrupts
  qBittorrent). This needs the `indexer-check` role in
  `gluetun/auth/config.toml` (see the main README's Uptime Kuma section);
- anything else (usually a stale Cloudflare challenge) is fixed by re-testing
  the indexer, same as Prowlarr's "Test" button.

It then re-tests the indexer in Prowlarr, and in Sonarr/Radarr for any indexer
their health page lists as unavailable, since those keep their own backoff of
up to 24 hours. It pushes "down" if an indexer is still disabled or banned.
Actions are logged to `~/homeserver-maintenance/indexer-check.log`. Run it
every 30 minutes, offset from `disk-check.sh`, against a push monitor with a
60-minute (3600s) interval:

```sh
crontab -e
# 15,45 * * * * ~/homeserver/scripts/indexer-check.sh
```

Use the push URL Uptime Kuma shows, without its `?status=...` query string.
All three scripts skip the push if the variable is unset or `changeme`.

## What it backs up

Anything hand-edited that can't be regenerated from git or from an app's own
UI (see `BACKUP_PATHS` in `maintenance.sh`) — currently `.env`, samba
config, WireGuard config, the personalized Homepage dashboard
config, and this directory's sudoers rule. Backups land in
`~/homeserver-maintenance/backups/`, one tarball per change, oldest pruned
past the last 10.

This is deliberately *not* a full disaster-recovery backup — it skips every
service's runtime state (Radarr/Sonarr/Prowlarr config + API keys, Pi-hole's
blocklists, qBittorrent's session, gluetun's server cache, Caddy's certs),
since all of that is just as easy to
regenerate by letting the app re-initialize on a fresh volume. See the
top-level README's "Backup" section if you instead want a full tarball of
everything, for exact-state disaster recovery rather than a clean rebuild.

## Restoring on a new (or rebuilt) host

```sh
git clone <this-repo-url> homeserver
cd homeserver
# copy your latest config-backup-*.tar.gz onto this host, e.g. via scp
scripts/restore.sh /path/to/config-backup-YYYYMMDD-HHMMSS.tar.gz
docker compose up -d
```

`restore.sh` extracts the backup tarball into place (same files
`maintenance.sh` backs up — see above) and creates empty directories for
everything else `compose.yaml` bind-mounts, so `docker compose up -d` has
somewhere to write instead of failing or having Docker auto-create it as
`root`. It'll also offer to install the sudoers rule for you (steps 1-2
above), and warns if `/mnt/media` or `/srv/general-share` aren't mounted
yet.

Because runtime state isn't backed up, several services come up as a fresh
install and need one-time manual attention after first boot — `restore.sh`
prints the list at the end (Jellyfin's first-run setup wizard, new
Radarr/Sonarr API keys to copy into `.env`, qBittorrent's temporary
generated password, Pi-hole's custom DNS records).
