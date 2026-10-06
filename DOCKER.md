# Running garmin-stats-ai in Docker

This document covers the Docker-based deployment of garmin-stats-ai on a host
that has Docker but **no Python installed**. It replaces the Raspberry-Pi /
systemd deployment described in `deploy/README.md`.

## Overview

The project has two Python apps. In Docker they run as **two containers built
from one shared image**, mirroring the original systemd layout:

| Container | Service | What it does | Command |
|-----------|---------|--------------|---------|
| `garmin-fetcher` | `fetcher` | Polls Garmin Connect on a loop, writes the SQLite DB | `python -m garmin_grafana.garmin_fetch` |
| `garmin-web` | `web` | FastAPI dashboard + Claude chat, reads the SQLite DB | `garmin-insights web` |

The fetcher **writes** the DB; the web app **reads** it. They share it through
a bind-mounted volume.

### Files (in the repo root)

| File | Purpose |
|------|---------|
| `Dockerfile` | Builds the shared `python:3.11-slim` image with both subprojects installed |
| `docker-compose.yml` | Defines the `fetcher` and `web` services, volumes, ports, restart policy |
| `.dockerignore` | Keeps the build context small; prevents baking secrets/data into the image |
| `.env` | Your secrets and config (you create this — **not committed**) |
| `DOCKER.md` | This document |

### Where data lives

| What | Host path | Container path |
|------|-----------|----------------|
| SQLite DB | `./data/garmin.db` (i.e. `/root/garmin-stats-ai/data/garmin.db`) | `/data/garmin.db` |
| Garmin OAuth tokens | `./tokens/` | `/tokens/` |

Both persist across container restarts and host reboots because they are bind
mounts on the host, not inside the container.

---

## 1. Configure `.env`

```bash
cd /root/garmin-stats-ai
cp .env.example .env
nano .env
```

**Required values** (the app is useless without these):

```bash
GARMINCONNECT_EMAIL=your@email.com      # fetcher login — must be set or the fetcher hangs
GARMINCONNECT_PASSWORD=your_password    # fetcher login — must be set
ANTHROPIC_API_KEY=sk-ant-...            # web chat — needed when you use the AI chat
```

**Recommended (cosmetic / quality):**

```bash
DISPLAY_NAME=YourName
BIOLOGICAL_SEX=Male        # Male / Female — drives sex-specific reference ranges
```

**Ignore these in `.env`** — the compose file overrides them:
`SQLITE_DB_PATH`, `TOKEN_DIR`, `WEB_HOST`, `WEB_PORT`. They are forced to
`/data/garmin.db`, `/tokens`, `0.0.0.0`, `8080` inside the containers.

---

## 2. Build and start

```bash
cd /root/garmin-stats-ai
mkdir -p data tokens          # host dirs for the DB and token cache
docker compose up -d --build
```

`-d` runs detached; `--build` (re)builds the image. First build takes a few
minutes (installs pandas, scipy, etc.).

### Access the dashboard

```
http://<server-ip>:8090
```

> **Port note:** the host port is **8090**, not 8080. Port 8080 on this server
> is already used by another container (`searxng`). Inside the container the app
> still listens on 8080; only the host-side mapping is 8090
> (`"8090:8080"` in `docker-compose.yml`). To change it, edit the left number.

> **Security:** the web app has **no built-in authentication**. Only expose port
> 8090 on a trusted network, or put it behind a reverse proxy / tunnel with auth
> (see `docs/deployment-security.md`).

---

## 3. Operate

```bash
cd /root/garmin-stats-ai

docker compose ps                   # status of both services
docker compose logs -f fetcher      # follow fetcher (Garmin sync activity)
docker compose logs -f web          # follow web server (HTTP, chat)
docker compose logs --tail=50 web   # last 50 lines

docker compose restart web          # restart just the web app
docker compose restart fetcher      # restart just the fetcher
docker compose up -d --build        # rebuild + apply changes after editing files
docker compose down                 # stop & remove both (DB/tokens persist in ./data, ./tokens)
docker compose stop                 # stop without removing
```

### Logs

The apps log to stdout/stderr; there are **no log files inside the container**.
Always read logs via `docker compose logs`. (Docker stores them as JSON under
`/var/lib/docker/containers/`, but don't read those directly.)

### How to tell it's healthy

1. `docker compose ps` → both show `Up` (not `Restarting`).
2. `curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8090/` → `200`.
3. `docker compose logs --tail=20 fetcher` → recent `Success : ...` lines.
4. The dashboard header shows a recent **"last sync"** time.

---

## 4. Backfill historical data

On the **first run with an empty DB, the fetcher only pulls the last 7 days**
and then only syncs forward. To load history, run a one-shot backfill with
`MANUAL_START_DATE`. When that variable is set, the fetcher does a bulk fetch of
the whole range and then **exits** — so run it as a separate throwaway
container, never in the long-running `fetcher` service (otherwise the restart
policy would loop it forever).

```bash
cd /root/garmin-stats-ai

# Backfill from a chosen start date to today, detached:
docker compose run -d --name garmin-backfill \
  -e MANUAL_START_DATE=2025-02-01 \
  fetcher python -m garmin_grafana.garmin_fetch
```

This reuses the fetcher's image, `.env`, and the same `/data` + `/tokens`
volumes, so backfilled data lands in the same DB the web app reads.

### Monitor and clean up

```bash
docker logs -f garmin-backfill           # watch progress
docker ps --filter name=garmin-backfill  # still running?
# When done it logs "Bulk update success" and exits on its own.
docker rm garmin-backfill                # remove the stopped one-shot container
```

> **Expect it to be slow.** Calls are rate-limited (~5s between metrics), so a
> long range (hundreds of days) can take hours. This is intentional to avoid
> Garmin rate-limiting your account. The live dashboard fills in progressively;
> refresh after it completes.

---

## 5. Timezone

Garmin stores all timestamps in **UTC**. For the dashboard to show times in your
local wall-clock (sleep bed/wake times, hour-of-day heatmaps, "today"), the
`web` container's timezone must be set.

This is configured in `docker-compose.yml` on the `web` service:

```yaml
environment:
  TZ: America/Toronto      # Montreal / Eastern Time
```

Change `TZ` to your own zone (standard IANA name, e.g. `America/New_York`,
`Europe/London`, `Asia/Shanghai`) and restart the web app:

```bash
docker compose up -d web
```

### Fetcher timezone (usually automatic)

The fetcher has a separate `USER_TIMEZONE` env var (default empty). Left blank,
it **auto-detects** your zone from your last Garmin activity, which is correct
for most people. Set it explicitly in `.env` only if auto-detection is wrong:

```bash
USER_TIMEZONE=America/Toronto
```

### Timezone display fixes applied to the source

Three dashboard views originally read the raw UTC timestamp and so displayed
times shifted by the UTC offset. These were fixed in the repo source to convert
UTC → local (honouring the `TZ` above):

- `web/visualizations.py` — sleep timeline bed/wake times (`.astimezone()`)
- `web/visualizations.py` — intraday heatmap (SQLite `datetime(time,'localtime')`)
- `web/lifestyle_viz.py` — stress hour-of-day fingerprint (same `localtime` fix)

If you change `TZ`, these views follow it automatically after a `web` restart.

## 6. Auto-restart after host reboot

Already configured — no extra setup needed:

- The Docker daemon is enabled on boot (`systemctl is-enabled docker` → `enabled`).
- Both services use `restart: unless-stopped` in `docker-compose.yml`.

So after a host reboot the containers come back automatically — **unless** you
had deliberately `docker compose stop`/`down` them first (that's the point of
`unless-stopped`). To bring them back after a deliberate stop, run
`docker compose up -d`.

---

## Known fix baked into the image

The web app serves static assets from `garmin_insights/web/static/`, but those
files are **not declared as package data** in `garmin-insights/pyproject.toml`,
so `pip install` drops them and the web server crashes on startup with
`RuntimeError: Directory '.../web/static' does not exist`.

The `Dockerfile` works around this by copying `web/static/` into the installed
package after `pip install`. This keeps the cloned repo source unmodified. If
the project later fixes `pyproject.toml` to include that data (e.g. via
`[tool.setuptools.package-data]`), the Dockerfile step becomes redundant and can
be removed.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `web` keeps `Restarting` | Check `docker compose logs web`. If it's the `web/static` error, rebuild with `--build` (the fix is in the Dockerfile). |
| `fetcher` keeps `Restarting` | Missing/wrong Garmin creds in `.env`, or it hit the interactive login prompt. Check `docker compose logs fetcher`. |
| Dashboard shows only 7 days | Expected on first run — see **Backfill** above. |
| `data/garmin.db` never appears | Fetcher never completed a successful sync — check its logs for login errors. |
| Can't reach `:8090` | Container not up, firewall, or port conflict. Check `docker compose ps` and `ss -ltnp \| grep 8090`. |
| Port 8090 also taken | Edit the `ports:` mapping in `docker-compose.yml` to a free host port. |

---

## 7. Read-only DB snapshot over Tailscale (external access)

A second machine (`muse`) needs read-only access to `garmin.db` **without SSH**.
This is done with two extra services plus a host-level Tailscale node — the
remote only ever fetches a consistent, at-most-1-hour-old snapshot over HTTP.

### How it works

```
fetcher ──writes──► data/garmin.db  (WAL mode, live)
                          │
         db-export ──VACUUM INTO (hourly)──► export/garmin_export.db  (clean single file)
                          │
         db-serve (busybox httpd) ──serves /export──► http://docker-lxc:18080/garmin_export.db
                          │
                   Tailscale (tag:docker) ──ACL: only tag:muse → tcp:18080──► muse
```

- **`db-export`** — reuses the `garmin-stats-ai:latest` image (it has python+sqlite3).
  Every `INTERVAL_SECONDS` (default 3600) it runs `VACUUM INTO` to produce a
  **consistent** single-file snapshot at `export/garmin_export.db`, written to a
  temp file then atomically `mv`'d into place. `VACUUM INTO` is required because
  the live DB is in **WAL mode**: a plain copy of `garmin.db` would miss whatever
  is still in `-wal`, and the snapshot is a normal `journal_mode=delete` DB that
  the client opens with no `-wal`/`-shm` needed.
- **`db-serve`** — `busybox:1.36` httpd serving **only** the `./export` dir.
  ~0.5 MB RSS. No directory listing (`GET /` returns 404); the file is reachable
  only by its exact name `garmin_export.db`.
- **Host Tailscale node** — Tailscale runs on the docker LXC host (not in a
  container), advertising `tag:docker`. The httpd port is bound to the host's
  **Tailscale IP only** (`${DB_SERVE_BIND_IP}:18080:18080`), so it is not reachable
  from LAN/public even if ACLs change (defense in depth).

### Compose services (appended to `docker-compose.yml`)

```yaml
  db-export:
    image: garmin-stats-ai:latest
    container_name: garmin-db-export
    entrypoint: ["/bin/sh", "/app/export_db.sh"]
    environment:
      SRC: /data/garmin.db
      DST: /export/garmin_export.db
      INTERVAL_SECONDS: "3600"
    volumes:
      - ./data:/data            # must be read-write: WAL-mode DB can't be
                                # opened from a :ro mount (needs -wal/-shm)
      - ./export:/export
      - ./deploy/export_db.sh:/app/export_db.sh:ro
    mem_limit: 128m
    restart: unless-stopped

  db-serve:
    image: busybox:1.36
    container_name: garmin-db-serve
    command: ["httpd", "-f", "-v", "-h", "/export", "-p", "18080"]
    volumes:
      - ./export:/export:ro
    ports:
      - "${DB_SERVE_BIND_IP}:18080:18080"   # bind to Tailscale IP only
    read_only: true
    cap_drop: ["ALL"]
    security_opt: ["no-new-privileges:true"]
    mem_limit: 32m
    depends_on:
      - db-export
    restart: unless-stopped
```

The export loop lives in `deploy/export_db.sh` (mounted into `db-export`).

### Why `/data` is read-write for `db-export`

WAL-mode SQLite **cannot open a database on a read-only mount** — it needs to
create/touch the `-wal` and `-shm` sidecar files. A `:ro` mount fails with
`unable to open database file`. The container only ever runs `VACUUM INTO`
(logically read-only on the source) and the script issues no writes to it.

### Operate

```bash
# bring the two services up
docker compose up -d db-export db-serve

# check the latest export happened
docker logs garmin-db-export | tail

# the snapshot the client fetches
ls -l export/garmin_export.db
```

### Client (muse) usage

```bash
# MagicDNS name is stable across IP changes; 18080 is the only allowed port
curl -fsS -o garmin.db http://docker-lxc:18080/garmin_export.db
sqlite3 garmin.db "PRAGMA integrity_check;"   # expect: ok
```

- Freshness: at most 1 hour old (hourly export).
- The remote must be on Tailscale with `tag:muse`; the ACL grant allows only
  `tag:muse → tag:docker : tcp:18080` (no SSH, no other ports/hosts).

### Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `db-export` logs `unable to open database file` | `/data` mounted `:ro` — change to `./data:/data` (WAL needs write access to sidecar files). |
| `GET /` returns 404 | Expected — no directory listing. Use the exact path `/garmin_export.db`. |
| Client can't reach `:18080` | muse not on Tailscale, missing `tag:muse`, or ACL grant not saved. Verify `tailscale status`. |
| `export/garmin_export.db` missing | First export not done yet or VACUUM failed — check `docker logs garmin-db-export`. |
