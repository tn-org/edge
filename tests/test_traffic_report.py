"""Tests for scripts/traffic_report.py: the caps on telling visitors apart.

Standard library only (unittest), like the script itself. Run from the root of this repo:

  python3 -m unittest discover -s tests -v

The tests write made-up access logs into temporary directories and run the script's
main() over them. MemoryTest fills the caps with their real values and measures the memory
of the sets that tell visitors apart, which takes a few seconds.
"""

import contextlib
import datetime
import io
import json
import os
import platform
import sys
import tempfile
import tracemalloc
import unittest
import warnings
from unittest import mock

# Keep the import below from leaving a __pycache__ in scripts/
sys.dont_write_bytecode = True
sys.path.insert(
    0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "scripts"))
)

import traffic_report  # noqa: E402

# 14:00 on 2026-11-18 in Japan
NOW = "2026-11-18T05:00:00Z"
TODAY = "2026-11-18"
YESTERDAY = "2026-11-17"
JAPAN = datetime.timezone(datetime.timedelta(hours=9))

DESKTOP_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/130.0.0.0 Safari/537.36"
)
MOBILE_AGENT = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
)
BOT_AGENT = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"

CAP_MESSAGE = "Visitors reached the cap"
MIB = 1024 * 1024
# The memory the visitor sets may take at the real caps. report-traffic.service gives a run
# 300M; the rest is for Python itself and the lookups of hostnames and User-Agents
# (LOOKUP_LIMIT keys of up to LOOKUP_KEY_LENGTH and MAX_AGENT_LENGTH characters).
MEMORY_LIMIT = 150 * MIB


def stamp(date, hour, minute=0):
    """StartUTC, as Traefik writes it, of a Japanese date and time."""
    local = datetime.datetime.combine(
        datetime.date.fromisoformat(date), datetime.time(hour, minute), JAPAN
    )
    utc = local.astimezone(datetime.timezone.utc)
    return utc.strftime("%Y-%m-%dT%H:%M:%S") + ".123456789Z"


def line(
    host,
    start,
    path="/",
    client="192.0.2.1",
    agent=DESKTOP_AGENT,
    method="GET",
    status=200,
    router="site@docker",
):
    """One line of the access log with the fields count_line reads."""
    record = {
        "StartUTC": start,
        "RequestHost": host,
        "RequestMethod": method,
        "RequestPath": path,
        "DownstreamStatus": status,
        "ClientHost": client,
    }
    if router is not None:
        record["RouterName"] = router
    if agent is not None:
        record["request_User-Agent"] = agent
    return json.dumps(record) + "\n"


def visitor_agent(number):
    """The User-Agent of one made-up visitor: a desktop browser with a number added."""
    return f"{DESKTOP_AGENT} v{number}"


def run(lines):
    """Run main() over an access.log holding these lines.

    Returns the exit code, what the run printed, and the days of every hostname file
    (hostname -> date -> day).
    """
    with tempfile.TemporaryDirectory() as root:
        log_dir = os.path.join(root, "logs")
        out_dir = os.path.join(root, "out")
        os.mkdir(log_dir)
        with open(os.path.join(log_dir, "access.log"), "w", encoding="utf-8") as handle:
            handle.writelines(lines)
        output = io.StringIO()
        # main() leaves its lock file to be closed when the process exits, which a run of
        # its own does right after; here that is reported as a ResourceWarning
        with contextlib.redirect_stdout(output), warnings.catch_warnings():
            warnings.simplefilter("ignore", ResourceWarning)
            code = traffic_report.main(
                [
                    "--log-dir",
                    log_dir,
                    "--out-dir",
                    out_dir,
                    "--cache-dir",
                    os.path.join(root, "cache"),
                    "--now",
                    NOW,
                ]
            )
        days = {}
        for name in os.listdir(out_dir):
            if not name.endswith(".json"):
                continue
            with open(os.path.join(out_dir, name), encoding="utf-8") as handle:
                payload = json.load(handle)
            days[payload["host"]] = {day["date"]: day for day in payload["days"]}
    return code, output.getvalue(), days


def hour(pages, visitors, new):
    return {"pageViews": pages, "visitors": visitors, "newVisitors": new}


class BelowCapTest(unittest.TestCase):
    def test_figures_are_exact_and_not_marked(self):
        lines = [
            line("example.com", stamp(TODAY, 10, 0), "/"),
            line("example.com", stamp(TODAY, 10, 30), "/about"),
            line("example.com", stamp(TODAY, 11, 0), "/", client="192.0.2.2", agent=MOBILE_AGENT),
            line("example.com", stamp(TODAY, 11, 10), "/", client="192.0.2.3", agent=BOT_AGENT),
            line("example.com", stamp(TODAY, 11, 20), "/contact", method="POST"),
            line("example.com", stamp(TODAY, 11, 30), "/_astro/app.js"),
            # Traefik answered it itself: not counted at all
            line("example.com", stamp(TODAY, 11, 40), "/", router=None),
        ]
        code, output, days = run(lines)

        self.assertEqual(code, 0)
        self.assertNotIn(CAP_MESSAGE, output)
        self.assertEqual(set(days), {"example.com"})
        self.assertEqual(set(days["example.com"]), {TODAY})
        day = days["example.com"][TODAY]
        self.assertEqual(day["requests"], 6)
        self.assertEqual(day["pageViews"], 3)
        self.assertEqual(day["visitors"], 2)
        self.assertEqual(day["botPageViews"], 1)
        expected_hours = [hour(0, 0, 0)] * 24
        expected_hours[10] = hour(2, 1, 1)
        expected_hours[11] = hour(1, 1, 1)
        self.assertEqual(day["hours"], expected_hours)
        self.assertEqual(
            day["pages"],
            [
                {"path": "/", "pageViews": 2, "visitors": 2},
                {"path": "/about", "pageViews": 1, "visitors": 1},
            ],
        )
        self.assertEqual(day["pagesOther"], {"pageViews": 0, "visitors": 0})
        self.assertEqual(day["devices"], {"mobile": 1, "desktop": 1, "tablet": 0, "other": 0})
        self.assertIs(day["visitorsCapped"], False)


class DayCapTest(unittest.TestCase):
    def test_a_day_over_its_cap_counts_page_views_but_no_more_visitors(self):
        lines = [
            # Each new visitor adds 3 entries (the day, the hour, the path): 3 fit in 10
            line("example.com", stamp(TODAY, 11, 0), "/", agent=visitor_agent(1)),
            line("example.com", stamp(TODAY, 11, 0), "/", agent=visitor_agent(2)),
            line("example.com", stamp(TODAY, 11, 0), "/", agent=visitor_agent(3)),
            # The fourth would make 12: the day reaches its cap here
            line("example.com", stamp(TODAY, 11, 0), "/", agent=visitor_agent(4)),
            line("example.com", stamp(TODAY, 11, 0), "/", agent=visitor_agent(5)),
            # Another hostname on the same day has a cap of its own
            line("example.org", stamp(TODAY, 11, 0), "/", agent=visitor_agent(1)),
            line("example.org", stamp(TODAY, 12, 0), "/", agent=visitor_agent(2)),
            # A known visitor on a new path would add an entry: not added
            line("example.com", stamp(TODAY, 11, 5), "/about", agent=visitor_agent(1)),
            # A known visitor earlier than first seen would be new to that hour: not added,
            # and the hour the visitor is new in stays where it was
            line("example.com", stamp(TODAY, 10, 0), "/", agent=visitor_agent(1)),
        ]
        with mock.patch.object(traffic_report, "MAX_DAY_TRACKED", 10):
            code, output, days = run(lines)

        self.assertEqual(code, 0)
        capped = days["example.com"][TODAY]
        self.assertEqual(capped["requests"], 7)
        self.assertEqual(capped["pageViews"], 7)
        self.assertEqual(capped["visitors"], 3)
        expected_hours = [hour(0, 0, 0)] * 24
        expected_hours[10] = hour(1, 0, 0)
        expected_hours[11] = hour(6, 3, 3)
        self.assertEqual(capped["hours"], expected_hours)
        self.assertEqual(
            capped["pages"],
            [
                {"path": "/", "pageViews": 6, "visitors": 3},
                {"path": "/about", "pageViews": 1, "visitors": 0},
            ],
        )
        self.assertEqual(capped["devices"], {"mobile": 0, "desktop": 3, "tablet": 0, "other": 0})
        self.assertIs(capped["visitorsCapped"], True)

        other = days["example.org"][TODAY]
        self.assertEqual(other["pageViews"], 2)
        self.assertEqual(other["visitors"], 2)
        expected_hours = [hour(0, 0, 0)] * 24
        expected_hours[11] = hour(1, 1, 1)
        expected_hours[12] = hour(1, 1, 1)
        self.assertEqual(other["hours"], expected_hours)
        self.assertIs(other["visitorsCapped"], False)

        self.assertIn(CAP_MESSAGE, output)
        self.assertIn(f"example.com on {TODAY}", output)
        self.assertNotIn("example.org on", output)


class RunCapTest(unittest.TestCase):
    def test_a_day_that_needs_an_entry_after_the_run_used_them_up_is_marked(self):
        lines = [
            # 9 entries: all the run may add
            line("example.com", stamp(TODAY, 11, 0), "/", agent=visitor_agent(1)),
            line("example.com", stamp(TODAY, 11, 0), "/", agent=visitor_agent(2)),
            line("example.com", stamp(TODAY, 11, 0), "/", agent=visitor_agent(3)),
            # A bot's page view and a POST need no entry
            line("example.net", stamp(TODAY, 11, 0), "/", agent=BOT_AGENT),
            line("example.net", stamp(TODAY, 11, 0), "/form", method="POST"),
            # Another hostname, on another day, after the run used them up
            line("example.org", stamp(YESTERDAY, 11, 0), "/", agent=visitor_agent(1)),
            # A page view that adds no entry does not reach the cap
            line("example.com", stamp(TODAY, 11, 30), "/", agent=visitor_agent(1)),
        ]
        with mock.patch.object(traffic_report, "MAX_RUN_TRACKED", 9):
            code, output, days = run(lines)

        self.assertEqual(code, 0)
        full = days["example.com"][TODAY]
        self.assertEqual(full["pageViews"], 4)
        self.assertEqual(full["visitors"], 3)
        self.assertIs(full["visitorsCapped"], False)

        bots = days["example.net"][TODAY]
        self.assertEqual(bots["requests"], 2)
        self.assertEqual(bots["botPageViews"], 1)
        self.assertIs(bots["visitorsCapped"], False)

        capped = days["example.org"][YESTERDAY]
        self.assertEqual(capped["requests"], 1)
        self.assertEqual(capped["pageViews"], 1)
        self.assertEqual(capped["visitors"], 0)
        self.assertEqual(capped["hours"][11], hour(1, 0, 0))
        self.assertEqual(capped["pages"], [{"path": "/", "pageViews": 1, "visitors": 0}])
        self.assertIs(capped["visitorsCapped"], True)
        # The day after it was counted too, with no line: all zeros and not marked
        self.assertIs(days["example.org"][TODAY]["visitorsCapped"], False)

        self.assertIn(f"example.org on {YESTERDAY}", output)
        self.assertNotIn("example.com on", output)


class MemoryTest(unittest.TestCase):
    """The visitor sets filled up to MAX_RUN_TRACKED, with the real caps, stay under 150 MiB.

    page_view is fed directly, the way count_line calls it: every call hashes the client
    address and the User-Agent into a new int, and paths are new strings near
    MAX_PATH_LENGTH, as each line read gives them. The days are filled one after another
    until each reaches MAX_DAY_TRACKED, which is what a flood that goes on for days does;
    result() is taken for every day at the end, as close_day does.
    """

    CLIENT = "192.0.2.1"
    PATH_PREFIX = "/" + "p" * 280 + "-"

    def measure(self, name, feed):
        self.assertFalse(tracemalloc.is_tracing())
        stats = traffic_report.Stats()
        tracemalloc.start()
        try:
            entries = feed(stats)
            results = [entry.result() for entry in entries]
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()

        print(
            f"\n  {name}: peak {peak / MIB:.1f} MiB for {stats.tracked} entries over "
            f"{len(entries)} days of a hostname (Python {platform.python_version()})",
            file=sys.stderr,
        )
        self.assertGreater(stats.tracked, traffic_report.MAX_RUN_TRACKED - 3)
        self.assertEqual(sum(entry.tracked for entry in entries), stats.tracked)
        for entry in entries:
            self.assertLessEqual(entry.tracked, traffic_report.MAX_DAY_TRACKED)
        self.assertTrue(all(result["visitorsCapped"] for result in results))
        self.assertLess(peak, MEMORY_LIMIT)

    def test_every_page_view_a_new_visitor(self):
        def feed(stats):
            entries = []
            number = 0
            # A new visitor adds 3 entries
            while stats.tracked + 3 <= traffic_report.MAX_RUN_TRACKED:
                entry = traffic_report.HostDay()
                entries.append(entry)
                while not entry.capped:
                    visitor = hash((self.CLIENT, "Mozilla/5.0 %d" % number))
                    path = self.PATH_PREFIX + str(number % traffic_report.MAX_DAY_PAGES)
                    entry.page_view(number % 24, visitor, traffic_report.DESKTOP, path, stats)
                    number += 1
            return entries

        self.measure("every page view a new visitor", feed)

    def test_few_visitors_on_many_pages(self):
        def feed(stats):
            entries = []
            while stats.tracked + 3 <= traffic_report.MAX_RUN_TRACKED:
                entry = traffic_report.HostDay()
                entries.append(entry)
                number = 0
                while not entry.capped:
                    agent = "Mozilla/5.0 %d %d" % (len(entries), number)
                    # Every visitor sees every path, over every hour of the day
                    for page in range(traffic_report.MAX_DAY_PAGES):
                        visitor = hash((self.CLIENT, agent))
                        path = self.PATH_PREFIX + str(page)
                        entry.page_view(page % 24, visitor, traffic_report.DESKTOP, path, stats)
                        if entry.capped:
                            break
                    number += 1
            return entries

        self.measure("few visitors on many pages", feed)


if __name__ == "__main__":
    unittest.main()
