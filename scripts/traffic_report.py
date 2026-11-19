#!/usr/bin/env python3
"""Count the Traefik access log per hostname and Japanese day for the ops console.

`report.sh traffic` runs this every hour (report-traffic.timer). It writes one file per
hostname, sync/state/traffic/<host>.json, which the console's user analytics screen reads,
and keeps every day it has counted in a cache directory of its own (.state/traffic/ on a
host), so that a day that is over is not counted again. The shape of the files is a
contract with the console (see "Contract with the ops console" in docs/architecture.md);
the rules for every figure are here, under "Counting rules".

What leaves this process is counts and paths, nothing else. The client address and the
User-Agent are read to tell visitors apart and to sort out bots and devices. Neither of
them, nor anything derived from them that could tell one client from another, is written
to the files for the console, to the cache or to the output of the run.

Telling visitors apart takes memory for each of them, and a client can make up a new
User-Agent on every request, so it is capped (MAX_DAY_TRACKED and MAX_RUN_TRACKED under
"Limits"). A hostname's day that reaches a cap is written with visitorsCapped: its page
views stay exact and its visitor figures are lower than they really are. The run still
succeeds. The paths kept for the lists of pages are capped as well, per hostname and day
and over the whole run (MAX_DAY_PAGES and MAX_RUN_PAGES), since a site answering every
path with 200 lets a client make up paths too: a path first seen after a cap is reached is
counted in pagesOther instead of being listed. That lowers no figure, so the day is not
marked.

Standard library only, written for Python 3.9 (the python3 of Amazon Linux 2023).

Usage:
  traffic_report.py --log-dir DIR --out-dir DIR --cache-dir DIR [--now 2026-11-18T05:07:41Z]

--now stands in for the current time, so that a run over a set of made-up logs can be
repeated with the same result.
"""

import argparse
import calendar
import datetime
import fcntl
import gzip
import json
import os
import re
import sys
import zlib

# ---- Versions ------------------------------------------------------------------------

# The shape of state/traffic/<host>.json, part of the contract with the console
FILE_VERSION = 1
# How lines are counted: what a page view, a bot, a visitor and a device are, and how
# paths are rewritten (everything under "Counting rules" below). Raise it whenever one of
# those rules changes. The kept days were counted under the old rules, so they are thrown
# away and the window is counted again from the logs, BACKFILL_DAYS_PER_RUN days per run.
RULES_VERSION = 2
# The shape of the kept days in the cache directory (only this script reads them)
CACHE_VERSION = 1

# ---- Days ----------------------------------------------------------------------------

TIMEZONE = "Asia/Tokyo"
# Japan has kept no daylight saving time since 1951, so the zone is a fixed offset and no
# time zone database is needed.
TZ_OFFSET = 9 * 3600
HOUR = 3600
DAY = 86400
EPOCH_DATE = datetime.date(1970, 1, 1)
# Today and the 189 days before it. The console compares 90 days with the 90 before them,
# which needs 181; the rest is margin.
WINDOW_DAYS = 190
# A day is closed ("complete") once it has been over for this long and every log file
# that may hold it was read. A request is logged when it ends, so the lines of the
# requests still running at midnight arrive after it.
CLOSE_AFTER = HOUR
# Days before yesterday that have not been counted yet are filled in at most this many per
# run, newest first. On a host with a year of logs the first runs therefore fill the
# window over about a day of hourly runs, instead of one run reading half a year of logs.
BACKFILL_DAYS_PER_RUN = 7

# ---- Limits --------------------------------------------------------------------------

# Hostnames written per run, the busiest first (page views, then requests, over the window)
MAX_HOSTS = 50
# Hostnames counted per day while the lines are read. The lines of a hostname first seen
# after the day already has this many are counted in the "hostname that is not counted"
# figure of the run instead, so that made-up Host headers cannot make the run grow.
MAX_DAY_HOSTS = 1000
# Pages listed per day; the rest is added up in pagesOther
TOP_PAGES = 50
# Paths counted while the lines are read, per hostname and day (MAX_DAY_PAGES) and over
# every hostname and day counted in one run (MAX_RUN_PAGES). A path first seen after its
# day already has MAX_DAY_PAGES of them, or after the run has MAX_RUN_PAGES, goes to
# pagesOther, so that requests for made-up paths (a site answering every path with 200)
# cannot make the run grow. The cap of the day alone would not do: every path kept holds
# its own copy of the path and an empty set for its visitors, so the paths of the run would
# still grow with the number of hostnames and days it counts. The page views of such a
# path are counted exactly in pagesOther, and its visitors among those of pagesOther (under
# MAX_DAY_TRACKED and MAX_RUN_TRACKED like any other), so the day is not marked for it; the
# run's output says when the cap of the run was reached.
MAX_DAY_PAGES = 5000
MAX_RUN_PAGES = 60_000
MAX_PATH_LENGTH = 300
# The hostname is the file name, and "<host>.json.tmp" has to fit in 255 bytes
MAX_HOST_LENGTH = 255 - len(".json.tmp")
# User-Agents are cut to this many characters before they are used (to sort out bots and
# devices, and to tell visitors apart), so that a long one cannot make the lookup below
# grow. A browser's stays well under it.
MAX_AGENT_LENGTH = 512
# Lookups kept between lines (hostnames, User-Agents), dropped and started again when full.
# A RequestHost longer than LOOKUP_KEY_LENGTH is not kept and is worked out again on each
# line, for the same reason.
LOOKUP_LIMIT = 50000
LOOKUP_KEY_LENGTH = 512
# Entries kept in memory to tell visitors apart. One entry is one visitor added to the
# visitors of a hostname's day, to those of one of its hours, of one of its listed paths or
# of pagesOther. A visitor is a client address with a User-Agent, and anyone can send a new
# User-Agent with every request, so without a cap a flood of such requests would grow
# these sets until the run is killed for its memory (MemoryMax=300M and MemorySwapMax=0 in
# report-traffic.service). The day would then never be written, and every later run would
# pick it again and fail the same way. A hostname's day that cannot add the entries of a
# page view under either cap adds none from then on: it keeps the ones it has, goes on
# counting its page views and requests exactly, and is written with visitorsCapped, its
# visitor figures lower than they really are. The run still succeeds.
# tests/test_traffic_report.py measures the memory these sets and the listed paths take at
# the caps of the run.
# Per hostname and day. An eighth of the run's, so that a flood on one or two hostnames, on
# today and yesterday, leaves most of the run's entries to the other hostnames and days.
MAX_DAY_TRACKED = 100_000
# Over every hostname and day counted in one run
MAX_RUN_TRACKED = 800_000
# Hostname days named in the output of a run when some reached a cap; the rest are counted
CAPPED_LISTED = 5

# ---- Log files -----------------------------------------------------------------------

# traefik/traefik.yml writes /var/log/traefik/access.log, which is logs/traefik/access.log
# on the host. logrotate/traefik rotates it daily with dateext (-%Y%m%d), strips the query
# out of the plain rotated file and compresses it one rotation later (delaycompress). So
# the directory holds access.log, access.log-YYYYMMDD (the newest rotated one) and
# access.log-YYYYMMDD.gz. The date in a name is the day logrotate ran, in the host's time
# zone; nothing here relies on it beyond sorting the files.
LOG_NAME = "access.log"
ROTATED_NAME = re.compile(r"access\.log-([0-9]{8})(\.gz)?")
# Lines read from the top of each file to tell roughly which hours it holds
HEAD_LINES = 200
# How far a line's StartUTC can sit outside the span worked out for its file. A request is
# logged when it ends, so a long one (a download, a websocket) lands in a file that began
# after it started.
SPAN_MARGIN = 2 * HOUR
# What reading a broken or half-written file raises (gzip.BadGzipFile is an OSError)
READ_ERRORS = (OSError, EOFError, zlib.error)

# ---- Counting rules (RULES_VERSION) ----------------------------------------------------

# Routers of Traefik's own end in this. They are not a site: the redirect from port 80 to
# 443 (web-to-websecure@internal) answers every hostname, so counting its lines would give
# a made-up Host header a hostname of its own. Their lines are not counted, the same as
# lines without a router.
INTERNAL_ROUTER_SUFFIX = "@internal"

# Hostnames: RequestHost, lower-cased and without a port. It becomes a file name on the
# console's side, so only this shape is counted.
HOST_SHAPE = re.compile(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*")
# A bare IPv4 address fits the shape above. It is not a site (scanners send the server's
# own address as the Host header), and no address is ever written out, so it is not counted.
IPV4_SHAPE = re.compile(r"[0-9]{1,3}(\.[0-9]{1,3}){3}")

# A page view is a GET answered with 2xx or 304 for a path shaped like a page: no
# extension in the last segment, a trailing slash, or .html. These paths never count,
# whatever their shape.
EXCLUDED_PATH = "/health"
EXCLUDED_PREFIXES = (
    "/health/",
    "/_astro/",
    "/assets/",
    "/.well-known/",
    "/cdn-cgi/",
    "/api/",
    "/internal/",
    "/robots.txt",
    "/sitemap",
    "/favicon",
)

# Bots: an empty User-Agent, or one that contains any of these (compared in lower case).
# Their page views are counted in botPageViews and nowhere else.
BOT_TOKENS = (
    "bot",
    "crawl",
    "spider",
    "slurp",
    "preview",
    "facebookexternalhit",
    "curl",
    "wget",
    "python",
    "go-http-client",
    "headless",
    "lighthouse",
    "route53-health-check",
    "uptime",
    # More clients that are never a person at a browser: HTTP libraries, scanners and
    # monitoring services that do not call themselves bots
    "http-client",
    "httpclient",
    "okhttp",
    "axios",
    "node-fetch",
    "java/",
    "libwww",
    "scrapy",
    "phantomjs",
    "zgrab",
    "masscan",
    "nmap",
    "censys",
    "pingdom",
    "statuscake",
)
BOT_PATTERN = re.compile("|".join(re.escape(token) for token in BOT_TOKENS))
BOT = -1

# Devices, in the order of the "devices" object. A visitor is one client address with one
# User-Agent, so every visitor has exactly one device.
DEVICE_KEYS = ("mobile", "desktop", "tablet", "other")
MOBILE, DESKTOP, TABLET, OTHER = range(4)

# Path segments rewritten before paths are compared: ids and tokens, and anything that may
# be an e-mail address or a handle (@, also when percent-encoded)
NUMERIC_SEGMENT = re.compile(r"[0-9]+")
UUID_SEGMENT = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)
# Tokens (password resets, e-mail confirmations, invitations, signed links), which would
# otherwise stay in the listed paths: a segment holding a run of 20 or more ASCII letters
# and digits with both in it (TOKEN_RUN), or a run of 16 or more hexadecimal digits
# (HEX_RUN), becomes :id. For example
#   /reset-password/<64 hexadecimal digits>  -> /reset-password/:id
#   /invite/Gh7kQ2xZp9LmT4vB8nR1             -> /invite/:id
#   /verify/mail-0123456789abcdef            -> /verify/:id
# while words joined by hyphens, and long words, stay as they are:
#   /blog/top-10-best-cameras-2026           (no run is that long)
#   /docs/internationalization-guide         (letters only)
TOKEN_RUN = re.compile(r"[A-Za-z0-9]{20,}")
HEX_RUN = re.compile(r"[0-9A-Fa-f]{16,}")
# Control characters: every code point of Unicode's Cc category (U+0000 to U+001F and
# U+007F to U+009F), the same range the console checks. A listed path holding one would
# make the console refuse the whole day, so such a path goes to pagesOther.
CONTROL_CHARACTER = re.compile(r"[\x00-\x1f\x7f-\x9f]")

# ---- Time ----------------------------------------------------------------------------

# Traefik writes StartUTC as RFC 3339 with nanoseconds ("2026-11-18T05:07:41.123456789Z").
# datetime.fromisoformat cannot read that before Python 3.11, so it is read here.
STAMP = re.compile(
    r"([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?"
    r"(Z|[+-][0-9]{2}:[0-9]{2})"
)
START_KEY = '"StartUTC":"'


def parse_stamp(text):
    """Seconds since the epoch for an RFC 3339 time with a zone; None when unreadable."""
    if not isinstance(text, str):
        return None
    match = STAMP.fullmatch(text)
    if not match:
        return None
    year, month, day, hour, minute, second = (int(v) for v in match.groups()[:6])
    if not (1 <= month <= 12 and 1 <= day <= 31 and hour <= 23 and minute <= 59 and second <= 60):
        return None
    epoch = calendar.timegm((year, month, day, hour, minute, second, 0, 0, 0))
    zone = match.group(7)
    if zone != "Z":
        offset = int(zone[1:3]) * 3600 + int(zone[4:6]) * 60
        epoch += -offset if zone[0] == "+" else offset
    return epoch


def quick_start(line):
    """StartUTC of a line without parsing the whole of it; None when it cannot be found.

    Most lines read belong to a day this run does not count, and this lets them be skipped
    before json.loads. JSON escapes every quote inside a value, so the key cannot be
    mistaken for part of a path or a header.
    """
    at = line.find(START_KEY)
    if at < 0:
        return None
    at += len(START_KEY)
    end = line.find('"', at)
    if end < 0:
        return None
    return parse_stamp(line[at:end])


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).isoformat()


def day_of(epoch):
    """Japanese day of a time, as days since 1970-01-01."""
    return (epoch + TZ_OFFSET) // DAY


def day_start(index):
    """Start of a Japanese day, in seconds since the epoch."""
    return index * DAY - TZ_OFFSET


def day_name(index):
    return (EPOCH_DATE + datetime.timedelta(days=index)).isoformat()


def day_index(name):
    return (datetime.date.fromisoformat(name) - EPOCH_DATE).days


# ---- Counting rules: functions ---------------------------------------------------------


def host_of(raw):
    """The hostname a line is counted under, or None when it is not counted."""
    if not isinstance(raw, str):
        return None
    host = raw.strip().lower()
    name, colon, port = host.rpartition(":")
    if colon and port.isascii() and port.isdigit():
        host = name
    if len(host) > MAX_HOST_LENGTH or not HOST_SHAPE.fullmatch(host):
        return None
    if IPV4_SHAPE.fullmatch(host):
        return None
    return host


def is_page(path):
    """Is this path (query already dropped) shaped like a page, and not excluded?"""
    if not path.startswith("/"):
        return False
    if path == EXCLUDED_PATH or path.startswith(EXCLUDED_PREFIXES):
        return False
    last = path[path.rfind("/") + 1:]
    # An empty last segment is a path ending in "/"
    if "." not in last:
        return True
    return last.lower().endswith(".html")


def has_token(part):
    """Does this path segment hold something shaped like a token (see TOKEN_RUN)?"""
    if HEX_RUN.search(part):
        return True
    for match in TOKEN_RUN.finditer(part):
        run = match.group()
        if not (run.isalpha() or run.isdigit()):
            return True
    return False


def page_key(path):
    """The path a page view is listed under, or None for pagesOther."""
    parts = path.split("/")
    for i, part in enumerate(parts):
        if not part:
            continue
        if NUMERIC_SEGMENT.fullmatch(part) or UUID_SEGMENT.fullmatch(part) or has_token(part):
            parts[i] = ":id"
        elif "@" in part or "%40" in part.lower():
            parts[i] = ":redacted"
    key = "/".join(parts)
    if len(key) > MAX_PATH_LENGTH or CONTROL_CHARACTER.search(key):
        return None
    return key


def device_of(agent):
    """Device of a lower-cased User-Agent that is not a bot."""
    # Tablets first: an iPad says "Mobile" too, and an Android tablet does not.
    if "ipad" in agent or "tablet" in agent or "kindle" in agent or "silk/" in agent:
        return TABLET
    if "android" in agent:
        return MOBILE if "mobile" in agent else TABLET
    if (
        "mobi" in agent
        or "iphone" in agent
        or "ipod" in agent
        or "windows phone" in agent
        or "blackberry" in agent
        or "opera mini" in agent
    ):
        return MOBILE
    # An iPad on iPadOS 13 or later asks for the desktop site and says Macintosh, so it is
    # counted here; nothing in the User-Agent tells it apart.
    if "windows" in agent or "macintosh" in agent or "x11" in agent or "linux" in agent:
        return DESKTOP
    return OTHER


def agent_kind(agent):
    """BOT, or the device of a person's browser."""
    lower = agent.lower()
    if not lower.strip() or BOT_PATTERN.search(lower):
        return BOT
    return device_of(lower)


# ---- Counting ------------------------------------------------------------------------


class HostDay:
    """One hostname on one day while its lines are counted."""

    __slots__ = (
        "requests",
        "page_views",
        "bot_page_views",
        "hour_views",
        "hour_visitors",
        "visitors",
        "pages",
        "other_views",
        "other_visitors",
        "tracked",
        "capped",
    )

    def __init__(self):
        self.requests = 0
        self.page_views = 0
        self.bot_page_views = 0
        self.hour_views = [0] * 24
        # 24 sets of visitors, made on the first page view
        self.hour_visitors = None
        # visitor -> first hour * 4 + device. A visitor is Python's own hash of the client
        # address and the User-Agent, which only means something inside this process.
        self.visitors = {}
        # path -> [page views, set of visitors], at most MAX_DAY_PAGES paths (and
        # MAX_RUN_PAGES over every day of the run)
        self.pages = {}
        self.other_views = 0
        self.other_visitors = set()
        # Entries in visitors, hour_visitors, the paths' sets and other_visitors (see
        # MAX_DAY_TRACKED), and whether a page view could not add its own under a cap
        self.tracked = 0
        self.capped = False

    def page_view(self, hour, visitor, device, path, stats):
        """Count one page view; stats holds the entries and paths added over the whole run."""
        # Page views are counted exactly, whether or not the visitor can still be added
        self.page_views += 1
        self.hour_views[hour] += 1
        page = None if path is None else self.pages.get(path)
        if page is None and path is not None and len(self.pages) < MAX_DAY_PAGES:
            if stats.paths < MAX_RUN_PAGES:
                page = self.pages[path] = [0, set()]
                stats.paths += 1
            else:
                stats.paths_capped = True
        if page is None:
            # pagesOther: a path that is not listed, or a new one once the day has
            # MAX_DAY_PAGES of them or the run MAX_RUN_PAGES
            self.other_views += 1
            seen = self.other_visitors
        else:
            page[0] += 1
            seen = page[1]
        if self.capped:
            return
        if self.hour_visitors is None:
            self.hour_visitors = [set() for _ in range(24)]
        hour_seen = self.hour_visitors[hour]
        known = self.visitors.get(visitor)
        added = (known is None) + (visitor not in hour_seen) + (visitor not in seen)
        if not added:
            return
        if self.tracked + added > MAX_DAY_TRACKED or stats.tracked + added > MAX_RUN_TRACKED:
            # From here on the visitors of this day stay as they are (see MAX_DAY_TRACKED)
            self.capped = True
            return
        self.tracked += added
        stats.tracked += added
        hour_seen.add(visitor)
        seen.add(visitor)
        # The first hour is the earliest one, whatever order the lines come in: a request
        # is logged when it ends, and the files are not read in the order they were written.
        # A visitor first seen later is new to this hour's set, so the move comes after the
        # caps: the hour a visitor is new in is always an hour the visitor is counted in.
        if known is None or (known >> 2) > hour:
            self.visitors[visitor] = hour * 4 + device

    def result(self):
        """The figures of the day, in the shape of one entry of "days" (counts and paths)."""
        new = [0] * 24
        devices = [0] * 4
        for value in self.visitors.values():
            new[value >> 2] += 1
            devices[value & 3] += 1
        hours = []
        for hour in range(24):
            seen = len(self.hour_visitors[hour]) if self.hour_visitors else 0
            hours.append(
                {"pageViews": self.hour_views[hour], "visitors": seen, "newVisitors": new[hour]}
            )
        # Most page views first; equal ones by visitors, then by path, so that the same
        # lines always give the same list
        ranked = sorted(
            self.pages.items(), key=lambda item: (-item[1][0], -len(item[1][1]), item[0])
        )
        other_views = self.other_views
        other_visitors = set(self.other_visitors)
        for _, (views, seen) in ranked[TOP_PAGES:]:
            other_views += views
            other_visitors |= seen
        return {
            "requests": self.requests,
            "pageViews": self.page_views,
            "visitors": len(self.visitors),
            "botPageViews": self.bot_page_views,
            "hours": hours,
            "pages": [
                {"path": path, "pageViews": views, "visitors": len(seen)}
                for path, (views, seen) in ranked[:TOP_PAGES]
            ],
            "pagesOther": {"pageViews": other_views, "visitors": len(other_visitors)},
            "devices": dict(zip(DEVICE_KEYS, devices)),
            # The visitor figures above are lower than they really are (see MAX_DAY_TRACKED)
            "visitorsCapped": self.capped,
        }


def empty_result():
    """A hostname with no line on a day that was counted."""
    return {
        "requests": 0,
        "pageViews": 0,
        "visitors": 0,
        "botPageViews": 0,
        "hours": [{"pageViews": 0, "visitors": 0, "newVisitors": 0} for _ in range(24)],
        "pages": [],
        "pagesOther": {"pageViews": 0, "visitors": 0},
        "devices": dict.fromkeys(DEVICE_KEYS, 0),
        "visitorsCapped": False,
    }


class DayCount:
    """One Japanese day counted in this run."""

    def __init__(self, index):
        self.index = index
        # Hours with at least one line of any kind, for missingHours
        self.seen_hours = [False] * 24
        self.hosts = {}
        # The log files that may hold this day
        self.files = []


class Stats:
    def __init__(self):
        self.lines = 0
        self.unreadable = 0
        self.unrouted = 0
        self.other_hosts = 0
        # Entries added to tell visitors apart, over every day of the run (MAX_RUN_TRACKED)
        self.tracked = 0
        # Paths listed over every hostname and day of the run (MAX_RUN_PAGES), and whether a
        # new path went to pagesOther because the run already had that many. Counted apart
        # from the entries above: a path turned away leaves the visitor figures exact.
        self.paths = 0
        self.paths_capped = False


class LogFile:
    def __init__(self, name, path, compressed, order):
        self.name = name
        self.path = path
        self.compressed = compressed
        self.order = order
        self.current = name == LOG_NAME
        self.head_min = None
        self.head_max = None
        self.error = None
        self.lo = None
        self.hi = None

    def open(self):
        if self.compressed:
            return gzip.open(self.path, "rt", encoding="utf-8", errors="replace")
        return open(self.path, "r", encoding="utf-8", errors="replace")


def describe(error):
    """A reading error in a few words. Never the content of the file."""
    reason = getattr(error, "strerror", None)
    return reason or type(error).__name__


def list_log_files(log_dir):
    """The access log files, oldest first, and a name -> inode map to spot a rotation."""
    entries = {}
    with os.scandir(log_dir) as it:
        for entry in it:
            if entry.name != LOG_NAME and not ROTATED_NAME.fullmatch(entry.name):
                continue
            try:
                if entry.is_file(follow_symlinks=False):
                    entries[entry.name] = entry.stat(follow_symlinks=False)
            except OSError:
                continue
    snapshot = {name: st.st_ino for name, st in entries.items()}

    files = []
    for name, st in entries.items():
        path = os.path.join(log_dir, name)
        if name == LOG_NAME:
            files.append(LogFile(name, path, False, (1, "")))
            continue
        match = ROTATED_NAME.fullmatch(name)
        compressed = bool(match.group(2))
        # A plain file and its .gz side by side hold the same lines. logrotate writes the
        # .gz under its final name and removes the plain file only after that, so a .gz
        # written after the plain file was last changed may be half written: read the plain
        # one. Otherwise (a .gz made with gzip -k keeps the plain file's time) read the .gz.
        if compressed:
            plain = entries.get(name[: -len(".gz")])
            if plain is not None and st.st_mtime > plain.st_mtime + 1:
                continue
        else:
            packed = entries.get(name + ".gz")
            if packed is not None and not packed.st_mtime > st.st_mtime + 1:
                continue
        files.append(LogFile(name, path, compressed, (0, match.group(1))))
    files.sort(key=lambda f: f.order)
    return files, snapshot


def sample_head(log):
    """Earliest and latest StartUTC among the first lines of a file."""
    low = high = None
    try:
        with log.open() as handle:
            for number, line in enumerate(handle):
                if number >= HEAD_LINES:
                    break
                start = quick_start(line)
                if start is None:
                    try:
                        record = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(record, dict):
                        start = parse_stamp(record.get("StartUTC"))
                    if start is None:
                        continue
                low = start if low is None else min(low, start)
                high = start if high is None else max(high, start)
    except READ_ERRORS as error:
        log.error = describe(error)
    log.head_min, log.head_max = low, high


def assign_spans(files):
    """Work out roughly which times each file holds.

    A file starts about where its first lines are and ends about where the next file's
    first lines are (the rotation). A file whose first lines could not be read takes over
    its neighbours' bounds, so it is read together with them.
    """
    low = None
    for log in files:
        if log.head_min is not None:
            low = log.head_min
        log.lo = low if low is not None else float("-inf")
    high = None
    for log in reversed(files):
        log.hi = high if high is not None else float("inf")
        if log.head_max is not None:
            high = log.head_max


def count_file(log, days, stats):
    """Count every line of one file that belongs to one of the days counted in this run."""
    hosts = {}
    agents = {}
    try:
        with log.open() as handle:
            for line in handle:
                if log.current and not line.endswith("\n"):
                    # Traefik is writing this line right now; the next run reads it whole
                    continue
                stats.lines += 1
                start = quick_start(line)
                if start is not None and day_of(start) not in days:
                    continue
                try:
                    record = json.loads(line)
                except ValueError:
                    record = None
                if not isinstance(record, dict):
                    stats.unreadable += 1
                    if start is not None:
                        day = days[day_of(start)]
                        day.seen_hours[((start + TZ_OFFSET) % DAY) // HOUR] = True
                    continue
                if start is None:
                    start = parse_stamp(record.get("StartUTC"))
                    if start is None:
                        stats.unreadable += 1
                        continue
                    if day_of(start) not in days:
                        continue
                day = days[day_of(start)]
                hour = ((start + TZ_OFFSET) % DAY) // HOUR
                day.seen_hours[hour] = True
                count_line(day, hour, record, stats, hosts, agents)
    except READ_ERRORS as error:
        log.error = describe(error)


def count_line(day, hour, record, stats, hosts, agents):
    # No router means Traefik answered the request itself (a 404 for an unknown host). A
    # router of Traefik's own is not a site either (see INTERNAL_ROUTER_SUFFIX).
    router = record.get("RouterName")
    if not isinstance(router, str) or not router or router.endswith(INTERNAL_ROUTER_SUFFIX):
        stats.unrouted += 1
        return

    raw_host = record.get("RequestHost")
    host = hosts.get(raw_host) if isinstance(raw_host, str) else None
    if host is None:
        host = host_of(raw_host)
        if isinstance(raw_host, str) and len(raw_host) <= LOOKUP_KEY_LENGTH:
            if len(hosts) >= LOOKUP_LIMIT:
                hosts.clear()
            hosts[raw_host] = host or ""
    if not host:
        stats.other_hosts += 1
        return

    method = record.get("RequestMethod")
    path = record.get("RequestPath")
    status = record.get("DownstreamStatus")
    client = record.get("ClientHost") or record.get("ClientAddr")
    # When Traefik trusts X-Forwarded-For (a host behind a CDN), ClientHost is that header
    # as it came: a comma-separated list whose front part the client writes itself, so a
    # client changing it would count as a new visitor on every request. Only the last value,
    # added by the trusted proxy, is used. Behind two trusted proxies in a row (a CDN, then a
    # load balancer) the last value is the first proxy's address, so the visitors coming
    # through one of its servers are counted as fewer than they are.
    if isinstance(client, str) and "," in client:
        client = client.rpartition(",")[2].strip()
    if (
        not isinstance(method, str)
        or not isinstance(path, str)
        or not isinstance(status, int)
        or isinstance(status, bool)
        or not isinstance(client, str)
        or not client
    ):
        stats.unreadable += 1
        return

    entry = day.hosts.get(host)
    if entry is None:
        if len(day.hosts) >= MAX_DAY_HOSTS:
            stats.other_hosts += 1
            return
        entry = day.hosts[host] = HostDay()
    entry.requests += 1

    if method != "GET" or not (200 <= status <= 299 or status == 304):
        return
    # The query never counts, and may hold personal data
    path = path.split("?", 1)[0]
    if not is_page(path):
        return

    # Traefik leaves the header out when the request had none
    agent = record.get("request_User-Agent")
    if not isinstance(agent, str):
        agent = ""
    agent = agent[:MAX_AGENT_LENGTH]
    kind = agents.get(agent)
    if kind is None:
        kind = agent_kind(agent)
        if len(agents) >= LOOKUP_LIMIT:
            agents.clear()
        agents[agent] = kind
    if kind == BOT:
        entry.bot_page_views += 1
        return
    entry.page_view(hour, hash((client, agent)), kind, page_key(path), stats)


# ---- Cache ---------------------------------------------------------------------------

CACHE_NAME = re.compile(r"([0-9]{4}-[0-9]{2}-[0-9]{2})\.json")


def valid_entry(entry, name):
    return (
        isinstance(entry, dict)
        and entry.get("version") == CACHE_VERSION
        and entry.get("rulesVersion") == RULES_VERSION
        and entry.get("date") == name
        and isinstance(entry.get("complete"), bool)
        and isinstance(entry.get("coveredUntil"), str)
        and isinstance(entry.get("computedAt"), str)
        and isinstance(entry.get("missingHours"), list)
        and isinstance(entry.get("hosts"), dict)
        and all(
            isinstance(result, dict)
            and isinstance(result.get("pageViews"), int)
            and isinstance(result.get("requests"), int)
            for result in entry["hosts"].values()
        )
    )


def remove(path):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def load_cache(days_dir, first, last):
    """The kept days inside the window. Anything else in there is removed."""
    kept = {}
    for name in sorted(os.listdir(days_dir)):
        path = os.path.join(days_dir, name)
        if name.endswith(".json.tmp") and CACHE_NAME.fullmatch(name[: -len(".tmp")]):
            # Left by a run that was killed while writing
            remove(path)
            continue
        match = CACHE_NAME.fullmatch(name)
        if not match:
            continue
        try:
            index = day_index(match.group(1))
        except ValueError:
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                entry = json.load(handle)
        except (OSError, ValueError):
            entry = None
        # Outside the window, counted under other rules, or unreadable: thrown away, and
        # counted again when the day is still inside the window
        if index < first or index > last or not valid_entry(entry, match.group(1)):
            remove(path)
            continue
        kept[index] = entry
    return kept


def write_json(path, payload, compact=False):
    """Write through a .tmp file and a rename, so a reader never sees half a file."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        if compact:
            json.dump(payload, handle, separators=(",", ":"), allow_nan=False)
        else:
            json.dump(payload, handle, allow_nan=False)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def close_day(day, now, rotated):
    """The kept form of a day counted in this run."""
    start, end = day_start(day.index), day_start(day.index + 1)
    complete = (
        now >= end + CLOSE_AFTER
        and not rotated
        and all(log.error is None for log in day.files)
    )
    covered = end if complete else min(end, now - now % 60)
    # Only hours that are over: the hour now running is not missing yet
    missing = [
        hour
        for hour in range(24)
        if not day.seen_hours[hour] and start + (hour + 1) * HOUR <= now
    ]
    results = {host: entry.result() for host, entry in day.hosts.items()}
    # The busiest hostnames of the day; the cap keeps a flood of made-up Host headers from
    # filling the cache
    ranked = sorted(results, key=lambda h: (-results[h]["pageViews"], -results[h]["requests"], h))
    return {
        "version": CACHE_VERSION,
        "rulesVersion": RULES_VERSION,
        "date": day_name(day.index),
        "complete": complete,
        "coveredUntil": iso(covered),
        "computedAt": iso(now),
        "missingHours": missing,
        "hosts": {host: results[host] for host in ranked[:MAX_HOSTS]},
    }


# ---- Run -----------------------------------------------------------------------------


def choose_days(today, first, cache, earliest, have_files):
    """The days to count in this run: today, yesterday until it is closed, and a few more."""
    if not have_files:
        return []

    def countable(index):
        # A day that was over before the oldest log line has nothing to count
        if earliest is None:
            return index == today
        return day_start(index + 1) > earliest - HOUR

    days = [today]
    yesterday = today - 1
    if countable(yesterday) and not (yesterday in cache and cache[yesterday]["complete"]):
        days.append(yesterday)
    older = [index for index in range(today - 2, first - 1, -1) if countable(index)]
    missing = [index for index in older if index not in cache]
    # A day left open by a file that could not be read is tried again, after the days that
    # have never been counted
    reopened = [index for index in older if index in cache and not cache[index]["complete"]]
    days.extend((missing + reopened)[:BACKFILL_DAYS_PER_RUN])
    return days


def build_host_files(cache, now):
    """The files for the console: one per hostname, the busiest MAX_HOSTS of the window."""
    indexes = sorted(cache)
    totals = {}
    for index in indexes:
        for host, result in cache[index]["hosts"].items():
            total = totals.setdefault(host, [0, 0])
            total[0] += result["pageViews"]
            total[1] += result["requests"]
    hosts = sorted(totals, key=lambda h: (-totals[h][0], -totals[h][1], h))[:MAX_HOSTS]
    payloads = {}
    for host in hosts:
        days = []
        seen = False
        for index in indexes:
            entry = cache[index]
            result = entry["hosts"].get(host)
            # From the first day the hostname has a line; a counted day without one is 0
            if result is None and not seen:
                continue
            seen = True
            day = {
                "date": entry["date"],
                "complete": entry["complete"],
                "coveredUntil": entry["coveredUntil"],
                "computedAt": entry["computedAt"],
                "missingHours": entry["missingHours"],
            }
            day.update(result if result is not None else empty_result())
            days.append(day)
        payloads[host] = {
            "version": FILE_VERSION,
            "generatedAt": iso(now),
            "host": host,
            "rulesVersion": RULES_VERSION,
            "timezone": TIMEZONE,
            "days": days,
        }
    return payloads


def remove_stale_host_files(out_dir, written):
    """Remove the files of hostnames not written in this run, and leftover .tmp files."""
    removed = 0
    for name in os.listdir(out_dir):
        if name.endswith(".json.tmp"):
            if HOST_SHAPE.fullmatch(name[: -len(".json.tmp")]):
                remove(os.path.join(out_dir, name))
            continue
        if not name.endswith(".json"):
            continue
        host = name[: -len(".json")]
        if HOST_SHAPE.fullmatch(host) and host not in written:
            remove(os.path.join(out_dir, name))
            removed += 1
    return removed


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Count the Traefik access log per hostname and Japanese day."
    )
    parser.add_argument("--log-dir", required=True, help="directory of access.log and its rotations")
    parser.add_argument("--out-dir", required=True, help="where <host>.json is written (sync/state/traffic)")
    parser.add_argument("--cache-dir", required=True, help="where the counted days are kept (.state/traffic)")
    parser.add_argument("--now", help="the current time, RFC 3339 with a zone (default: the clock)")
    return parser.parse_args(argv)


def summarise_days(indexes):
    if not indexes:
        return "no day"
    ordered = sorted(indexes)
    if len(ordered) == 1:
        return day_name(ordered[0])
    return f"{len(ordered)} days, {day_name(ordered[0])} to {day_name(ordered[-1])}"


def main(argv=None):
    args = parse_args(argv)
    if args.now:
        now = parse_stamp(args.now)
        if now is None:
            print(f"--now must be an RFC 3339 time with a zone (got: {args.now})", file=sys.stderr)
            return 2
    else:
        now = int(datetime.datetime.now(datetime.timezone.utc).timestamp())

    if not os.path.isdir(args.log_dir):
        print(f"No access log directory at {args.log_dir}", file=sys.stderr)
        return 1

    days_dir = os.path.join(args.cache_dir, "days")
    try:
        os.makedirs(days_dir, exist_ok=True)
        os.makedirs(args.out_dir, exist_ok=True)
        lock = open(os.path.join(args.cache_dir, "lock"), "a")
    except OSError as error:
        print(f"Could not prepare {args.cache_dir} and {args.out_dir} ({describe(error)})", file=sys.stderr)
        return 1
    # One run at a time: two runs would write the same .tmp files under each other
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("Another run is counting the access log; leaving this hour to it")
        return 0

    today = day_of(now)
    first = today - (WINDOW_DAYS - 1)
    cache = load_cache(days_dir, first, today)

    files, before = list_log_files(args.log_dir)
    for log in files:
        sample_head(log)
    assign_spans(files)
    heads = [log.head_min for log in files if log.head_min is not None]
    earliest = min(heads) if heads else None

    targets = choose_days(today, first, cache, earliest, bool(files))
    days = {index: DayCount(index) for index in targets}
    for index, day in days.items():
        start, end = day_start(index), day_start(index + 1)
        if earliest is None:
            # No file has a line with a time in its first lines, so the spans say nothing:
            # only today is counted, from the file being written now, rather than reading
            # every rotation of the year on every run.
            day.files = [log for log in files if log.current]
        else:
            day.files = [
                log for log in files if log.lo - SPAN_MARGIN < end and log.hi + SPAN_MARGIN > start
            ]
    reading = [log for log in files if any(log in day.files for day in days.values())]

    stats = Stats()
    for log in reading:
        count_file(log, days, stats)

    # A rotation in the middle of the run (a file renamed, compressed or rewritten) can
    # hide lines from it, so no day is closed on what it read; the next run closes them.
    _, after = list_log_files(args.log_dir)
    rotated = before != after

    try:
        for index, day in days.items():
            entry = close_day(day, now, rotated)
            cache[index] = entry
            write_json(os.path.join(days_dir, entry["date"] + ".json"), entry, compact=True)
        payloads = build_host_files(cache, now)
        for host, payload in payloads.items():
            write_json(os.path.join(args.out_dir, host + ".json"), payload)
        removed = remove_stale_host_files(args.out_dir, set(payloads))
    except OSError as error:
        print(f"Could not write the access summaries ({describe(error)})", file=sys.stderr)
        return 1

    for log in files:
        if log.error is not None:
            print(
                f"Could not read {log.name} to the end ({log.error}); the days it may hold stay open "
                "and are counted again on a later run",
                file=sys.stderr,
            )
    if rotated:
        print("The log files were rotated during the run, so no day was closed; the next run closes them")
    if not files:
        print(f"No access log in {args.log_dir} yet")

    closed = [index for index in targets if cache[index]["complete"]]
    if targets:
        print(
            f"Counted {summarise_days(targets)} (closed: {len(closed)}) from {len(reading)} log files: "
            + (", ".join(log.name for log in reading) or "none")
        )
    print(
        f"Lines read: {stats.lines}; unreadable lines skipped: {stats.unreadable}; "
        f"lines without a router or with one of Traefik's own: {stats.unrouted}; "
        f"lines for a hostname that is not counted: {stats.other_hosts}"
    )
    print(
        f"Wrote {len(payloads)} hostname files from {len(cache)} counted days "
        f"(window from {day_name(first)}; removed {removed} old files)"
    )
    capped = sorted(
        (index, host)
        for index, day in days.items()
        for host, entry in day.hosts.items()
        if entry.capped
    )
    if capped:
        listed = ", ".join(f"{host} on {day_name(index)}" for index, host in capped[:CAPPED_LISTED])
        if len(capped) > CAPPED_LISTED:
            listed += f" and {len(capped) - CAPPED_LISTED} more"
        print(
            f"Visitors reached the cap for {len(capped)} of the hostnames' days, written with "
            f"visitorsCapped (visitor figures low, page views exact): {listed}"
        )
    if stats.paths_capped:
        print(
            f"Listed paths reached the cap of the run ({MAX_RUN_PAGES}): paths first seen after "
            "that were counted in pagesOther instead of being listed, their page views exact"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
