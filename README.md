# edge

The host layer for a single server, shipped as one repo. Every host runs the same
contents of this repo and clones it as-is. It is not a template, so there are no
placeholders to substitute. Everything that differs per host lives in
`.env`, which is not tracked by git.

What is in here:

| Path                                            | Role                                                                        |
| ----------------------------------------------- | --------------------------------------------------------------------------- |
| `docker-compose.yml`                            | Traefik v3 (80/443, ACME) and CrowdSec, both joining a shared network       |
| `traefik/`                                      | Static config template plus the host-wide dynamic config (TLS, middlewares) |
| `crowdsec/`                                     | Acquisition (Traefik access log) and the collections to enable              |
| `systemd/` `logrotate/` `auto-patch/` `sysctl/` | Host maintenance timers, log rotation, OS auto-updates, swap unit + tuning  |
| `scripts/`                                      | Setup, deploy, notification and blocking operations                         |

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
   `make setup`: shared network, rendered config, Traefik + CrowdSec, then a swapfile
   with its boot unit and swappiness setting (see "Swap" below), the `/etc` files and
   systemd timers (log rotation, OS auto-updates, pending reboot check, blocking report,
   certificate expiry report, disk usage record, host sync). The auto-follow timer
   (`edge-update`) is installed but deliberately left disabled.

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

## Swap

`make host-apply` (and so `make setup` on a new host) gives the host a swapfile, so a
memory spike pushes pages out to disk instead of ending with the OOM killer taking a
process down. It is there for the host itself and the edge containers. Keeping
application containers off swap is up to their own compose files (for example
`memswap_limit` equal to `mem_limit`); edge does not touch them. `scripts/setup-swap.sh`
does the work; this section is where its rules and the reasons for them are kept.

### Size and disk space

`/swapfile` is as large as the host's memory (`MemTotal`), rounded up to a whole GiB and
kept between 1 GiB and 4 GiB. There is no `.env` key for it.

- Rounded up because `MemTotal` reads a little under the instance's nominal size (a
  2 GiB instance reports about 1.9 GiB), so the result matches the instance size.
- As much as memory: swap here only has to hold a spike until it passes or someone
  looks, and when every application container's compose file sets `memswap_limit` (see
  above) only the host processes and the edge containers swap at all, so one memory's
  worth is ample without taking much disk. A container whose compose file does not set it
  swaps as well, by Docker's default: as much as its `mem_limit` when it has one, and as
  much as the host has when it has none.
- At least 1 GiB, so the smallest instances still get a margin worth having.
- At most 4 GiB: a host that would fill more than that is short of memory and would be
  crawling on disk long before it used it all; give it a bigger instance instead.

The swapfile may leave the root filesystem at most 75% used. The ops console's hourly
disk check warns at 80%, and the 5 points in between are room for the logs and images
that grow day to day, not a guarantee: the check is made once, when the file is created,
and on a new host that is before the applications are on it, so what they add later can
still take the disk past 80%, with the swapfile counted in.

- When the full size does not fit, it is cut down in whole GiB to the largest that does.
- When not even 1 GiB fits, nothing is created: a full disk stops every service, which is
  worse than having no swap. A warning goes to the ops console and the swap step still
  succeeds, since the warning already says what to do and a failure would only add a
  second warning about the same thing. Free up space or grow the root volume (and its
  filesystem), then run `make host-apply` again.
- No `/swapfile` is created on a host that already has other active swap.

The size is decided once, when the file is created. After resizing the instance, or after
making room on a disk that gave a smaller swapfile, recreate it (the run writes the file
again; see below for when to run it):

```
sudo swapoff /swapfile && sudo rm /swapfile && make host-apply
```

`swapoff` first reads every page in the swapfile back into memory. When the free memory
cannot take them, the OOM killer takes a service down to make room, or `swapoff` fails
with `ENOMEM` ("Cannot allocate memory") and leaves the file on; the `&&` then stops the
rest. Look at `free -m` before running it: the `used` figure on the `Swap:` line should
fit well within the `available` figure on the `Mem:` line. When it does not, wait until
swap use comes down, or run it at a time when the services can be restarted.

### Boot unit and swappiness

- `systemd/swapfile.swap` turns `/swapfile` on at boot. `make host-apply` installs and
  enables it whenever it has `/swapfile` on. It is a unit rather than an `/etc/fstab`
  line because a file of edge's own is replaced whole, like every other unit here, with
  nothing to tell apart from lines other people wrote.
- The unit is skipped at boot when `/swapfile` is not there, so a missing file fails
  nothing. A `/swapfile` that is there but cannot be turned on fails the unit, and the
  failure goes to the ops console through `notify-failure@`, as for every other edge
  unit. `notify-failure@` is installed by steps of `make host-apply` that come after the
  swap step (`setup-auto-patch` is the first of them). On a new host where
  `make host-apply` stopped before them, a failure at boot stays in the journal and
  reaches no one until a run gets past them.
- `vm.swappiness = 10` comes from `sysctl/99-zz-swap.conf`: swap is a safety margin, so
  the kernel drops page cache first and swaps only under real memory pressure (the file
  explains the value). It is installed and loaded together with the unit.
- Both files are taken out again only when `/swapfile` is gone and `make host-apply`
  does not create it again (the disk is short, or the host has other active swap): the
  tuning is written for this swapfile. On a host whose swap was set up some other way
  from the start they are never installed, and its swappiness is never touched.
- Taking the sysctl file out leaves the running value as it is. `vm.swappiness` stays at
  10 until the next boot: what it was before is not recorded, and writing the kernel
  default could override what another sysctl file sets. With no swap active the value
  has no effect; with other swap active, 10 goes on applying to that swap until the next
  boot. From then on the remaining sysctl files decide, or the kernel default (60) when
  none of them sets it.
- A line for `/swapfile` in `/etc/fstab` is left as it is. The unit edge installs takes
  precedence over the one systemd-fstab-generator makes from that line, so it is still
  edge's unit that turns the file on, but the generator also makes the unit a
  requirement of `swap.target` (unless the line has `nofail` or `noauto`). That holds
  even though edge's unit is only wanted: a `/swapfile` that cannot be turned on at boot
  then fails `swap.target` along with the unit. `make host-apply` prints a warning when
  it finds such a line; removing the line makes the swap optional again.

### When the swap step fails

It is the first step of `make host-apply`, so the swapfile is in place before
`setup-auto-patch` installs dnf-automatic: dnf reads the repository metadata into memory,
which on a host with 0.5-1 GiB can be enough to bring in the OOM killer. On a new host the
runtime install in `bootstrap-host.sh` and the stack that `init.sh` starts still come
before it, and go without swap.

A failure in it (a `/swapfile` that cannot be used, a failed write) does not fail the
run. The other steps work without swap, and what they lose on a small host is the margin
against the OOM killer during that install, which is not worth leaving log rotation, OS
auto-updates and the timers unapplied. A warning goes to the ops console, the other steps
are applied as usual and `make host-apply` still succeeds. On a new host a failure could
not keep the stack from starting either way, since `make setup` runs `make host-apply`
after `init.sh` has started it; it would only end `make setup` before its checks and
report a failed setup for a host that is otherwise complete. An interruption (Ctrl-C, a
dropped session) still stops the run, as at any other step. Fix the cause and run
`make host-apply` again.

### Writing the swapfile keeps the root volume busy

`dd` writes every block, which takes several seconds per GiB (tens of seconds at the
larger sizes) and can use the volume's whole write throughput for that long;
`oflag=direct` keeps it out of the page cache, not off the disk. On a host that is
serving traffic, run the `make host-apply` that creates it at a quiet time. A host that
is already running picks it up with one `make host-apply` after the update:

```
cd /app/edge
make update
make host-apply
```

Check the result with `swapon --show` and `sysctl vm.swappiness`.

### `/swapfile` belongs to edge

On an edge host the path `/swapfile` is edge's. `scripts/setup-swap.sh` recognises its
swapfile by that path alone, so a `/swapfile` made by hand is treated as edge's too:
`make host-apply` turns it on, whether or not the host has other active swap (the unit
turns it on at every boot anyway, and doing the same at once keeps the running host as it
will be after its next boot), installs `swapfile.swap` for it and applies the swappiness.
A `/swapfile` that is not a regular file holding a swap area (a directory, a symlink, a
file `mkswap` was never run on) makes the swap step fail without changing anything, with
a warning in the ops console. `/swapfile.tmp` is edge's as well: the swap step writes a
new swapfile under that name before moving it into place, and every run first removes a
file or symlink at that path as the leftover of a run that was killed outright.

- `sudo swapoff /swapfile` alone does not last: `swapfile.swap` turns it back on at the
  next boot, and the next `make host-apply` turns it on right away.
- Removing the file after `swapoff` does not last either while the disk has room and the
  host has no other active swap: the next `make host-apply` creates a new one. There is
  no setting that keeps an edge host without swap.
- Removing it without `swapoff` first leaves it on: the kernel keeps using the deleted
  file, and its disk space, until the host reboots, because `swapoff` finds a swap area
  by its path and the path is gone. `make host-apply` recognises this (`/proc/swaps`
  lists it as `/swapfile\040(deleted)`), leaves the unit and the swappiness as they are
  and says so, with a warning in the ops console; the swap step still succeeds. Run it
  again after the next reboot. It then goes on as on any host with
  no `/swapfile`, or with the new `/swapfile` when one has been put in place meanwhile.
- When `/swapfile` is gone and `make host-apply` does not create it again, it takes out
  `/etc/systemd/system/swapfile.swap` and `/etc/sysctl.d/99-zz-swap.conf` (see "Boot unit
  and swappiness" above, also for what happens to `vm.swappiness`). The unit goes only
  when its content is the same as `systemd/swapfile.swap` in this repo. One that differs
  (written or edited by hand, or installed from an earlier version of the file), or that
  cannot be compared, is left in place, and the run says so.
- Either of those two files replaced by a symlink is left alone: `make host-apply`
  neither writes through the link nor replaces or removes it, and does not enable or
  load what it points to. A link to `/dev/null` is a mask (`systemctl mask` makes one for
  a unit, and the same link masks a sysctl file). A masked unit keeps `/swapfile` off at
  boot only; the next `make host-apply` still turns it on. A link to any other file
  stands in for edge's file, and at boot systemd reads the file it points to.

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
 │  ├ disk-usage.json            usage per directory, plus large files directly under / (daily)
 │  ├ host.json                  facts about the host itself (the dashboard FQDN)
 │  └ metrics.json               memory, swap, load and CPU of the host and of each container
 └ ops/                      the console writes req-<id>.json, the host answers res-<id>.json
```

Snapshots are rewritten in full on every `host-sync` run through a `.tmp` file, so a
reader never sees half of one. `metrics.json` is a reading of that moment: memory and swap
from `/proc/meminfo`, the kernel's `vm.swappiness`, the load averages, CPU usage over one
second, and memory and CPU per running container from `docker stats`, each container with
the compose project and service it belongs to (its compose labels, read with `docker ps`;
null for a container compose did not create). Its swap counters are totals since boot, so
the console works out the change between two readings. A figure that cannot be read is
null and the rest is still written. When docker cannot be used at all (a hand-run by a
user outside the docker group, a daemon that is down or does not answer), the container
list is null and the host's own figures are still written: docker hangs most often when
memory runs short, which is when those figures matter most. A list means docker answered,
so an empty one means that no container is running. It names every running container and
its compose project and service, the applications' too; those names are read on the host
at run time and written only into this file.

Operation requests (unblock an IP, run a timer, schedule a reboot) are picked up by the
same run; a request whose `res-` file already exists is never run twice, and the console
deletes both files once it has taken the result in. Which units an operation may touch is
decided here (`is_managed_unit` in `scripts/report.sh`), not by whoever wrote the request.

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
