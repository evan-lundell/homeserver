#!/bin/bash
#
# Reports filesystem usage to an Uptime Kuma push monitor: "up" while every
# filesystem below is under the threshold, "down" (with which one) otherwise.
# Intended to run via cron every 30 minutes, against a push monitor with a
# 60-minute heartbeat interval, so a stopped cron job also shows as down.

REPO=~/homeserver
THRESHOLD=90
FILESYSTEMS=(/ /mnt/media)

PUSH_URL=$(grep -E '^UPTIME_KUMA_PUSH_DISK=' "$REPO/.env" 2>/dev/null | cut -d= -f2-)
[ -z "$PUSH_URL" ] || [ "$PUSH_URL" = "changeme" ] && exit 0

status=up
msg=""
for fs in "${FILESYSTEMS[@]}"; do
    pct=$(df --output=pcent "$fs" 2>/dev/null | tail -1 | tr -dc '0-9')
    if [ -z "$pct" ]; then
        status=down
        msg+="$fs unreadable; "
        continue
    fi
    [ "$pct" -ge "$THRESHOLD" ] && status=down
    msg+="$fs ${pct}%; "
done

curl -fsS -m 10 -o /dev/null --get \
    --data-urlencode "status=$status" \
    --data-urlencode "msg=${msg%; }" \
    "$PUSH_URL"
