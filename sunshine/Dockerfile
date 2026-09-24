FROM ghcr.io/lizardbyte/sunshine:v2026.911.165624-debian-trixie

USER root

# Xorg + the modesetting driver: a real X server against a physical HDMI
# dummy plug (EDID emulator) on this otherwise-headless host, so it gets
# genuine hardware-accelerated OpenGL/Vulkan (needed for Azahar/3DS — the
# earlier "dummy" 2D-only video driver couldn't back Vulkan's presentation
# path at all, and only gave OpenGL software/CPU rendering, too slow for
# real gameplay). Deliberately NOT Xvfb — Xvfb has no input driver stack at
# all, so Sunshine's uinput-injected mouse/keyboard events (real kernel
# input devices) never reach it. A real Xorg session loads the libinput
# driver like a normal desktop would, so those devices actually get picked
# up.
# pulseaudio: virtual audio sink so emulator audio has somewhere to go.
# openbox: minimal window manager so the emulator window gets decorated/
# focused normally instead of floating undecorated on the root window.
# intel-media-va-driver-non-free: VAAPI driver for this host's Intel HD 530
# (Skylake) iGPU — the modern iHD driver, not the legacy i965 one.
# mesa-vulkan-drivers: without a registered Vulkan ICD, libvulkan.so.1 is
# still present (pulled in as a dependency of something else) but every
# Vulkan call finds zero drivers — Azahar segfaults on launch (NULL
# function pointer, confirmed via gdb/core dump) probing Vulkan
# availability in that state, well before any game/renderer is involved.
# Debian's default sources only enable the "main" component; the Intel
# VAAPI driver lives in non-free(-firmware), so enable those too.
RUN sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/' \
        /etc/apt/sources.list.d/debian.sources

RUN apt-get update && apt-get install -y --no-install-recommends \
        xserver-xorg-core \
        xserver-xorg-input-libinput \
        xserver-xorg-legacy \
        pulseaudio \
        openbox \
        intel-media-va-driver-non-free \
        mesa-vulkan-drivers \
        libgpg-error0 \
        curl \
        unzip \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Let Xorg run as a non-root user (no logind/systemd seat management in a
# container to grant this the normal way).
RUN echo 'allowed_users=anybody\nneeds_root_rights=no' > /etc/X11/Xwrapper.config

COPY xorg.conf /etc/X11/xorg.conf

# Match the host's evan (1000:1000), like every other service in this repo
# (PUID/PGID=1000). The base image's lizard user defaults to 1001:1001.
# This matters specifically for /mnt/media: it's a mergerfs union whose
# create()/mkdir() permission check only honors owner/group match, not
# "other" bits (confirmed bug, not a config issue — writes to existing
# files respect "other" fine, only *creating new files* doesn't), so a
# non-matching uid can never create new save files there no matter the mode.
RUN usermod -u 1000 lizard && groupmod -g 1000 lizard \
    && chown -R lizard:lizard /home/lizard

# melonDS (DS). Extract the AppImage at build time so no FUSE is needed at
# runtime inside the container.
RUN curl -fL -o /tmp/melonds.zip \
        https://github.com/melonDS-emu/melonDS/releases/download/1.1/melonDS-1.1-appimage-x86_64.zip \
    && unzip -j /tmp/melonds.zip -d /tmp/melonds \
    && chmod +x /tmp/melonds/melonDS*.AppImage \
    && cd /tmp/melonds && ./melonDS*.AppImage --appimage-extract \
    && mv squashfs-root /opt/melonDS \
    && cd / && rm -rf /tmp/melonds.zip /tmp/melonds

# Azahar (3DS) — the actively maintained Citra successor.
RUN curl -fL -o /tmp/azahar.AppImage \
        https://github.com/azahar-emu/azahar/releases/download/2126.1/azahar.AppImage \
    && chmod +x /tmp/azahar.AppImage \
    && cd /tmp && ./azahar.AppImage --appimage-extract \
    && mv squashfs-root /opt/azahar \
    && rm -f /tmp/azahar.AppImage

# mGBA (GBA, plus GB/GBC).
RUN curl -fL -o /tmp/mgba.AppImage \
        https://github.com/mgba-emu/mgba/releases/download/0.10.5/mGBA-0.10.5-appimage-x64.appimage \
    && chmod +x /tmp/mgba.AppImage \
    && cd /tmp && ./mgba.AppImage --appimage-extract \
    && mv squashfs-root /opt/mgba \
    && rm -f /tmp/mgba.AppImage

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && chown lizard:lizard /entrypoint.sh

ENV LIBVA_DRIVER_NAME=iHD
ENV DISPLAY=:1

USER lizard

ENTRYPOINT ["/entrypoint.sh"]
