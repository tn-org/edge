# Architecture and contracts

This repo carries the host layer only. It ships the whole "box" side of a single server:

- **Traefik v3** as the reverse proxy. Routing is discovered from the compose labels of
  the applications running on the host (docker provider). TLS certificates come from the
  built-in ACME resolver.
- **CrowdSec** for abuse detection. It reads the Traefik access log and decides what to
  block; the bouncer plugin inside Traefik does the actual rejecting.
- **Host maintenance**: a swapfile sized from the host's memory with its boot unit and
  swappiness setting (`scripts/setup-swap.sh`, `systemd/swapfile.swap`, `sysctl/`),
  systemd timers (disk usage, access log count, blocking report, certificate expiry,
  pending reboot, host sync), log rotation, OS auto-updates (dnf-automatic) and the
  operational scripts under
  `scripts/`. The swap is for the host and the edge containers; keeping application
  containers off it is left to their own compose files. Its rules are under "Swap" in
  `README.md`.

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
  console. `events/YYYY-MM-DD.ndjson` gets one JSON object per notification, appended.
  One of them is routine and arrives every day from every host: the "Host daily report"
  that `report.sh disk-usage` sends after its measurement (08:30). The console treats a
  host route with no event for 25 hours as dead, and this report is what keeps it alive on
  hosts that run no CrowdSec (the blocking report, the other routine event, is not
  installed there);
  `bans.json`, `timers.json`, `reboot.json`, `disk-usage.json`, `host.json` and
  `metrics.json` are full snapshots, rewritten through a `.tmp` file so a reader never
  sees half of one.
  `host.json` carries the facts the console cannot derive on its own: `dashboard` (the
  dashboard FQDN as `{"host": …}`, or null) and `abuseBlocking` (`{"runs": true}` when
  CrowdSec runs, otherwise `{"runs": false, "reason": "off"}` for `EDGE_CROWDSEC=off` or
  `"origin-ca"` for a host behind Cloudflare, `off` winning when both apply). The console
  expects the daily blocking report only from a host whose `runs` is true. The file is
  only rewritten when its content changed, so the console can skip a `generatedAt` it has
  already taken in. `metrics.json` is the opposite: a reading of
  memory, swap, load and CPU for the host and for each running container, rewritten with
  a new `generatedAt` on every `host-sync` run. Its swap counters (`pswpin` / `pswpout`)
  are totals since boot, so the console takes the difference between two readings, and
  `swap.swappiness` is the kernel's `vm.swappiness`. A container's `cpuPercent` is
  docker's figure, where 100 is one whole CPU, while the host's `usagePercent` is the
  share of all CPUs together. A container's `composeProject` and `composeService` are its
  `com.docker.compose.project` and `com.docker.compose.service` labels: `docker stats`
  prints no labels, so they are read with `docker ps` and matched by container name, and
  they are null for a container compose did not create. A figure that cannot be read is
  null and the rest is still written. `containers` is the one group that can be null as a
  whole: a list means `docker stats` answered (an empty one, that no container is
  running), null means docker could not be used, and the host's figures are written
  either way. The rules for each figure are in the
  `host-metrics` part of `scripts/report.sh`. `reboot.json` carries `required`
  (`needs-restarting -r`) and `servicesToRestart`: the systemd units that
  `needs-restarting -s` names as still running code an update has replaced, each once and
  in name order. It is `[]` when there is none and null when they could not be checked
  (`needs-restarting` is missing, failed or took over 30 seconds); a null does not fail the
  run. The check walks every process, so its answer, a failed one included, is kept in
  `.state/services-to-restart` and taken again only when that is 30 minutes old or older
  than the current boot; until then the list can be up to 30 minutes behind. edge restarts
  no service; the list is only shown. The JSON shape of `bans.json` dates from a
  fail2ban-era implementation and did not change: what used to be a fail2ban "jail" is a
  CrowdSec scenario name.
- `state/traffic/<host>.json` is the Traefik access log counted per hostname and per
  Japanese day (Asia/Tokyo), for the console's user analytics screen. `report.sh traffic`
  writes it every hour at about :07 (`report-traffic.timer`; the counting and its rules
  are in `scripts/traffic_report.py`): one file per hostname, the whole file on every run,
  through a `.tmp` file and a rename. It counts only what the log already records;
  `traefik/traefik.yml` and `logrotate/traefik` are not changed for it.
  - Shape: `version` (1), `generatedAt`, `host`, `rulesVersion`, `timezone`
    (`Asia/Tokyo`) and `days`, oldest first. Each day has `date`, `complete`,
    `coveredUntil`, `computedAt`, `missingHours`, `requests`, `pageViews`, `visitors`,
    `botPageViews`, `hours` (always 24, 00:00 to 23:00, each with `pageViews`, `visitors`
    and `newVisitors`), `pages` (at most 50, most page views first, each with `path`,
    `pageViews` and `visitors`), `pagesOther` (`pageViews` and `visitors` of the rest)
    and `devices` (`mobile`, `desktop`, `tablet` and `other`, in visitors).
  - Days: a line's `StartUTC`, in Japanese time, decides its day and hour, never the file
    it is in or the host's time zone. The window is today and the 189 days before it. A
    day is `complete` once it has been over for an hour and every log file that may hold
    it was read; from then on it is kept in `.state/traffic/` and not counted again, so its
    `computedAt` no longer moves. Today, and yesterday until it is complete, are counted
    again on every run. The days before that are filled in from the rotated logs
    (compressed ones included) at most 7 a run, newest first, so the first runs on a host
    fill the window in about a day. `coveredUntil` is the end of the day once it is
    complete and the minute of the run before that. `missingHours` are the hours already
    over in which the whole log, not only this hostname, has no line at all: a gap in the
    log rather than a quiet hour.
  - Hostnames: `RequestHost` in lower case without a port. Lines without a `RouterName`
    are not counted, nor lines of a router of Traefik's own (a name ending in `@internal`,
    such as the redirect from port 80, which answers every hostname), and neither are
    hostnames that do not match
    `^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$`, bare IPv4
    addresses and names over 246 characters (the file name has to fit). A day counts at
    most 1000 hostnames, in the order they first appear; the lines of the others are not
    counted. At most 50 hostnames are written, the most page views over the window first
    (then requests). A hostname's `days` start at the first day it has a line, and a day
    counted after that without one is all zeros. The file of a hostname that has no line left in the window,
    or is no longer among the 50, is removed.
  - Figures: `requests` is every counted line. A page view is a GET answered with 2xx or
    304 for a path shaped like a page (no extension in the last segment, a trailing slash,
    or `.html`), except `/health`, `/health/`, `/_astro/`, `/assets/`, `/.well-known/`,
    `/cdn-cgi/`, `/api/` and `/internal/`, and paths starting with `/robots.txt`,
    `/sitemap` or `/favicon`. A page view from a bot (an empty User-Agent, or one naming a
    crawler, an HTTP library, a scanner or a monitoring service) is counted in
    `botPageViews` and nowhere else. A visitor is one client address with one User-Agent
    that has a page view that day; the 24 `newVisitors` add up to the day's `visitors`, and
    so do the four `devices`. Visitors are not matched up across days. The client address
    is `ClientHost` (else `ClientAddr`); when it is a comma-separated list (X-Forwarded-For
    trusted from a CDN, whose front part the client writes), only the last value is used.
    Behind two trusted proxies in a row that last value is the first proxy's address, so
    the visitors coming through one of its servers are counted as fewer than they are. The
    User-Agent is cut to 512 characters before it is used. Paths lose the query; segments
    of digits only, shaped like a UUID or holding a token (a run of 20 or more ASCII
    letters and digits with both in it, or of 16 or more hexadecimal digits; words joined
    by hyphens such as `top-10-best-cameras-2026` stay) become `:id`, segments holding `@`
    (or `%40`) become `:redacted`, and a path over 300 characters or with a control
    character (Unicode's Cc category: U+0000 to U+001F and U+007F to U+009F, the range
    the console refuses) is counted in `pagesOther`, and so is a path first seen after the
    hostname's day already has 5000 paths. Paths are as the client sent them: percent
    encoding is not decoded.
  - No client address and no User-Agent is passed on, nor anything derived from them that
    could tell one client from another. Both are read only inside the counting process;
    these files, `.state/traffic/` and the output of the run hold counts and paths only.
  - A change to the counting rules raises `rulesVersion` (now 2). The kept days are then
    thrown away and the window is counted again, 7 days a run.
  - `state/traffic/` itself is created by every run that writes into `sync/`, so a host
    that has `make update` but not yet `make host-apply` has the directory with no file in
    it.
- `sync/ops/` is the other direction. The console writes `req-<id>.json`
  (`kind` = `ban`, `timer` or `reboot`), the host executes it during `host-sync` and writes
  `res-<id>.json` beside it; the console deletes both once it has taken the result in. A
  request that already has a result is never run again. What an operation may touch is
  decided on this side (`is_managed_unit`), never by the request.
- Permissions: `state/` and `state/traffic/` are 755 with 644 files (the console mounts
  them read-only), `ops/` is 777 with 666 files, because the console container writes
  there as a different user. The timers run as root and restore ownership after writing,
  the same way `render-config.sh` does for the generated config.
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

`EDGE_TLS_MODE` (`letsencrypt` or `origin-ca`) and `EDGE_CROWDSEC` (`auto` or `off`)
select what the stack is made of. Their defaults (`letsencrypt`, `auto`) are what the host
did before the keys existed. CrowdSec runs only when both allow it: with `auto` it
follows the TLS mode (runs with `letsencrypt`, not with `origin-ca` behind Cloudflare),
and `off` stops it on any host. There is no `on`, because no host needs it behind
Cloudflare. The scripts that care read the keys through `scripts/mode-lib.sh`, which is
also where the defaults, the derivation and the accepted values are defined once.

- `origin-ca` means the certificates are the files in `certs/` (Cloudflare Origin CA, 15
  years, placed by hand). `render-config.sh` lists them in
  `traefik/dynamic/generated-tls.yml` and filters ACME out of the static config. Port 80
  and the redirect to HTTPS are unchanged, so the only difference is where a certificate
  comes from. The ACME store is left in place, which is what makes going back one key.
- No CrowdSec (`origin-ca`, or `EDGE_CROWDSEC=off`) means no CrowdSec container and no
  bouncer in the entrypoint's default middlewares. Rate limiting, the concurrency limit
  and the security headers are Traefik's own and are unaffected. The blocking report
  timer is not installed and `bans.json` is not published, so nothing reports a guard
  that is not running.

Both filters run over the already substituted static config and check their own result, so
a template edit that moves the lines they look for fails the render instead of producing a
proxy that serves the wrong thing.

## Updates (this repo does not push itself)

**There is no deploy mechanism from edge to a host, and no CI workflow in this repo.** The
only update path runs on the host: `make update` does `git fetch`, then
`git reset --hard origin/$DEPLOY_BRANCH`, then `scripts/deploy-host.sh`. That script
renders the config and runs `compose up -d`. Routing and middlewares are watched by
Traefik, so no restart is needed for them. A container is recreated when its definition
changed (a new pinned Traefik version arrives this way) and restarted when the static
config (`traefik/traefik.yml`, `crowdsec/`) changed.

Changes under `/etc` and to systemd units require `make host-apply`, run by hand. The
same goes for a step newly added to `scripts/host-apply.sh` (the swapfile, for example):
a running host gets it from `make update` followed by one `make host-apply`.

Hosts that should follow automatically enable `edge-update.timer`, which runs
`make update` daily at 05:00 (Asia/Tokyo). The unit is installed by `make host-apply`, but
enabling it is a manual `systemctl enable --now`.

For bringing up a new host see `README.md`, for the command list and where each command
runs see `docs/commands.md`, and for the blocking design see
`docs/abuse-blocking-design.md`.
