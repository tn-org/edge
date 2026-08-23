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
   sudo mkdir -p /app && sudo chown "$USER:$USER" /app
   git clone https://github.com/tn-org/edge.git /app/edge
   ```
2. Create `.env` and fill it in
   ```
   cd /app/edge
   cp .env.example .env
   make env
   ```
   Set `APP_ENV=production`, `ACME_EMAIL`, `INTERNAL_TOKEN` and `CROWDSEC_BOUNCER_KEY`.
   Generate the two secrets with `openssl rand -hex 32`. `INTERNAL_TOKEN` must be the
   same single value across this host's applications, ops console and host layer.
   Leave `EDGE_NETWORK` and `OPS_NOTIFY_URL` at their defaults.
3. Run the full setup (repeatable and idempotent)
   ```
   make setup
   ```
   This creates the shared network, renders the config, starts Traefik and CrowdSec, and
   applies the `/etc` files and systemd timers (log rotation, OS auto-updates, blocking
   report, disk usage record, host sync). The auto-follow timer (`edge-update`) is
   installed but deliberately left disabled.
4. Verify
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
`notify-failure@` and forwarded to the notification hub. To try it by hand, run
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
- No host port publishing is needed. The ops console is the exception and keeps
  `127.0.0.1:9090:9090`, because `report.sh` and `notify.sh` post to it from outside docker.
- TLS, rate limiting, security headers and blocking are applied to every router by the
  entrypoint's default middlewares. Labels do not need to repeat them.
- Blocking external access to `/internal/` is the application's job (respond 404 to
  `/internal/` requests that carry `X-Forwarded-For`). That keeps it independent of the
  proxy in front.

## `.env` keys

| Key                    | Default                 | Description                                                                                          |
| ---------------------- | ----------------------- | ---------------------------------------------------------------------------------------------------- |
| `APP_ENV`              | `local`                 | `local` = workstation, anything else = server. Controls sudo and the server-only guard               |
| `EDGE_NETWORK`         | `edge`                  | Name of the one shared docker network; edge and every application join it as external                |
| `ACME_EMAIL`           | —                       | Registration address for Let's Encrypt (where expiry notices go)                                     |
| `INTERNAL_TOKEN`       | —                       | Shared secret for internal calls; one value across applications, ops console and host layer          |
| `OPS_NOTIFY_URL`       | `http://127.0.0.1:9090` | Where the notification hub lives; change only if the ops console runs on another host                |
| `CROWDSEC_BOUNCER_KEY` | —                       | Shared secret between the Traefik bouncer and the CrowdSec LAPI; compose refuses to start without it |

Generate `INTERNAL_TOKEN` and `CROWDSEC_BOUNCER_KEY` with `openssl rand -hex 32`. `.env`
is not tracked by git and exists only on the server. Compare it against the example with
`make env CMD=check`.

## Further reading

- Command list and where each one runs: `docs/commands.md`
- Blocking design: `docs/abuse-blocking-design.md`
- Cloud-side monitoring (external checks, managed database): `docs/aws-monitoring-setup.md`
- Repo structure and contracts: `docs/architecture.md`
