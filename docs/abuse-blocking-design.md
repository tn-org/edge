# Abuse blocking design

Detection is tuned to match real traffic, and every block is recorded permanently in the
ops console. CrowdSec decides what to block from the Traefik access log; the Traefik
bouncer plugin enforces it.

## Layout

```
request
  └─ Traefik (default middlewares on the websecure entrypoint)
       ├─ crowdsec-bouncer  ask the LAPI; return 403 while the IP is blocked
       ├─ security-headers
       ├─ ratelimit-default 429 above 30 r/s with a burst of 100
       └─ inflight-default  429 above 100 concurrent requests
  └─ access log (JSON, logs/traefik/access.log)
       └─ CrowdSec reads it and creates a decision when a scenario matches
```

- A block is a CrowdSec decision, stored in SQLite on the named volume `crowdsec-data`.
- Enforcement happens in Traefik middleware, so **only HTTP is affected**; packets are not
  dropped.
- The allowlist source of truth is `crowdsec/generated/allowlist.tsv`. It is converted
  into a parser-stage whitelist, so an allowlisted IP never produces a decision at all.

## 1. Detection

Three collections are enabled through `COLLECTIONS` in the compose file.

| Collection                          | What it catches                                                           |
| ----------------------------------- | ------------------------------------------------------------------------- |
| `crowdsecurity/traefik`             | Parser for the Traefik JSON log; without it nothing is analysed           |
| `crowdsecurity/base-http-scenarios` | 404 sweeps, fast crawling, suspicious user agents, credential brute force |
| `crowdsecurity/http-cve`            | Requests probing known CVEs                                               |

Thresholds come from the scenario definitions in the collections; they are not written out
again as local overrides. When a threshold turns out not to match reality, inspect it with
`cscli scenarios` and override that one scenario.

Block duration is whatever the scenario says (often four hours) plus 24 hours for manual
blocks. Keeping the maximum at about a day is deliberate: the record lives in the ops
console, so the block itself does not need to be long lived, and a false positive clears
within a day.

## 2. Recording blocks

The host writes the blocking state to `sync/state/bans.json`, a full snapshot rewritten on
every `host-sync` run, and the ops console reads it from there. The console appends to its
`ban_records` table and never deletes: the unique key is `(jail, ip, banned_at)`, and
"currently blocked" means `released_at is null` and `expires_at` in the future.

Unblock and allowlist requests come back the other way as `sync/ops/req-<id>.json` with
`kind: "ban"`. `report.sh bans-sync` runs each one through `ban.sh` — the same path as
`make ban` — and writes `res-<id>.json` beside it.

The field names date from a fail2ban implementation and are kept as
a stable contract. What used to be a jail name is now a CrowdSec scenario name such as
`crowdsecurity/http-probing`, and the operation names (`list`, `ban`, `unban`, `allow`,
`disallow`, `allowed`) are unchanged for the same reason.

One field means something slightly different from its name. `totalBanned` (a per-jail
lifetime counter in fail2ban) has no CrowdSec equivalent, so **the current number of blocks
is sent instead**. Long-term totals live in `ban_records`, which is what the console shows
as the lifetime count for an IP, so nothing is lost.

## 3. Rate limiting

| Limit       | Setting                                       |
| ----------- | --------------------------------------------- |
| Per second  | `rateLimit`: average 30, period 1s, burst 100 |
| Concurrent  | `inFlightReq`: amount 100                     |
| On overflow | 429                                           |

The thresholds sit well above measured legitimate use, and the burst allowance passes
normal page loads and parallel asset fetches straight through. There is no scenario that
escalates repeated 429s into a block; whether to add one is a decision for after the
numbers are in.

## 4. Guarding against false positives

- The allowlist (`make ban CMD=allow IP=…`). Put your own static addresses and any
  external uptime checker in it.
- Unblocking through the console is written to its audit log.
- The 08:00 daily report lists the last 24 hours of blocks broken down by scenario.

## Turning it off (`EDGE_CROWDSEC=off`)

A host can run without any of this: no CrowdSec container, and no bouncer in the default
middleware list of the websecure entrypoint. Everything else in the layout above is Traefik
middleware and stays — the rate limit, the concurrency limit and the security headers keep
applying to every router.

What goes with it is stated rather than faked: `report-bans.timer` is not installed,
`make ban` stops with the reason, and `bans-sync` publishes no `bans.json` and answers
queued console requests with an error, so the console shows no blocking state for the host
instead of an empty list. Being behind the Cloudflare proxy is not on its own a reason to
switch it off: the real client IP still arrives (`X-Forwarded-For`, trusted only from
Cloudflare's ranges), and a free Cloudflare plan blocks nothing by itself.

## Known gaps

- **SSH brute force is not blocked.** The Traefik bouncer only sees HTTP. Adding the
  `crowdsecurity/sshd` collection would produce decisions, but enforcing them needs a
  separate host firewall bouncer (iptables or nftables).
- **No packet-level blocking.** A blocked IP still completes the TCP connection and the TLS
  handshake and then receives a 403.

## Checking it works

```
docker compose exec crowdsec cscli metrics       # is the log being read? (acquisition rows)
docker compose exec crowdsec cscli decisions list
docker compose exec crowdsec cscli bouncers list # is traefik registered?
make bans                                        # same content as the daily report, display only
```

If the acquisition section of `cscli metrics` stays empty, the Traefik log format and the
`type: traefik` label in `acquis.yaml` do not match. CrowdSec keeps running happily in that
state, so check it by eye when setting a host up: silently failing to parse every line is
the worst failure mode here.
