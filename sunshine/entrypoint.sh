#!/bin/bash
set -e

export HOME=/home/lizard
export DISPLAY=:1

# Clear any stale lock/socket left behind by a `docker restart` (the
# container filesystem, including /tmp, survives a restart unlike a full
# recreate), which otherwise makes this X server fail to bind :1 silently.
rm -f /tmp/.X11-unix/X1 /tmp/.X1-lock

Xorg "$DISPLAY" -noreset -novtswitch -sharevts \
    -config /etc/X11/xorg-dummy.conf -logfile "$HOME/xorg.log" &
for i in $(seq 1 20); do
    [ -e /tmp/.X11-unix/X1 ] && break
    sleep 0.5
done

pulseaudio --start --exit-idle-time=-1
sleep 1
pactl load-module module-null-sink sink_name=sunshine_sink sink_properties=device.description=SunshineSink >/dev/null 2>&1 || true
pactl set-default-sink sunshine_sink >/dev/null 2>&1 || true

openbox &

# Make sure Sunshine captures the Xvfb X11 display rather than trying KMS —
# there's no real monitor on this headless host, so KMS capture finds nothing.
mkdir -p "$HOME/.config/sunshine"
CONF="$HOME/.config/sunshine/sunshine.conf"
touch "$CONF"
grep -q '^capture' "$CONF" || echo 'capture = x11' >> "$CONF"
# This host's Intel HD 530 VAAPI HEVC encoder fails on real frames
# ("Failed to end picture encode issue: 24") — force H.264 only.
grep -q '^hevc_mode' "$CONF" || echo 'hevc_mode = 1' >> "$CONF"
if [ -n "$SERVER_LAN_IP" ]; then
    grep -q '^csrf_allowed_origins' "$CONF" \
        || echo "csrf_allowed_origins = https://${SERVER_LAN_IP}:47990,http://sunshine.evan" >> "$CONF"
fi

exec sunshine
