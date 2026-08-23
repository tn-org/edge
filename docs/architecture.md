# Architecture and contracts

This repo carries the host layer only. It ships the whole "box" side of a single server:

- **Traefik v3** as the reverse proxy. Routing is discovered from the compose labels of
  the applications running on the host (docker provider). TLS certificates come from the
  built-in ACME resolver.
- **CrowdSec** for abuse detection. It reads the Traefik access log and decides what to
  block; the bouncer plugin inside Traefik does the actual rejecting.
- **Host maintenance**: systemd timers (disk usage, blocking report, pending reboot, host
  sync), log rotation, OS auto-updates (dnf-automatic) and the operational scripts under
  `scripts/`.

Every host runs the same contents of this repo. It is a concrete deployment rather than a
template, and each host clones it as-is. Everything host specific lives in `.env`, which
is not tracked by git; no application name, domain or host-specific path appears in the
repo itself. The install location is always `/app/edge`.

The ops console is **not** part of this repo. Each application repo owns and deploys its
own, at `/app/<slug>/console` on the server.

## Adding an application does not touch edge

The application declares how it is exposed through its own compose labels. edge holds no
domain and no upstream; there is deliberately nowhere to write them.

```yaml
services:
  backend:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.<name>.rule=Host(`${PUBLIC_HOST:?PUBLIC_HOST is not set}`)"
      - "traefik.http.routers.<name>.entrypoints=websecure"
      - "traefik.http.services.<name>.loadbalancer.server.port=8000"
    networks: [edge]
```

No host port publishing is required, because Traefik reaches the container over the
shared network. TLS, rate limiting, security headers and blocking already apply to every
router through the entrypoint's default middlewares, so labels only need to add
application-specific middlewares.

## Contract with the ops console (do not change)

The host layer does not depend on the ops console, but two touch points are fixed:

- `scripts/notify.sh` and `scripts/report.sh` post to the notification hub (the console's
  `/internal/notify` and friends) at `OPS_NOTIFY_URL` from `.env`, default
  `http://127.0.0.1:9090`, authenticated with `INTERNAL_TOKEN` from `.env`. The blocking
  sync endpoint stays `/internal/fail2ban`: the implementation behind it is CrowdSec now,
  but the JSON shape did not change, and what used to be a fail2ban "jail" is a CrowdSec
  scenario name.
- The console publishes itself through the Traefik labels in its own compose file. Both
  sides meet on the shared external docker network named by `EDGE_NETWORK` in `.env`
  (default `edge`).

## Rendering config from `.env`

Traefik's static config and the CrowdSec LAPI key cannot expand environment variables
inside the file. `scripts/render-config.sh` substitutes the `.env` values (`ACME_EMAIL`,
`EDGE_NETWORK`, `CROWDSEC_BOUNCER_KEY`) and writes the result into `traefik/generated/`
and `crowdsec/generated/`, both untracked. `make up` and `deploy-host.sh` run it
automatically; call `make render` by hand only when you want a value change applied
immediately.

## Updates (this repo does not push itself)

**There is no deploy mechanism from edge to a host, and no CI workflow in this repo.** The
only update path runs on the host: `make update` does `git fetch`, then
`git reset --hard origin/$DEPLOY_BRANCH`, then `scripts/deploy-host.sh`. That script
renders the config and runs `compose up -d`. Routing and middlewares are watched by
Traefik, so no restart is needed for them; containers are recreated only when the static
config (`traefik/traefik.yml`, `crowdsec/`) changed.

Changes under `/etc` and to systemd units require `make host-apply`, run by hand.

Hosts that should follow automatically enable `edge-update.timer`, which runs
`make update` daily at 05:00 (Asia/Tokyo). The unit is installed by `make host-apply`, but
enabling it is a manual `systemctl enable --now`.

For bringing up a new host see `README.md`, for the command list and where each command
runs see `docs/commands.md`, and for the blocking design see
`docs/abuse-blocking-design.md`.
