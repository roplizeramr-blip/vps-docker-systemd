# vps-docker-systemd

A cloud desktop that runs **real systemd as PID 1 inside a Docker container**.

This is the experiment that answers the question the Supervisor-based images
could not: *does the full `vps/` unit stack behave the same way when systemd
is the real init?*

| | `debian-systemd-desktop` (Supervisor) | **this repo (systemd PID 1)** |
|---|---|---|
| PID 1 | `supervisord` | `/lib/systemd/systemd` |
| `systemctl status` | shim script (fake) | real systemd |
| `journalctl -u vnc -f` | Python fake journald | real journald |
| Units | supervisor programs | `vnc.service`, `websockify.service`, `xfce.service`, `control.service` + distro `nginx.service` |
| OOM guard | `earlyoom` (supervisor program) | `earlyoom.service` (distro unit) |
| `vps/` unit files | copied verbatim, unused | **the units that actually run** |

The desktop stack itself is unchanged and already verified:

* **TigerVNC** (`Xtigervnc`) — one process, owns the framebuffer, RFB on
  `127.0.0.1:5901` only, `-noreset` so a browser refresh never kills the
  session.
* **websockify** — bridges RFB to WebSocket *and* serves the noVNC bundle.
* **nginx** — the only public listener. Terminates HTTP Basic Auth and
  upgrades the WebSocket natively (`proxy_http_version 1.1` +
  `Upgrade`/`Connection`), so there is **no Python socket pump** in the path.
  That is what used to cause the frequent disconnects.
* **noVNC** — opened with `autoconnect=1&resize=remote&reconnect=1`.
* **XFCE** — lean: `xfwm4` + `xfsettingsd` + `xfce4-panel`, wallpaper painted
  once by `feh` (no `xfdesktop`, no `xfce4-session`).
* **control-server.py** — answers `/healthz`, `/api/status` and `/status` on
  `127.0.0.1:3001`. It never proxies WebSocket traffic.

---

## Layout

```
Dockerfile                 image: Debian 13 + systemd as PID 1
scripts/entrypoint-docker.sh   prepares runtime state, then execs systemd
scripts/nginx.conf.template    nginx config (rendered at boot)
scripts/control-server.py      /healthz, /api/status, /status
scripts/start-*.sh             the programs the systemd units call
vps/systemd/*.service|.target  the REAL unit files
vps/systemd/*.service.docker   Docker-only drop-in overrides
vps/install.sh                 same stack, installed on a clean Debian 13 VPS
web/                           noVNC landing page + status page
desktop/                       wallpaper + .desktop launchers
```

`vps/systemd/` is byte-identical to the VPS unit files: the **same** unit
files are used on a real VPS and inside the container. The only difference is
the `*.service.docker` drop-ins, which clear `PAMName=login` because PAM
sessions need a healthy `systemd-logind` + session bus, which containers often
do not have. `User=desktop` still applies, so privileges are still dropped.

---

## Run it

### Docker (local)

```bash
docker build -t vps-docker-systemd .
docker run -d --name cloud-desktop \
    --privileged \
    -p 3000:3000 \
    -e VNC_PW='a-strong-password' \
    -e DESKTOP_PW='a-strong-password' \
    vps-docker-systemd
```

`--privileged` (or at least `--cap-add SYS_ADMIN` plus a writable
`/sys/fs/cgroup`) is required: systemd needs to set up the cgroup hierarchy
before it can start any unit.

### Inside the running container

```bash
docker exec -it cloud-desktop systemctl status cloud-desktop.target
docker exec -it cloud-desktop journalctl -u vnc -u websockify -u xfce -f
docker exec -it cloud-desktop systemd-analyze blame
```

### On a real VPS (no container)

```bash
git clone https://github.com/roplizeramr-blip/vps-docker-systemd.git
cd vps-docker-systemd
VNC_PW='a-strong-password' ./vps/install.sh
```

Same units, same scripts, no Docker involved.

---

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `VNC_PW` | *(required)* | HTTP Basic-Auth password (min 6 chars) |
| `DESKTOP_PW` | – | password of the Linux `desktop` user |
| `ROOT_PW` | – | root password |
| `VNC_USER` | `admin` | Basic-Auth user name |
| `VNC_RESOLUTION` | `1280x720` | desktop geometry |
| `PORT` | `3000` | public port |
| `CONTROL_PORT` | `3001` | internal control API |
| `WS_PORT` | `6080` | internal WebSocket bridge |
| `VNC_PORT` | `5901` | internal RFB port |
| `DESKTOP_HOSTNAME` | `docker-desktop` | hostname inside the desktop |

**Never commit `.env` or any password.** The `.env` file is git-ignored and
the image never bakes a password in: `VNC_PW` is turned into an nginx
apr1 hash at boot time and then discarded.

---

## URLs

| Path | What |
|---|---|
| `/` | the desktop (noVNC, Basic Auth) |
| `/status` | status page (no password) |
| `/api/status` | JSON status (no password) |
| `/healthz` | `200 ok` when the desktop is reachable, `503` while starting |
