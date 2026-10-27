#!/bin/bash
# Container entrypoint: runs real systemd as PID 1 (not Supervisor).
#
# Unlike the Supervisor-based container this image deliberately does NOT run
# a process manager as PID 1: /lib/systemd/systemd is PID 1, the real unit
# files in /etc/systemd/system/ drive the desktop stack, and the five
# services (vnc, websockify, xfce, nginx, control) + earlyoom behave exactly
# as they would on a real VPS.
#
# This script only prepares runtime state (env file, nginx config, runtime
# dirs, passwords, machine-id) and then hands PID 1 to systemd with:
#   exec /lib/systemd/systemd --system --default-standard-output=journal+console
#
# --default-standard-output=journal+console   sends unit stdout/stderr to BOTH
# the journal (visible via `journalctl`) and the container console (visible via
# CranL app logs), so systemd boot messages and `systemctl status` output are
# observable without attaching a journal reader.
set -Eeuo pipefail

# ------------------------------------------------------------------ env
export VNC_PW="${VNC_PW:-}"
export VNC_USER="${VNC_USER:-admin}"
export VNC_AUTH="${VNC_AUTH:-1}"
export VNC_RESOLUTION="${VNC_RESOLUTION:-1280x720}"
export VNC_DISPLAY="${VNC_DISPLAY:-1}"
export VNC_PORT="${VNC_PORT:-5901}"
export WS_PORT="${WS_PORT:-6080}"
export PORT="${PORT:-3000}"
export CONTROL_PORT="${CONTROL_PORT:-3001}"
export DESKTOP_PW="${DESKTOP_PW:-}"
export ROOT_PW="${ROOT_PW:-}"
export DESKTOP_HOSTNAME="${DESKTOP_HOSTNAME:-docker-desktop}"
export TZ="${TZ:-Africa/Cairo}"
export PUBLIC_DESKTOP="${PUBLIC_DESKTOP:-1}"
export HOME="/home/desktop"
export USER="desktop"
export LOGNAME="desktop"

# systemd needs these set so it knows it is running in a container.
export container="${container:-docker}"
export SYSTEMD_LOG_TARGET="${SYSTEMD_LOG_TARGET:-console}"
export SYSTEMD_LOG_LEVEL="${SYSTEMD_LOG_LEVEL:-info}"
export SYSTEMD_IGNORE_CHROOT=1

# ------------------------------------------------------------------ locale
if ! locale -a 2>/dev/null | grep -qi '^en_us\.utf8$'; then
    export LANG="${LANG:-C.UTF-8}" LANGUAGE="${LANGUAGE:-C.UTF-8}" LC_ALL="${LC_ALL:-C.UTF-8}"
else
    export LANG="${LANG:-en_US.UTF-8}"
    export LANGUAGE="${LANGUAGE:-en_US:en}"
    export LC_ALL="${LC_ALL:-en_US.UTF-8}"
fi
if [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    printf '%s\n' "$TZ" > /etc/timezone
fi

log() { printf '[entrypoint] %s\n' "$*"; }

# ------------------------------------------------------------------ checks
if [ -z "$VNC_PW" ]; then
    log "ERROR: VNC_PW must be set in the deployment environment"; exit 1
fi
if [[ "$VNC_PW" == *$'\n'* ]]; then
    log "ERROR: VNC_PW must not contain a newline"; exit 1
fi
if [ "${#VNC_PW}" -lt 6 ]; then
    log "ERROR: VNC_PW must be at least 6 characters"; exit 1
fi
case "$VNC_USER" in
    ''|*[!A-Za-z0-9_.-]*) log "ERROR: VNC_USER has invalid characters"; exit 1 ;;
esac

# ------------------------------------------------------------------ runtime dirs
install -d -m 1777 /tmp/.X11-unix
rm -f "/tmp/.X${VNC_DISPLAY}-lock" "/tmp/.X11-unix/X${VNC_DISPLAY}"
install -d -m 0755 /var/log/nginx /run/nginx /run/dbus /var/lib/dbus /run/user/1000
install -d -m 0700 -o desktop -g desktop /run/user/1000
install -d -m 0700 -o desktop -g desktop /home/desktop/.vnc /home/desktop/.config /home/desktop/.cache /home/desktop/Desktop

# A stable machine-id keeps apps that read it happy and consistent across restarts.
if [ ! -s /etc/machine-id ]; then
    if [ -r /proc/sys/kernel/random/uuid ]; then
        tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id 2>/dev/null || true
    fi
fi
if [ -n "${DESKTOP_HOSTNAME:-}" ]; then
    hostname "$DESKTOP_HOSTNAME" 2>/dev/null || true
    printf '%s\n' "$DESKTOP_HOSTNAME" > /etc/hostname 2>/dev/null || true
fi

# Best-effort kernel tuning (may be read-only in the container).
for setting in vm.swappiness=10 vm.dirty_ratio=5 fs.inotify.max_user_watches=524288; do
    sysctl -w "$setting" >/dev/null 2>&1 || true
done

log "TigerVNC ${VNC_RESOLUTION} on 127.0.0.1:${VNC_PORT} (display :${VNC_DISPLAY})"
log "noVNC/websockify 127.0.0.1:${WS_PORT}; nginx public :${PORT}"
log "control API 127.0.0.1:${CONTROL_PORT}"
log "hands off to systemd (PID 1)"

# ------------------------------------------------------------------ env file (read by the systemd units)
# NOTE: VNC_PW is intentionally NOT written here; nginx Basic-Auth is derived
#       from it below and the desktop socket is loopback-only.
cat > /etc/cloud-desktop/desktop.env <<EOF
VNC_USER=${VNC_USER}
VNC_AUTH=${VNC_AUTH}
VNC_RESOLUTION=${VNC_RESOLUTION}
VNC_PORT=${VNC_PORT}
VNC_DISPLAY=${VNC_DISPLAY}
WS_PORT=${WS_PORT}
CONTROL_PORT=${CONTROL_PORT}
PORT=${PORT}
PUBLIC_DESKTOP=${PUBLIC_DESKTOP}
DESKTOP_HOSTNAME=${DESKTOP_HOSTNAME}
EOF
chown root:desktop /etc/cloud-desktop/desktop.env
chmod 0640 /etc/cloud-desktop/desktop.env

# ------------------------------------------------------------------ nginx Basic Auth + rendered config
HASH="$(openssl passwd -apr1 "$VNC_PW")"
printf '%s:%s\n' "$VNC_USER" "$HASH" > /etc/nginx/.htpasswd
chown root:www-data /etc/nginx/.htpasswd 2>/dev/null || true
chmod 0640 /etc/nginx/.htpasswd

sed -e "s/__PORT__/${PORT}/g" \
    -e "s/__WS_PORT__/${WS_PORT}/g" \
    -e "s/__CONTROL_PORT__/${CONTROL_PORT}/g" \
    /usr/local/bin/nginx.conf.template > /etc/nginx/nginx.conf
/usr/sbin/nginx -t -c /etc/nginx/nginx.conf

# ------------------------------------------------------------------ optional Linux passwords (never committed)
if [ -n "$DESKTOP_PW" ]; then
    printf 'desktop:%s\n' "$DESKTOP_PW" | chpasswd 2>/dev/null && log "DESKTOP_PW applied"
fi
if [ -n "$ROOT_PW" ]; then
    printf 'root:%s\n' "$ROOT_PW" | chpasswd 2>/dev/null && log "ROOT_PW applied"
fi
if [ -n "${SWAP_ENABLED:-0}" ]; then
    /usr/local/bin/setup-swap.sh >/var/log/swap.log 2>&1 &
fi
if [ "${HIDE_CONTAINER:-0}" = "1" ]; then
    rm -f /.dockerenv
fi

# ------------------------------------------------------------------ hand PID 1 to systemd
# Default target (multi-user.target) pulls cloud-desktop.target, which brings
# up vnc, websockify, xfce, nginx and control as real systemd units.
exec /lib/systemd/systemd --system \
    --default-standard-output=journal+console \
    --default-standard-error=journal+console
