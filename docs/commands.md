# make command reference

There is a single Makefile at the repo root. This repo owns the host layer only (Traefik,
CrowdSec, systemd, log rotation, OS auto-updates). The ops console belongs to the
application repo (`/app/<slug>/console` on the server) and documents its own commands.

**There are no domain or certificate commands.** Applications declare how they are exposed
through their Traefik labels, and Traefik's ACME resolver obtains the certificates.

Where a command may run is decided by `APP_ENV` in the root `.env` (`local` = workstation,
anything else = server). Running a server-only command locally fails immediately and
prints the correct one-line procedure. When a required argument is missing, the command
asks interactively if a tty is attached, and otherwise prints usage and exits 1 so that a
timer-driven run never hangs.

## Command table

### Stack

| Command        | Purpose                             | Arguments                                           | Runs on | Called by          |
| -------------- | ----------------------------------- | --------------------------------------------------- | ------- | ------------------ |
| `make up`      | Start Traefik and CrowdSec          | —                                                   | both    | manual, setup.sh   |
| `make down`    | Stop Traefik and CrowdSec           | —                                                   | both    | manual             |
| `make restart` | Restart Traefik and CrowdSec        | —                                                   | both    | manual             |
| `make ps`      | Show status                         | —                                                   | both    | manual, setup.sh   |
| `make logs`    | View logs                           | `TARGET=access\|container` `[DOMAIN=]` `[SERVICE=]` | both    | manual             |
| `make render`  | Apply `.env` values to config files | —                                                   | both    | up, deploy-host.sh |

- `logs TARGET=access` tails the single Traefik JSON access log. `DOMAIN=` narrows it to
  one destination; there are no per-domain log files.
- `render` writes `traefik/generated/` (static config, LAPI key) and
  `crowdsec/generated/` (allowlist). None of it is tracked by git.
- No reload command is needed to apply config. Routing follows docker events and
  `traefik/dynamic/` is watched for file changes.

### Updates

| Command       | Purpose                                                | Arguments          | Runs on | Called by                            |
| ------------- | ------------------------------------------------------ | ------------------ | ------- | ------------------------------------ |
| `make update` | Follow origin and apply the host layer (git + compose) | `[DEPLOY_BRANCH=]` | server  | manual, edge-update.timer (optional) |

This repo has no mechanism to push itself onto a host. Updates happen on the host with
`make update` (`git fetch --all --prune`, `git reset --hard origin/$DEPLOY_BRANCH`, then
`scripts/deploy-host.sh`). `DEPLOY_BRANCH` defaults to `main`. `deploy-host.sh` renders
the config and runs `compose up -d --remove-orphans`, recreating containers only when the
static config (`traefik/traefik.yml`, `crowdsec/`) changed. Changes under `/etc` and to
systemd units are not included; run `make host-apply` by hand for those.

Automatic following is `edge-update.timer` (daily at 05:00 Asia/Tokyo). The unit is only
installed by `make host-apply`; enable it once per host with
`sudo systemctl enable --now edge-update.timer`.

### Monitoring and maintenance

| Command             | Purpose                                                 | Arguments                                                  | Runs on | Called by                           |
| ------------------- | ------------------------------------------------------- | ---------------------------------------------------------- | ------- | ----------------------------------- |
| `make host-apply`   | Apply host config (log rotation, timers)                | —                                                          | server  | manual, setup.sh                    |
| `make ban`          | Block and allowlist operations (interactive by default) | `[CMD=list\|ban\|unban\|allow\|disallow\|allowed]` `[IP=]` | server  | manual, requests from the console   |
| `make bans`         | Show blocking status (display only, no notification)    | —                                                          | server  | manual                              |
| `make docker-prune` | Remove unused docker images                             | —                                                          | server  | manual (weekly: docker-prune.timer) |

- `ban CMD=ban` blocks for 24 hours by default. Override with
  `BAN_DURATION=72h make ban CMD=ban IP=…`.
- `allow` and `disallow` rewrite the allowlist (`crowdsec/generated/allowlist.tsv`) and
  restart CrowdSec, which takes a few seconds. An allowlisted IP is never considered for
  blocking in the first place.
- The operation names come from the fail2ban era and are kept, because the `action` field
  of the requests queued by the console uses them.

### Environment and first run

| Command      | Purpose                                                 | Arguments                                          | Runs on | Called by                                    |
| ------------ | ------------------------------------------------------- | -------------------------------------------------- | ------- | -------------------------------------------- |
| `make env`   | Configure `.env` (interactive, or set one key directly) | `[KEY= VALUE=]` `[CMD=check]` (check is read-only) | both    | manual                                       |
| `make setup` | Full first-run wizard (repeatable, idempotent)          | —                                                  | both    | manual (on a server it initialises the host) |

Four keys need a value on a fresh host: `APP_ENV`, `ACME_EMAIL`, `INTERNAL_TOKEN` and
`CROWDSEC_BOUNCER_KEY`. `EDGE_NETWORK` and `OPS_NOTIFY_URL` can stay at their defaults
(the full key list is in `README.md`).

- `CROWDSEC_BOUNCER_KEY` is the shared secret between the Traefik bouncer and CrowdSec.
  Generate it with `openssl rand -hex 32` and put it in `.env`; compose then registers it
  with CrowdSec as a bouncer named `traefik` at startup, so `cscli bouncers add` is never
  needed by hand. If a different key is already registered, run
  `cscli bouncers delete traefik` and start again.
- `INTERNAL_TOKEN` is one value shared by this host's applications, ops console and host
  layer.
- If you change `EDGE_NETWORK`, change it in every application's `.env` on that host too.
  It is the real network name, so changing one side breaks connectivity.

## Scheduled jobs (times are Asia/Tokyo)

Everything on the host that runs without a human. Jobs run by the scheduler inside the ops
console container are listed by the console repo instead, and the combined live list is
visible in the console under scheduled tasks. Names do not spell out "daily" or "weekly",
since the interval column already says so.

| Time         | Name                                                         | Runner  | Configured by                                     | Result                     |
| ------------ | ------------------------------------------------------------ | ------- | ------------------------------------------------- | -------------------------- |
| Daily 04:00  | OS security auto-update                                      | systemd | dnf-automatic.timer (setup-auto-patch.sh)         | Mail on failure            |
| Daily 05:00  | edge update (git follow, compose apply; disabled by default) | systemd | edge-update.timer (setup-update.sh)               | Mail on failure            |
| Daily 08:00  | Abuse blocking record                                        | systemd | report-bans.timer (setup-bans.sh)                 | Mail on failure            |
| Daily 08:20  | Pending reboot check (repeats daily while a reboot is due)   | systemd | report-reboot-check.timer (setup-reboot-check.sh) | Mail on the days it is due |
| Daily 08:30  | Disk usage per directory                                     | systemd | report-disk-usage.timer (setup-disk-usage.sh)     | Mail on failure            |
| Every 5 min  | Host state sync and operation execution                      | systemd | host-sync.timer (setup-host-sync.sh)              | Mail on failure            |
| Sunday 06:00 | Remove unused docker images                                  | systemd | docker-prune.timer (setup-docker-prune.sh)        | Mail on failure            |

`edge-update` is the only one disabled by default. It runs only on hosts where somebody
ran `sudo systemctl enable --now edge-update.timer`. There is no mechanism that deploys to
this host from the outside, and this repo contains no CI workflows.

Certificate renewal and persisting the block list are not on the list because they no
longer need a timer: Traefik's ACME resolver renews certificates before they expire, and
blocks live in the CrowdSec database on a named volume.

Three ways a result reaches you:

- **Mail every time**: only the daily system report (sent by the ops console). A day
  without it means the delivery path or the scheduler is broken.
- **Mail on failure**: errors and warnings turn into mail as soon as they reach the system
  log. Silence means everything is fine.
- **Console only**: it just stays in the console's system log.

Assumptions about systemd:

- Everything runs on the host with `Persistent=true` and a `RandomizedDelaySec`, so runs
  missed while the machine was off are caught up at the next boot. Failures are picked up
  by `notify-failure@` and forwarded to the notification hub.
- Installation is a one-time manual step (`scripts/setup-*.sh`, or all at once through
  `make setup` / `make host-apply`).

Timers that ship with the OS (man page indexing, locate database updates and the like) are
not listed. The host side (`emit_unit` in `report.sh`) filters the list down to the units
this repo operates. `logrotate` is included even though the unit belongs to the OS,
because the configuration comes from here.
