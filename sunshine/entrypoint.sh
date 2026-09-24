#!/bin/bash
set -e

export HOME=/home/lizard
export DISPLAY=:1

# Clear any stale lock/socket left behind by a `docker restart` (the
# container filesystem, including /tmp, survives a restart unlike a full
# recreate), which otherwise makes this X server fail to bind :1 silently.
rm -f /tmp/.X11-unix/X1 /tmp/.X1-lock

Xorg "$DISPLAY" -noreset -novtswitch -sharevts \
    -config /etc/X11/xorg.conf -logfile "$HOME/xorg.log" &
for i in $(seq 1 20); do
    [ -e /tmp/.X11-unix/X1 ] && break
    sleep 0.5
done

# Same /tmp-survives-restart trap as the X lock: a killed PulseAudio leaves
# its pid file behind, and `pulseaudio --start` then sees that (reused) pid
# as alive and silently starts nothing. Result: no stream audio, and Azahar
# segfaults enumerating audio devices (cubeb) against the dead server.
rm -rf /tmp/pulse-* "$HOME"/.config/pulse/*-runtime

pulseaudio --start --exit-idle-time=-1
for i in $(seq 1 20); do
    pactl info >/dev/null 2>&1 && break
    sleep 0.5
done
pactl load-module module-null-sink sink_name=sunshine_sink sink_properties=device.description=SunshineSink >/dev/null 2>&1 || true
pactl set-default-sink sunshine_sink >/dev/null 2>&1 || true

openbox &

# Make sure Sunshine captures this X11 session rather than trying KMS
# directly.
mkdir -p "$HOME/.config/sunshine"
CONF="$HOME/.config/sunshine/sunshine.conf"
touch "$CONF"
grep -q '^capture' "$CONF" || echo 'capture = x11' >> "$CONF"
# This host's Intel HD 530 VAAPI HEVC encoder fails on real frames
# ("Failed to end picture encode issue: 24") — force H.264 only.
grep -q '^hevc_mode' "$CONF" || echo 'hevc_mode = 1' >> "$CONF"
if [ -n "$SERVER_LAN_IP" ]; then
    grep -q '^csrf_allowed_origins' "$CONF" \
        || echo "csrf_allowed_origins = https://${SERVER_LAN_IP}:47990,https://sunshine.evan" >> "$CONF"
fi

exec sunshine
