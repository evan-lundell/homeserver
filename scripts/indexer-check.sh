#!/bin/bash
#
# Recovers indexers that Prowlarr (and Sonarr/Radarr) have disabled after
# repeated failures, then reports to an Uptime Kuma push monitor. Two failure
# modes recur with Cloudflare-fronted public indexers like 1337x:
#  - a stale Cloudflare challenge: re-testing the indexer (what the "Test"
#    button does) re-runs FlareSolverr and fixes it;
#  - Cloudflare banning the VPN exit IP (error code 1006/1015/1020): no amount
#    of re-testing helps, so the VPN is reconnected to a new random server
#    through gluetun's control server. That keeps gluetun's network namespace,
#    so the containers behind it don't need restarting.
# Intended to run via cron every 30 minutes, against a push monitor with a
# 60-minute heartbeat interval, so a stopped cron job also shows as down.

REPO=~/homeserver
STATE_DIR=~/homeserver-maintenance
LOGFILE="$STATE_DIR/indexer-check.log"
ROTATE_STAMP="$STATE_DIR/indexer-check.last-rotate"
ROTATE_COOLDOWN=$((6 * 3600))
MAX_ROTATIONS=3
BAN_CODES='error code: (1006|1015|1020)'

mkdir -p "$STATE_DIR"

log() {
    echo "$(date '+%F %T') $1" >> "$LOGFILE"
}

PUSH_URL=$(grep -E '^UPTIME_KUMA_PUSH_INDEXERS=' "$REPO/.env" 2>/dev/null | cut -d= -f2-)
[ "$PUSH_URL" = "changeme" ] && PUSH_URL=""

push() {
    [ -z "$PUSH_URL" ] && return
    curl -fsS -m 10 -o /dev/null --get \
        --data-urlencode "status=$1" \
        --data-urlencode "msg=$2" \
        "$PUSH_URL"
}

api_key() {
    docker exec "$1" cat /config/config.xml 2>/dev/null | grep -oP '(?<=<ApiKey>)[^<]+'
}

# api CONTAINER PORT KEY METHOD PATH [BODY_FILE]: calls an *arr API from inside
# its own container, so no ports or hostnames need to be known here. Prints the
# response body; fails on a non-2xx response.
api() {
    if [ -n "$6" ]; then
        docker exec -i "$1" curl -fsS -m 120 -X "$4" -H "X-Api-Key: $3" \
            -H 'Content-Type: application/json' --data-binary @- "http://localhost:$2$5" < "$6"
    else
        docker exec "$1" curl -fsS -m 120 -X "$4" -H "X-Api-Key: $3" "http://localhost:$2$5"
    fi
}

# gluetun CONTROL_PATH [PUT_BODY]
gluetun() {
    if [ -n "$2" ]; then
        docker exec gluetun wget -qO- -T 30 --method=PUT --header="X-API-Key: $GLUETUN_KEY" \
            --header='Content-Type: application/json' --body-data="$2" "http://127.0.0.1:8000$1"
    else
        docker exec gluetun wget -qO- -T 30 --header="X-API-Key: $GLUETUN_KEY" "http://127.0.0.1:8000$1"
    fi
}

public_ip() {
    gluetun /v1/publicip/ip | python3 -c 'import json,sys; print(json.load(sys.stdin).get("public_ip",""))' 2>/dev/null
}

is_banned() {
    docker exec prowlarr curl -s -m 20 -A 'Mozilla/5.0' "$1" | grep -qE "$BAN_CODES"
}

# Prints "id<TAB>name<TAB>url" for every Prowlarr indexer currently disabled.
disabled_indexers() {
    local status indexers
    status=$(api prowlarr 9696 "$PK" GET /api/v1/indexerstatus) || return 1
    indexers=$(api prowlarr 9696 "$PK" GET /api/v1/indexer) || return 1
    python3 -c '
import json, sys
from datetime import datetime, timezone
now = datetime.now(timezone.utc)
disabled = {s["indexerId"] for s in json.loads(sys.argv[1])
            if s.get("disabledTill") and datetime.fromisoformat(s["disabledTill"].replace("Z", "+00:00")) > now}
for i in json.loads(sys.argv[2]):
    if i["id"] in disabled and i["enable"]:
        url = next((f.get("value") for f in i["fields"] if f["name"] == "baseUrl"), None) or i["indexerUrls"][0]
        print(i["id"], i["name"], url, sep="\t")
' "$status" "$indexers"
}

# Reconnects the VPN until $1 stops serving a ban page, at most MAX_ROTATIONS
# times and only once per ROTATE_COOLDOWN, since every reconnect briefly
# interrupts qBittorrent.
rotate_vpn() {
    local url=$1 last old new attempt
    last=$(cat "$ROTATE_STAMP" 2>/dev/null || echo 0)
    if [ $(( $(date +%s) - last )) -lt "$ROTATE_COOLDOWN" ]; then
        log "VPN IP banned but last rotation was under $((ROTATE_COOLDOWN / 3600))h ago; skipping"
        return 1
    fi
    if [ -z "$GLUETUN_KEY" ]; then
        log "VPN IP banned but gluetun/auth/config.toml has no indexer-check role"
        return 1
    fi
    date +%s > "$ROTATE_STAMP"
    for attempt in $(seq 1 "$MAX_ROTATIONS"); do
        old=$(public_ip)
        gluetun /v1/vpn/status '{"status":"stopped"}' > /dev/null
        gluetun /v1/vpn/status '{"status":"running"}' > /dev/null
        new=""
        for _ in $(seq 1 12); do
            sleep 5
            new=$(public_ip)
            [ -n "$new" ] && [ "$new" != "$old" ] && break
        done
        log "VPN rotation $attempt: ${old:-?} -> ${new:-?}"
        sleep 10
        is_banned "$url" || return 0
    done
    return 1
}

# Re-tests every Sonarr/Radarr indexer named in an "Indexers unavailable due to
# failures" health warning. They keep their own backoff (up to 24h), separate
# from Prowlarr's, so they'd stay disabled long after Prowlarr recovers.
retest_arr() {
    local container=$1 port=$2 key health indexers ids id
    key=$(api_key "$container") || return
    health=$(api "$container" "$port" "$key" GET /api/v3/health) || return
    indexers=$(api "$container" "$port" "$key" GET /api/v3/indexer) || return
    ids=$(python3 -c '
import json, sys
names = set()
for h in json.loads(sys.argv[1]):
    if h["source"] in ("IndexerStatusCheck", "IndexerLongTermStatusCheck"):
        names.update(n.strip() for n in h["message"].split(":", 1)[1].split(","))
for i in json.loads(sys.argv[2]):
    if i["name"] in names:
        print(i["id"])
' "$health" "$indexers")
    for id in $ids; do
        if api "$container" "$port" "$key" GET "/api/v3/indexer/$id" \
            | api "$container" "$port" "$key" POST /api/v3/indexer/test /dev/stdin > /dev/null; then
            log "$container: re-tested indexer $id, OK"
        else
            log "$container: re-tested indexer $id, still failing"
        fi
    done
    if [ -n "$ids" ]; then
        echo '{"name":"CheckHealth"}' | api "$container" "$port" "$key" POST /api/v3/command /dev/stdin > /dev/null
    fi
}

# If Prowlarr itself is unreachable (e.g. mid-recreate during the nightly
# maintenance run), skip the push rather than pushing "down": the monitor's
# heartbeat interval still catches it if that lasts.
PK=$(api_key prowlarr)
if [ -z "$PK" ]; then
    log "can't read Prowlarr API key; skipping"
    exit 1
fi
GLUETUN_KEY=$(python3 -c '
import sys, tomllib
roles = tomllib.load(open(sys.argv[1], "rb")).get("roles", [])
print(next((r["apikey"] for r in roles if r["name"] == "indexer-check"), ""))
' "$REPO/gluetun/auth/config.toml" 2>/dev/null)

if ! disabled=$(disabled_indexers); then
    log "can't query Prowlarr; skipping"
    exit 1
fi

banned=""
ban_url=""
while IFS=$'\t' read -r id name url; do
    [ -z "$id" ] && continue
    if is_banned "$url"; then
        log "$name: Cloudflare ban page from $url"
        banned+="$name "
        [ -z "$ban_url" ] && ban_url=$url
    fi
done <<< "$disabled"

if [ -n "$ban_url" ] && rotate_vpn "$ban_url"; then
    banned=""
fi

while IFS=$'\t' read -r id name url; do
    [ -z "$id" ] && continue
    if api prowlarr 9696 "$PK" GET "/api/v1/indexer/$id" \
        | api prowlarr 9696 "$PK" POST /api/v1/indexer/test /dev/stdin > /dev/null; then
        log "$name: re-tested in Prowlarr, OK"
    else
        log "$name: re-tested in Prowlarr, still failing"
    fi
done <<< "$disabled"

retest_arr sonarr 8989
retest_arr radarr 7878

still=$(disabled_indexers | cut -f2 | paste -sd, -)
if [ -n "$banned" ]; then
    push down "VPN exit IP banned by: ${banned% } (auto-rotation didn't help or is on cooldown)"
elif [ -n "$still" ]; then
    push down "still disabled in Prowlarr: $still"
else
    push up "OK"
fi
