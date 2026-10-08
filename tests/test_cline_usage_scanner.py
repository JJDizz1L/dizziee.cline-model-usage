"""Tests for scripts/cline_usage_scanner.py.

Run with: python3 -m unittest discover -s tests
"""

import datetime as dt
import importlib.util
import json
import os
import sqlite3
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "cline_usage_scanner.py"
_spec = importlib.util.spec_from_file_location("cline_usage_scanner", SCRIPT)
scanner = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(scanner)

SCHEMA = """
CREATE TABLE sessions (
    session_id TEXT PRIMARY KEY,
    model TEXT NOT NULL,
    started_at TEXT NOT NULL,
    is_subagent INTEGER NOT NULL DEFAULT 0,
    metadata_json TEXT
)
"""


def usage_meta(input_t=0, output_t=0, cache_read=0, cache_write=0):
    return json.dumps({"usage": {
        "inputTokens": input_t,
        "outputTokens": output_t,
        "cacheReadTokens": cache_read,
        "cacheWriteTokens": cache_write,
    }})


class ClineScannerTestCase(unittest.TestCase):
    def setUp(self):
        self._old_tz = os.environ.get("TZ")
        self._tmp = tempfile.TemporaryDirectory()
        self.db_path = Path(self._tmp.name) / "sessions.db"
        self.conn = sqlite3.connect(self.db_path)
        self.conn.executescript(SCHEMA)
        self.conn.commit()

    def tearDown(self):
        self.conn.close()
        self._tmp.cleanup()
        if self._old_tz is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = self._old_tz
        time.tzset()

    def use_zone(self, zone):
        os.environ["TZ"] = zone
        time.tzset()

    def add_session(self, sid, started_at, metadata, model="m", is_subagent=0):
        self.conn.execute(
            "INSERT INTO sessions (session_id, model, started_at, is_subagent, metadata_json)"
            " VALUES (?, ?, ?, ?, ?)",
            (sid, model, started_at, is_subagent, metadata),
        )
        self.conn.commit()


class MalformedRowTests(ClineScannerTestCase):
    def test_bad_metadata_rows_do_not_wipe_valid_rows(self):
        self.use_zone("UTC")
        now = dt.datetime(2026, 10, 8, 12, 0)
        started = "2026-10-08T10:00:00+00:00"
        self.add_session("good", started, usage_meta(input_t=100, output_t=50))
        self.add_session("list-meta", started, "[]")
        self.add_session("null-usage", started, '{"usage": null}')
        self.add_session("bad-json", started, "not json")
        self.add_session("null-meta", started, None)

        result = scanner.scan(self.db_path, now=now)

        self.assertTrue(result["hasLocalStats"])
        self.assertEqual(result["todayTotalTokens"], 150)
        self.assertEqual(result["totalSessions"], 1)


class RecentDaysNamingTests(ClineScannerTestCase):
    def test_recent_days_use_totalTokens_key(self):
        self.use_zone("UTC")
        now = dt.datetime(2026, 10, 8, 12, 0)
        self.add_session("a", "2026-10-08T10:00:00+00:00", usage_meta(input_t=700))
        result = scanner.scan(self.db_path, now=now)
        day = result["recentDays"][-1]
        self.assertEqual(day["date"], "2026-10-08")
        self.assertEqual(day["totalTokens"], 700)
        self.assertNotIn("messageCount", day)


class LocalDayTests(ClineScannerTestCase):
    def test_today_follows_local_timezone(self):
        # New York is UTC-4 on 2026-10-08. 02:00 UTC is 22:00 on 2026-10-07 local,
        # and 14:00 UTC is 10:00 on 2026-10-08 local.
        self.use_zone("America/New_York")
        now = dt.datetime(2026, 10, 8, 10, 0)
        self.add_session("yesterday-local", "2026-10-08T02:00:00+00:00", usage_meta(input_t=10))
        self.add_session("today-local", "2026-10-08T14:00:00+00:00", usage_meta(input_t=20))
        result = scanner.scan(self.db_path, now=now)
        self.assertEqual(result["todayTotalTokens"], 20)


class SubagentTests(ClineScannerTestCase):
    def test_subagent_sessions_are_excluded(self):
        self.use_zone("UTC")
        now = dt.datetime(2026, 10, 8, 12, 0)
        self.add_session("sub", "2026-10-08T10:00:00+00:00", usage_meta(input_t=999), is_subagent=1)
        result = scanner.scan(self.db_path, now=now)
        self.assertEqual(result["todayTotalTokens"], 0)


if __name__ == "__main__":
    unittest.main()
