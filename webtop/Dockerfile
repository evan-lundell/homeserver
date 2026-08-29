# Thin remote desktop: linuxserver/webtop streams a full XFCE desktop into
# the browser via KasmVNC. This layers on everything the base image doesn't
# ship, using the exact recipe worked out by hand (see README.md's Webtop
# notes for the full story of why each piece is needed):
#   - Firefox, from Mozilla's own apt repo — Ubuntu's own `firefox` package
#     is a snap-store stub that doesn't work in a container.
#   - Discord's official .deb.
#   - intel-media-va-driver-non-free in place of the default
#     intel-media-va-driver — the default is missing the VideoProc VA-API
#     entrypoint the desktop stream's GPU-scaling step needs, so VAAPI
#     hardware encoding silently falls back to (much slower) CPU encoding
#     without it.
# Baked in here (rather than installed by hand in the running container)
# specifically so none of this gets wiped if scripts/maintenance.sh's
# nightly `docker compose pull` ever picks up a new upstream webtop image
# and recreates the container — a locally built image isn't affected by
# that pull, so this only changes when you rebuild it on purpose.
FROM lscr.io/linuxserver/webtop:ubuntu-xfce

RUN apt-get update && \
    apt-get install -y --no-install-recommends wget ca-certificates gnupg && \
    install -d -m 0755 /etc/apt/keyrings && \
    wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- | tee /etc/apt/keyrings/packages.mozilla.org.asc > /dev/null && \
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" | tee /etc/apt/sources.list.d/mozilla.list > /dev/null && \
    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' | tee /etc/apt/preferences.d/mozilla > /dev/null && \
    apt-get update && \
    apt-get install -y --no-install-recommends firefox intel-media-va-driver-non-free && \
    wget -O /tmp/discord.deb "https://discord.com/api/download?platform=linux&format=deb" && \
    apt-get install -y --no-install-recommends /tmp/discord.deb && \
    rm -rf /tmp/discord.deb /var/lib/apt/lists/* && \
    # Discord's Chromium sandbox needs a root-owned setuid helper that isn't
    # set up here (this container deliberately skips seccomp:unconfined —
    # see the Webtop notes in README.md) — launch with --no-sandbox instead.
    sed -i 's|^Exec=/usr/bin/discord|Exec=/usr/bin/discord --no-sandbox|' \
        /usr/share/applications/discord.desktop /usr/share/discord/discord.desktop
