"""Shared helpers for reading cscli JSON output (imported by report.sh).

Depending on the version, cscli emits either an array of alerts (with decisions nested
inside) or a flat array of decisions. Both shapes are read the same way here.
If this breaks, blocks are treated as zero and nothing is recorded, quietly, so an
unreadable shape returns None instead of raising and the caller reports a failed query.
"""

import datetime
import json
import re

# Scenario names mean little on their own, so give them readable labels.
# Exact match first, then prefix match, then the raw scenario name.
EXACT = {
    "crowdsecurity/http-probing": "Vulnerability scan (repeated 404s)",
    "crowdsecurity/http-crawl-non_statics": "Fast crawling",
    "crowdsecurity/http-bad-user-agent": "Suspicious user agent",
    "crowdsecurity/http-path-traversal-probing": "Path traversal probing",
    "crowdsecurity/http-sensitive-files": "Sensitive file probing (.env / .git)",
    "crowdsecurity/http-sqli-probing": "SQL injection probing",
    "crowdsecurity/http-xss-probing": "XSS probing",
    "crowdsecurity/http-backdoors-attempts": "Backdoor installation attempt",
    "crowdsecurity/http-open-proxy": "Open proxy scan",
    "crowdsecurity/http-generic-bf": "Credential brute force",
    "crowdsecurity/http-w00tw00t": "Known scanner (w00tw00t)",
    "crowdsecurity/ssh-bf": "SSH login brute force",
    "crowdsecurity/ssh-slow-bf": "SSH login brute force (slow)",
}

PREFIX = [
    ("crowdsecurity/CVE-", "Request probing a known vulnerability"),
    ("crowdsecurity/http-cve", "Request probing a known vulnerability"),
    ("crowdsecurity/", "CrowdSec default rule"),
]


def label_of(scenario: str) -> str:
    if not scenario:
        return "Unknown"
    if scenario in EXACT:
        return EXACT[scenario]
    # A manual block reads like "manual 'ban' from 'xxx'"
    if scenario.startswith("manual"):
        return "Manual block"
    # For anything not in the table, show the category plus the scenario name.
    # Without the name there is no way to go and adjust the threshold.
    for prefix, label in PREFIX:
        if scenario.startswith(prefix):
            return f"{label} ({scenario})"
    return scenario


def load(path):
    """Read the output of cscli -o json. Empty or non-JSON means None (query failed)."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read().strip()
    except OSError:
        return None
    if not text:
        return None
    try:
        data = json.loads(text)
    except ValueError:
        # With zero results some versions print "No active decisions" instead of JSON.
        # Treating that as a failed query would fail the five-minute sync all day long.
        if "no active" in text.lower():
            return []
        return None
    if data is None:
        return []
    return data if isinstance(data, list) else []


def iter_decisions(payload):
    """Yield (alert, decision) pairs, reading nested and flat shapes alike.

    Decisions whose scope is not Ip or Range (Country and so on) are skipped, because the
    console assumes IPs.
    """
    for item in payload or []:
        if not isinstance(item, dict):
            continue
        nested = item.get("decisions")
        pairs = [(item, d) for d in nested if isinstance(d, dict)] if isinstance(nested, list) else [(item, item)]
        for alert, decision in pairs:
            scope = str(decision.get("scope") or "Ip").lower()
            if scope not in ("ip", "range"):
                continue
            if not decision.get("value"):
                continue
            yield alert, decision


# List the longest units first. Otherwise "12ms" reads as "12m" with a leftover "s",
# turning milliseconds into minutes and putting the expiry time orders of magnitude out
# (regular expression alternation prefers the first match).
DURATION = re.compile(r"(-?\d+(?:\.\d+)?)(ms|us|µs|ns|h|m|s)")

UNIT_SECONDS = {
    "h": 3600.0,
    "m": 60.0,
    "s": 1.0,
    "ms": 0.001,
    "us": 0.000001,
    "µs": 0.000001,
    "ns": 0.000000001,
}


def duration_seconds(text):
    """Convert a Go duration string ("3h59m12.3s") to seconds; None when unreadable."""
    if not text:
        return None
    negative = str(text).lstrip().startswith("-")
    total = 0.0
    found = False
    for value, unit in DURATION.findall(str(text)):
        total += abs(float(value)) * UNIT_SECONDS[unit]
        found = True
    if not found:
        return None
    return -total if negative else total


def expires_at(decision, now=None):
    """Build the expiry time (ISO 8601, UTC) from the decision's remaining duration.

    The cscli duration is "seconds left from now", so it drifts by a few seconds on every
    sync. The console keeps expires_at as an updatable column, so overwriting is fine.
    """
    seconds = duration_seconds(decision.get("duration"))
    if seconds is None:
        return None
    now = now or datetime.datetime.now(datetime.timezone.utc)
    return (now + datetime.timedelta(seconds=seconds)).replace(microsecond=0).isoformat()


def banned_at(alert):
    """When the block started. Uses the alert creation time, stable across syncs."""
    for key in ("created_at", "start_at"):
        value = alert.get(key)
        if isinstance(value, str) and value:
            return value
    return None
