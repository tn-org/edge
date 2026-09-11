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

The host layer does not call the ops console at all. The contract is one directory,
`sync/` at the repo root, which the console mounts from its own compose file:

- `sync/state/` is written by `scripts/notify.sh` and `scripts/report.sh` and read by the
  console. `events/YYYY-MM-DD.ndjson` gets one JSON object per notification, appended;
  `bans.json`, `timers.json`, `reboot.json`, `disk-usage.json` and `host.json` are full
  snapshots, rewritten through a `.tmp` file so a reader never sees half of one.
  `host.json` carries the facts the console cannot derive on its own (currently the
  dashboard FQDN) and is only rewritten when its content changed, so the console can skip
  a `generatedAt` it has already taken in. The JSON shape dates
  from a fail2ban-era implementation and did not change: what used to be a fail2ban "jail"
  is a CrowdSec scenario name.
- `sync/ops/` is the other direction. The console writes `req-<id>.json`
  (`kind` = `ban`, `timer` or `reboot`), the host executes it during `host-sync` and writes
  `res-<id>.json` beside it; the console deletes both once it has taken the result in. A
  request that already has a result is never run again. What an operation may touch is
  decided on this side (`is_managed_unit`), never by the request.
- Permissions: `state/` is 755 with 644 files (the console mounts it read-only), `ops/` is
  777 with 666 files, because the console container writes there as a different user. The
  timers run as root and restore ownership after writing, the same way
  `render-config.sh` does for the generated config.
- There is no shared secret, no URL and no key in `.env` for any of this. A host without a
  console writes the same files and nobody reads them.
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

## The two host modes

`EDGE_TLS_MODE` (`letsencrypt` or `origin-ca`) selects what the stack is made of. It
defaults to `letsencrypt`, what the host did before the key existed. The mode also
decides whether CrowdSec runs: it does with `letsencrypt` and retires with `origin-ca`
(behind Cloudflare); there is no separate switch. The scripts that care read the key
through `scripts/mode-lib.sh`, which is also where the default, the derivation and the
accepted values are defined once.

- `origin-ca` means the certificates are the files in `certs/` (Cloudflare Origin CA, 15
  years, placed by hand). `render-config.sh` lists them in
  `traefik/dynamic/generated-tls.yml` and filters ACME out of the static config. Port 80
  and the redirect to HTTPS are unchanged, so the only difference is where a certificate
  comes from. The ACME store is left in place, which is what makes going back one key.
- `off` means no CrowdSec container and no bouncer in the entrypoint's default middlewares.
  Rate limiting, the concurrency limit and the security headers are Traefik's own and are
  unaffected. The blocking report timer is not installed and `bans.json` is not published,
  so nothing reports a guard that is not running.

Both filters run over the already substituted static config and check their own result, so
a template edit that moves the lines they look for fails the render instead of producing a
proxy that serves the wrong thing.

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
