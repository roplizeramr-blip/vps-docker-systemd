# syntax=docker/dockerfile:1.7
#
# Full-system cloud desktop: REAL systemd is PID 1 inside the container.
#
# This is the difference from the Supervisor-based image:
#   * no supervisord, no shim `systemctl`, no fake journald
#   * /lib/systemd/systemd is PID 1
#   * vnc / websockify / xfce / nginx / control are real systemd units
#     (the same unit files used on a real VPS, see vps/systemd/)
#   * `systemctl status`, `journalctl -u vnc -f` and `systemd-analyze` work
#
# Build:  docker build -t vps-docker-systemd .
# Run:    docker run -d -p 3000:3000 --privileged \
#             -e VNC_PW='...' vps-docker-systemd
#
FROM debian:13

ARG DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Africa/Cairo \
    container=docker \
    VNC_USER=admin \
    VNC_AUTH=1 \
    VNC_RESOLUTION=1280x720 \
    VNC_DISPLAY=1 \
    VNC_PORT=5901 \
    WS_PORT=6080 \
    CONTROL_PORT=3001 \
    PORT=3000 \
    PUBLIC_DESKTOP=1 \
    CHROME_AUTOSTART=1 \
    SWAP_ENABLED=0 \
    DESKTOP_HOSTNAME=docker-desktop \
    SYSTEMD_IGNORE_CHROOT=1 \
    SYSTEMD_LOG_TARGET=console \
    SYSTEMD_LOG_LEVEL=info

# ----------------------------------------------------------------- packages
RUN apt-get update && apt-get -y upgrade && \
    apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus dbus-x11 gnome-keyring \
        python3 python3-dbus python3-gi gir1.2-glib-2.0 \
        ssl-cert earlyoom openssl procps psmisc iproute2 \
        ca-certificates curl wget gnupg xz-utils libatomic1 \
        locales tzdata sudo passwd hostname less nano \
        tigervnc-standalone-server tigervnc-common novnc websockify nginx-light \
        xfwm4 xfce4-panel xfce4-settings xfconf xfce4-terminal \
        xfce4-screenshooter xfce4-taskmanager xfce4-appfinder \
        thunar mousepad ristretto \
        x11-utils x11-xserver-utils x11-xkb-utils xauth xdg-utils desktop-file-utils \
        xfonts-base xfonts-utils adwaita-icon-theme \
        fonts-dejavu-core fonts-noto-core fonts-noto-color-emoji fonts-liberation \
        librsvg2-common librsvg2-bin feh \
    && rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------- Google Chrome
RUN install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub -o /etc/apt/keyrings/google-chrome.asc && \
    chmod 0644 /etc/apt/keyrings/google-chrome.asc && \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.asc] https://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && apt-get install -y --no-install-recommends google-chrome-stable && \
    rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------- locale
RUN sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen

# ----------------------------------------------------------------- desktop user
RUN groupadd -g 1000 desktop 2>/dev/null || true && \
    useradd -m -u 1000 -g desktop -s /bin/bash -G sudo desktop && \
    install -d -m 0755 -o desktop -g desktop \
        /home/desktop/Desktop /home/desktop/.config /home/desktop/.cache && \
    install -d -m 0700 -o desktop -g desktop /home/desktop/.vnc && \
    echo "desktop ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/desktop-nopasswd && \
    chmod 0440 /etc/sudoers.d/desktop-nopasswd

# ----------------------------------------------------------------- application files
WORKDIR /opt/desktop
COPY scripts /opt/desktop-src/scripts
COPY web     /opt/desktop-src/web
COPY desktop /opt/desktop-src/desktop
COPY tests   /opt/desktop-src/tests
COPY vps     /opt/desktop-src/vps

RUN install -d -m 0755 /opt/desktop/web /opt/desktop/applications /opt/desktop/tests \
        /usr/share/backgrounds /etc/cloud-desktop && \
    install -m 0755 /opt/desktop-src/scripts/*.sh /usr/local/bin/ && \
    install -m 0755 /opt/desktop-src/scripts/control-server.py /usr/local/bin/control-server.py && \
    install -m 0644 /opt/desktop-src/web/*.html /opt/desktop/web/ && \
    install -m 0644 /opt/desktop-src/tests/*.sh /opt/desktop/tests/ && \
    install -m 0644 /opt/desktop-src/desktop/wallpaper.svg /usr/share/backgrounds/debian-cloud.svg && \
    rsvg-convert -w 1920 -h 1080 /usr/share/backgrounds/debian-cloud.svg \
        -o /usr/share/backgrounds/desktop.png && \
    install -m 0644 /opt/desktop-src/desktop/applications/*.desktop /opt/desktop/applications/ && \
    cp /opt/desktop/applications/*.desktop /home/desktop/Desktop/ && \
    chmod 0755 /home/desktop/Desktop/*.desktop && \
    chown -R desktop:desktop /home/desktop && \
    ln -sfn /usr/local/bin/google-chrome-wrapper.sh /usr/local/bin/google-chrome && \
    ln -sfn /usr/local/bin/google-chrome-wrapper.sh /usr/local/bin/google-chrome-stable

# ----------------------------------------------------------------- real systemd units
RUN install -m 0644 /opt/desktop-src/vps/systemd/*.service \
                 /opt/desktop-src/vps/systemd/*.target /etc/systemd/system/ && \
    install -m 0644 /opt/desktop-src/scripts/nginx.conf.template \
                 /usr/local/bin/nginx.conf.template && \
    # Docker-specific drop-ins: skip the PAM/login session layer (it needs a
    # healthy logind + session bus, which containers often lack).  systemd
    # still drops privileges through User=/Group= in the unit itself.
    for svc in vnc websockify xfce; do \
        install -d -m 0755 "/etc/systemd/system/${svc}.service.d"; \
    done && \
    install -m 0644 /opt/desktop-src/vps/systemd/vnc.service.docker \
        /etc/systemd/system/vnc.service.d/override.conf && \
    install -m 0644 /opt/desktop-src/vps/systemd/websockify.service.docker \
        /etc/systemd/system/websockify.service.d/override.conf && \
    install -m 0644 /opt/desktop-src/vps/systemd/xfce.service.docker \
        /etc/systemd/system/xfce.service.d/override.conf

# Enable cloud-desktop.target for the default boot target and make
# multi-user.target the default.  Done with symlinks (not `systemctl enable`)
# because `systemctl enable` is not reliable inside a build-time container.
RUN mkdir -p /etc/systemd/system/multi-user.target.wants && \
    ln -sfn /etc/systemd/system/cloud-desktop.target \
            /etc/systemd/system/multi-user.target.wants/cloud-desktop.target && \
    ln -sfn /etc/systemd/system/diag.service \
            /etc/systemd/system/multi-user.target.wants/diag.service && \
    ln -sfn /lib/systemd/system/multi-user.target /etc/systemd/system/default.target && \
    mkdir -p /etc/systemd/system/sysinit.target.wants && \
    ln -sfn /lib/systemd/system/dbus.service /etc/systemd/system/sysinit.target.wants/dbus.service

# Mask the units that need host privileges or a real console; they would only
# spam the journal in a container.
RUN for u in systemd-remount-fs.service \
            systemd-tmpfiles-setup-dev.service \
            systemd-tmpfiles-clean.service \
            systemd-sysusers.service \
            systemd-firstboot.service \
            systemd-update-utmp.service \
            getty@tty1.service \
            serial-getty@ttyS0.service; do \
        ln -sfn /dev/null "/etc/systemd/system/${u}"; \
    done

# A lingering user manager gives the desktop user a /run/user/1000 and a
# session bus.  `loginctl enable-linger` needs a running logind, so the
# marker file is created directly (this is exactly what it writes).
RUN install -d -m 0755 /var/lib/systemd/linger && \
    touch /var/lib/systemd/linger/desktop && \
    install -d -m 0700 -o desktop -g desktop /run/user/1000

# A fixed machine-id keeps the journal and the users consistent across restarts.
RUN dbus-uuidgen --ensure 2>/dev/null || \
    (tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id)

# ----------------------------------------------------------------- entrypoint
COPY scripts/entrypoint-docker.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

STOPSIGNAL SIGRTMIN+3
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${PORT}/healthz" || exit 1

CMD ["/entrypoint.sh"]
