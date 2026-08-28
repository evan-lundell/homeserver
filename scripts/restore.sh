#!/bin/bash
#
# Restore a maintenance.sh config backup onto a fresh clone of this repo,
# and create the runtime directories every other service's bind mount
# needs so `docker compose up -d` can start clean. Meant for first-time
# setup on a new/rebuilt host — see scripts/README.md.
#
# Usage: scripts/restore.sh <path-to-config-backup-tarball>

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <path-to-config-backup-tarball>" >&2
    exit 1
fi

BACKUP_FILE="$1"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -f "$BACKUP_FILE" ]; then
    echo "Backup file not found: $BACKUP_FILE" >&2
    exit 1
fi

echo "Restoring config from $BACKUP_FILE into $REPO"
read -r -p "This will overwrite any matching files already in $REPO. Continue? [y/N] " REPLY
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

tar -xzf "$BACKUP_FILE" -C "$REPO"
echo "Config files restored."

# Everything else compose.yaml bind-mounts but has no hand-edited config
# for — these just need to exist empty. Each app self-initializes on first
# `docker compose up -d` (new Radarr/Sonarr/Prowlarr API keys, fresh
# Pi-hole blocklists, new Caddy certs, etc), so there's nothing to restore
# for them, matching what maintenance.sh treats as regeneratable.
RUNTIME_DIRS=(
    jellyfin/config
    pihole/etc-pihole
    pihole/etc-dnsmasq.d
    caddy/data
    caddy/config
    gluetun
    qbittorrent
    prowlarr
    radarr
    sonarr
    homepage/config/logs
)

echo "Creating empty runtime directories..."
for d in "${RUNTIME_DIRS[@]}"; do
    mkdir -p "$REPO/$d"
done

# The sudoers rule needs root to install — ask rather than doing it silently.
SUDOERS_SRC="$REPO/scripts/homeserver-maintenance.sudoers"
if [ -f "$SUDOERS_SRC" ]; then
    read -r -p "Install the maintenance sudoers rule to /etc/sudoers.d/ now? [y/N] " REPLY
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        if visudo -cf "$SUDOERS_SRC" \
            && sudo install -o root -g root -m 0440 "$SUDOERS_SRC" /etc/sudoers.d/homeserver-maintenance; then
            echo "Sudoers rule installed."
        else
            echo "Sudoers install failed — see scripts/README.md to do it manually." >&2
        fi
    fi
fi

# Bind mounts pointing outside the repo (media, general share) aren't
# managed by this repo or the backup — just flag if they're missing.
for m in /mnt/media /srv/general-share; do
    [ -d "$m" ] || echo "WARNING: $m does not exist yet — set it up before 'docker compose up -d'."
done

cat <<'EOF'

Done. Before "docker compose up -d":
  - Review .env — confirm SERVER_LAN_IP, DDNS_HOSTNAME, etc. match this host.
  - Confirm /mnt/media and /srv/general-share (if used) are mounted.

After first boot, these come up fresh and need manual attention:
  - Jellyfin: complete the first-run setup wizard (admin user + media
    library paths).
  - Radarr / Sonarr: generate new API keys on first run — update
    RADARR_API_KEY / SONARR_API_KEY in .env to match, then
    `docker compose up -d homepage` to pick them up.
  - qBittorrent: check `docker compose logs qbittorrent` for the
    auto-generated temporary admin password on first login.
  - Pi-hole: blocklists rebuild themselves (gravity update) but any
    custom local DNS records need re-adding.
EOF
