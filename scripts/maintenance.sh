#!/bin/bash
#
# Automatic update + minimal config backup for the homeserver.
# Intended to run unattended via cron (see scripts/README.md or crontab -l).

REPO=~/homeserver
STATE_DIR=~/homeserver-maintenance
BACKUP_DIR="$STATE_DIR/backups"
LOGFILE="$STATE_DIR/maintenance.log"
HASH_FILE="$STATE_DIR/last-backup.sha256"
DATE=$(date +%Y%m%d-%H%M%S)

mkdir -p "$BACKUP_DIR"

log() {
    echo "$1" >> "$LOGFILE"
}

log "=== Maintenance run: $DATE ==="

# 1. Back up hand-edited config/secrets, but only the files that can't be
#    regenerated from git or from the apps' own UIs, and only when they've
#    actually changed since the last backup.
BACKUP_PATHS=(
    .env
    ddclient/ddclient.conf
    samba/smb.conf
    wireguard
    homepage/config/services.yaml
    homepage/config/widgets.yaml
    homepage/config/bookmarks.yaml
    homepage/config/settings.yaml
    homepage/config/docker.yaml
    scripts/homeserver-maintenance.sudoers
)

log "--- Checking config backup ---"
cd "$REPO" || { log "FATAL: cannot cd to $REPO"; exit 1; }

EXISTING_PATHS=()
for p in "${BACKUP_PATHS[@]}"; do
    [ -e "$p" ] && EXISTING_PATHS+=("$p")
done

NEW_HASH=$(tar -cf - -C "$REPO" "${EXISTING_PATHS[@]}" 2>>"$LOGFILE" | sha256sum | awk '{print $1}')
OLD_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")

if [ "$NEW_HASH" != "$OLD_HASH" ]; then
    BACKUP_FILE="$BACKUP_DIR/config-backup-$DATE.tar.gz"
    tar -czf "$BACKUP_FILE" -C "$REPO" "${EXISTING_PATHS[@]}" >> "$LOGFILE" 2>&1
    echo "$NEW_HASH" > "$HASH_FILE"
    log "Config changed, wrote $BACKUP_FILE"
    # Keep the last 10 config backups
    ls -1t "$BACKUP_DIR"/config-backup-*.tar.gz 2>/dev/null | tail -n +11 | xargs -r rm --
else
    log "No config changes since last backup, skipping"
fi

# 2. OS package updates
log "--- Updating OS packages ---"
sudo apt-get update >> "$LOGFILE" 2>&1
if [ $? -ne 0 ]; then
    log "FATAL: apt-get update failed, aborting run"
    exit 1
fi
sudo apt-get full-upgrade -y >> "$LOGFILE" 2>&1
if [ $? -ne 0 ]; then
    log "FATAL: apt-get full-upgrade failed, aborting run"
    exit 1
fi

# 3. Pull latest Docker images
log "--- Pulling Docker images ---"
docker compose pull >> "$LOGFILE" 2>&1
if [ $? -ne 0 ]; then
    log "FATAL: docker compose pull failed, aborting run"
    exit 1
fi

# 4. Recreate containers with new images
log "--- Recreating containers ---"
docker compose up -d >> "$LOGFILE" 2>&1
if [ $? -ne 0 ]; then
    log "FATAL: docker compose up failed, aborting run"
    exit 1
fi

# 5. gluetun-dependent containers need explicit recreation
#    in case gluetun itself got a new image (network namespace gets recreated)
log "--- Ensuring gluetun-dependent containers are in sync ---"
docker compose up -d gluetun qbittorrent prowlarr >> "$LOGFILE" 2>&1

# 6. Clean up old unused images, but leave anything from today alone so
#    a same-day rollback (docker compose down && re-pull old tag) is
#    still possible if an update turns out to be bad.
log "--- Pruning images older than 24h ---"
docker image prune -f --filter "until=24h" >> "$LOGFILE" 2>&1

log "=== Maintenance run complete: $(date +%Y%m%d-%H%M%S) ==="
log ""

# Reminder: check if a reboot is needed (e.g. after a kernel update)
if [ -f /var/run/reboot-required ]; then
    log "!!! REBOOT REQUIRED !!! See $LOGFILE for details."
fi
