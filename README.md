# edge

The host layer for a single server, shipped as one repo. Every host runs the same
contents of this repo and clones it as-is. It is not a template, so there are no
placeholders to substitute. Everything that differs per host lives in
`.env`, which is not tracked by git.

What is in here:

| Path                                  | Role                                                                        |
| ------------------------------------- | --------------------------------------------------------------------------- |
| `docker-compose.yml`                  | Traefik v3 (80/443, ACME) and CrowdSec, both joining a shared network       |
| `traefik/`                            | Static config template plus the host-wide dynamic config (TLS, middlewares) |
| `crowdsec/`                           | Acquisition (Traefik access log) and the collections to enable              |
| `systemd/` `logrotate/` `auto-patch/` | Host maintenance timers, log rotation, OS auto-updates                      |
| `scripts/`                            | Setup, deploy, notification and blocking operations                         |

**Nothing here is application specific.** There is no domain list, no upstream list and
no certificate mapping. Each application declares how it is exposed through Traefik
labels in its own compose file, and Traefik's ACME resolver obtains the certificates.
The ops console is also owned by the application repo and runs at `/app/<slug>/console`
on the server.

```
One server
 ├ /app/edge                 this repo: Traefik + CrowdSec + systemd timers + host notifications
 │                             creates one shared docker network (default name: edge)
 ├ /app/<slug>/main/prod     an application; a compose label is enough to expose an FQDN
 ├ /app/<slug>/main/stag     same, for a second environment
 ├ /app/<slug>/console       the ops console
 └ /app/<slug2>/...          more applications work the same way; edge does not change
```

## Bringing up a new host

**This repo has no mechanism to push itself onto a host.** Clone it on the host, run
`make setup`, and run `make update` on the host whenever you want to pick up changes
(hosts that should follow automatically can enable a timer). No CI configuration and no
cloud secrets or variables are required.

Log in to the server over SSH or a session manager as the deploy user (for example
`ssm-user` on Amazon Linux with SSM), then:

1. Clone the repo into its fixed location
   ```
   sudo dnf install -y git
   sudo mkdir -p /app && sudo chown "$(id -un):$(id -gn)" /app
   git clone https://github.com/tn-org/edge.git /app/edge
   ```
2. Run the bootstrap (everything up to a running edge)

   ```
   cd /app/edge
   bash scripts/bootstrap-host.sh
   ```

   It installs the runtime (docker, the compose plugin, make — a fresh Amazon Linux
   2023 AMI ships none of them), asks for the ACME e-mail and whether this host runs
   the shared PostgreSQL, fills `.env` (secrets generated with openssl) and runs
   `make setup`: shared network, rendered config, Traefik + CrowdSec, and the `/etc`
   files and systemd timers (log rotation, OS auto-updates, blocking report, disk
   usage record, host sync). The auto-follow timer (`edge-update`) is installed but
   deliberately left disabled.

   Idempotent — existing `.env` values are never overwritten. Pass
   `--acme-email <addr>` and `--db`/`--no-db` to skip the prompts, or
   `--prepare-only` to stop after the runtime install and do `cp .env.example .env`,
   `make env` and `make setup` by hand. There is no key for the ops console: the
   host writes into `sync/` and the console reads it. Log out and back in once
   afterwards so your own shell can use docker.

3. Verify
   ```
   make ps
   docker compose logs traefik | grep -i acme
   docker compose exec crowdsec cscli metrics
   ```
   If the acquisition section of `cscli metrics` stays empty, CrowdSec is not reading the
   log. It still exits successfully in that state, so check it by eye.

## Updating

When the repo moves forward, pull the change on the host. **The only update path is the
host pulling**; nothing pushes from the origin side.

```
cd /app/edge
make update
```

That runs `git fetch`, `git reset --hard origin/main` and `scripts/deploy-host.sh`
(render config, `compose up -d`, and recreate containers only if the static config
changed). Use `DEPLOY_BRANCH=<branch> make update` to follow a different branch.

Changes under `/etc` and to systemd units are not picked up by `make update`. Run
`make host-apply` afterwards for those.

### Following automatically (optional)

A systemd timer that runs `make update` every day at 05:00 (Asia/Tokyo) is included. The
unit is installed by `make setup` and `make host-apply` but **never enabled**. On hosts
that should follow automatically, enable it once:

```
sudo systemctl enable --now edge-update.timer
systemctl list-timers edge-update.timer
```

Stop it with `sudo systemctl disable --now edge-update.timer`. Failures are picked up by
`notify-failure@`, which records them in journald and in `sync/state/events/`. To try it
by hand, run
`sudo systemctl start edge-update.service` and `journalctl -u edge-update -n 30`.

## Exposing an application

**Nothing has to change in edge.** Adding labels to the application's compose file is
enough.

```yaml
services:
  backend:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.<slug>-${APP_ENV}.rule=Host(`${PUBLIC_HOST:?PUBLIC_HOST is not set}`)"
      - "traefik.http.routers.<slug>-${APP_ENV}.entrypoints=websecure"
      - "traefik.http.services.<slug>-${APP_ENV}.loadbalancer.server.port=8000"
    networks: [edge]

networks:
  edge:
    external: true
    name: ${EDGE_NETWORK:-edge}
```

- Each container keeps its public FQDN in its own `.env` as `PUBLIC_HOST`. The `:?`
  suffix refuses to start when it is unset.
- Write labels in list form; compose does not expand variables in mapping keys.
- No host port publishing is needed. The host layer never calls into a container either:
  `report.sh` and `notify.sh` write files under `sync/` and the console reads them.
- TLS, rate limiting, security headers and blocking are applied to every router by the
  entrypoint's default middlewares. Labels do not need to repeat them.
- Blocking external access to `/internal/` is the application's job (respond 404 to
  `/internal/` requests that carry `X-Forwarded-For`). That keeps it independent of the
  proxy in front.

## Talking to the ops console

The host layer writes files; it never calls the console. Everything lives in `sync/` at
the repo root (untracked, created on first write), which the console mounts from its own
compose file.

```
sync/
 ├ state/                    written here, read-only for the console
 │  ├ events/YYYY-MM-DD.ndjson   one notification per line, appended (dropped after 14 days)
 │  ├ bans.json                  blocking state snapshot
 │  ├ timers.json                scheduled job state snapshot
 │  ├ reboot.json                pending-reboot state snapshot
 │  ├ disk-usage.json            usage per directory (daily)
 │  └ host.json                  facts about the host itself (the dashboard FQDN)
 └ ops/                      the console writes req-<id>.json, the host answers res-<id>.json
```

Snapshots are rewritten in full on every `host-sync` run through a `.tmp` file, so a
reader never sees half of one. Operation requests (unblock an IP, run a timer, schedule a
reboot) are picked up by the same run; a request whose `res-` file already exists is never
run twice, and the console deletes both files once it has taken the result in. Which units
an operation may touch is decided here (`is_managed_unit` in `scripts/report.sh`), not by
whoever wrote the request.

There is nothing to configure, and nothing to undo on a host with no console: the files
are written either way and simply go unread.

## `.env` keys

| Key                    | Default       | Description                                                                                           |
| ---------------------- | ------------- | ----------------------------------------------------------------------------------------------------- |
| `APP_ENV`              | `local`       | `local` = workstation, anything else = server. Controls sudo and the server-only guard                |
| `EDGE_NETWORK`         | `edge`        | Name of the one shared docker network; edge and every application join it as external                 |
| `EDGE_TLS_MODE`        | `letsencrypt` | `letsencrypt` = Traefik's ACME resolver; `origin-ca` = certificates placed by hand in `certs/`        |
| `ACME_EMAIL`           | —             | Registration address for Let's Encrypt (where expiry notices go)                                      |
| `EDGE_CROWDSEC`        | `auto`        | `auto` = follow `EDGE_TLS_MODE`; `off` = no CrowdSec container and no bouncer, whatever the TLS mode  |
| `CROWDSEC_BOUNCER_KEY` | —             | Shared secret between the Traefik bouncer and the CrowdSec LAPI; compose refuses to start without it  |
| `COMPOSE_PROFILES`     | —             | Optional services to include in `up`/`update`; `db` adds the shared PostgreSQL instance               |
| `POSTGRES_PASSWORD`    | —             | Superuser password of the shared PostgreSQL instance; read only when the db service starts            |
| `POSTGRES_PORT`        | `5432`        | Host-side loopback port of the shared PostgreSQL instance; containers always use `edge-postgres:5432` |

Generate `CROWDSEC_BOUNCER_KEY` with `openssl rand -hex 32`. `.env` is not tracked by git
and exists only on the server. Compare it against the example with `make env CMD=check`.

## Shared database (optional)

One PostgreSQL instance per host, shared by every application: each one gets its own
database and owner role, nothing else differs. A host whose databases live in a managed
service (RDS etc.) skips this entirely — the service sits behind the `db` compose
profile and is off by default.

- Server: set `COMPOSE_PROFILES=db` and `POSTGRES_PASSWORD` in `.env`; the regular
  `make up` / `make update` path then carries the database.
- Workstation: `make db-up` starts the database alone (Traefik and CrowdSec never run
  locally) and creates the shared network if needed.

Provision an application with:

```
make db-create NAME=myapp PASSWORD=...
```

This creates role `myapp` owning database `myapp` and is idempotent; the password is
only needed while the role does not exist yet. The application connects with
`DB_HOST=edge-postgres` on the shared network (or `127.0.0.1:$POSTGRES_PORT` from the
host — the port is published on loopback only). Data lives in the `pgdata` named
volume.

## Hosts behind the Cloudflare proxy (optional modes)

Two keys in `.env` change what the stack is made of. Both default to what every host did
before they existed, so a `.env` that does not mention them is unaffected, and both are
reversible by putting the key back.

### `EDGE_TLS_MODE=origin-ca` — certificates placed by hand

For a host that is only reachable through the Cloudflare proxy. Traefik obtains nothing:
it serves the certificate files in `certs/`, which Cloudflare issues for 15 years.

1. In the Cloudflare dashboard, SSL/TLS > Origin Server > Create Certificate. One
   certificate covers `example.com` and `*.example.com`.
2. Save the two halves on the host as `certs/<apex>.pem` and `certs/<apex>.key`
   (the directory is created by `make render` and is not tracked by git).
3. Set `EDGE_TLS_MODE=origin-ca` in `.env` and run `make update`.

`scripts/render-config.sh` writes every pair it finds into
`traefik/dynamic/generated-tls.yml` and leaves ACME out of the static config; Traefik picks
a certificate per connection by SNI, so several apexes can share one host. Port 80 and the
redirect to HTTPS stay exactly as they are in either mode. The daily certificate report
reads `certs/` instead of the ACME store and warns the same way. Going back is
`EDGE_TLS_MODE=letsencrypt` plus `make update`: the ACME store is never deleted.

`make update` rather than `make up`, here and for every mode key: the mode changes
Traefik's static config, which Traefik reads only when it starts, and `make up` does not
recreate a running container. `make update` first follows origin like any update, then
runs `scripts/deploy-host.sh`, which renders the config, brings compose in line with the
mode (the CrowdSec service scaled to zero when it does not run), and restarts Traefik
because the static config changed. A mode change applied with `make up` alone stays
inactive until the next `make update` (the daily one too, on hosts that enable
`edge-update.timer`), so run `make update` right after editing `.env` and check the
result.

### Behind Cloudflare there is no abuse detection on this host

With `EDGE_CROWDSEC=auto` (the default) CrowdSec follows `EDGE_TLS_MODE`. With
`letsencrypt` it runs as it always has. With `origin-ca` it does not run — the host sits
behind the Cloudflare proxy with its security group admitting only Cloudflare, so
edge-level IP banning is redundant and stops together with the switch, with no separate
step: no container, no bouncer in the default middleware list, no blocking report timer,
`make ban` stops with the reason, and no blocking state is published to the ops console,
so no screen shows a guard that is not running. The rate limit, the concurrency limit
and the security headers are Traefik's own and stay in place in every mode; blocking a
client on an origin-ca host is done at Cloudflare.

### `EDGE_CROWDSEC=off` — no abuse detection on a letsencrypt host

For a host whose application's legitimate traffic matches the HTTP detection scenarios
(for example many requests for extension-less image URLs at once, or a run of 404s the
application returns by design) and cannot be changed yet, so CrowdSec would keep
blocking real users. `off` stops CrowdSec whatever `EDGE_TLS_MODE` says, with exactly
the result described above for `origin-ca`.

```
make env KEY=EDGE_CROWDSEC VALUE=off  # writes the key to .env
make update      # renders without the bouncer, drops CrowdSec, restarts Traefik
make host-apply  # removes the blocking report timer
```

Why `make update` and not `make up` is explained under `EDGE_TLS_MODE=origin-ca` above:
here the bouncer leaves Traefik's static config.

Going back is `EDGE_CROWDSEC=auto` plus the same two commands (`make update`, then
`make host-apply`). Only `auto` and `off` are accepted; there is no `on`, because no
host needs blocking behind Cloudflare.

## Traefik dashboard (optional)

Set both keys in `.env` and run `make render` (or `make update`):

```
DASHBOARD_HOST=traefik.example.com
DASHBOARD_AUTH=admin:$apr1$...      # openssl passwd -apr1 'your-password'
```

Point a DNS record for that FQDN at this host. The dashboard is then served over HTTPS
(its certificate comes from whatever `EDGE_TLS_MODE` provides, like any other route)
behind basic auth. With the keys empty
(the default) no route exists and the dashboard is unreachable. It is read-only: it
shows routers, services and middlewares, and cannot change anything.

## Further reading

- Command list and where each one runs: `docs/commands.md`
- Blocking design: `docs/abuse-blocking-design.md`
- Cloud-side monitoring (external checks, managed database): `docs/aws-monitoring-setup.md`
- Repo structure and contracts: `docs/architecture.md`
