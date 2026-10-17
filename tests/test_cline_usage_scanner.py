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


SCHEMA_V2 = """
CREATE TABLE sessions (
    session_id TEXT PRIMARY KEY,
    model TEXT NOT NULL,
    started_at TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT '',
    is_subagent INTEGER NOT NULL DEFAULT 0,
    messages_path TEXT,
    metadata_json TEXT
)
"""


def local_ms(*args):
    return int(dt.datetime(*args).astimezone().timestamp() * 1000)


def cline_msg(mid, ts, model_id, input_t=0, output_t=0, cache_read=0, cache_write=0):
    return {
        "id": mid,
        "role": "assistant",
        "content": [{"type": "text", "text": "x"}],
        "ts": ts,
        "modelInfo": {"id": model_id, "provider": "cline"},
        "metrics": {
            "inputTokens": input_t,
            "outputTokens": output_t,
            "cacheReadTokens": cache_read,
            "cacheWriteTokens": cache_write,
        },
    }


class MessageFileTests(unittest.TestCase):
    def setUp(self):
        self._old_tz = os.environ.get("TZ")
        self._tmp = tempfile.TemporaryDirectory()
        self.db_path = Path(self._tmp.name) / "sessions.db"
        self.conn = sqlite3.connect(self.db_path)
        self.conn.executescript(SCHEMA_V2)
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

    def write_messages(self, sid, messages):
        path = Path(self._tmp.name) / f"{sid}.messages.json"
        path.write_text(json.dumps({"messages": messages}))
        return str(path)

    def add_session(self, sid, model, started_at, metadata, messages_path=None):
        self.conn.execute(
            "INSERT INTO sessions (session_id, model, started_at, messages_path, metadata_json)"
            " VALUES (?, ?, ?, ?, ?)",
            (sid, model, started_at, messages_path, metadata),
        )
        self.conn.commit()

    def test_multiday_session_split_by_message_day_and_model(self):
        # Started Sep 26, active again Sep 29 with a different model.
        self.use_zone("UTC")
        now = dt.datetime(2026, 9, 29, 12, 0)
        meta = usage_meta(input_t=3000, output_t=300)
        path = self.write_messages("s1", [
            cline_msg("m1", local_ms(2026, 9, 26, 10, 0), "model-a", input_t=1000),
            cline_msg("m2", local_ms(2026, 9, 26, 11, 0), "model-a", output_t=100),
            cline_msg("m3", local_ms(2026, 9, 29, 9, 0), "model-b", input_t=2000, output_t=200),
        ])
        self.add_session("s1", "model-a", "2026-09-26T09:00:00+00:00", meta, path)
        result = scanner.scan(self.db_path, now=now)
        self.assertEqual(result["todayTotalTokens"], 2200)
        self.assertEqual(result["todaySessions"], 1)
        self.assertEqual(result["todayTokensByModel"], {"model-b": 2200})
        days = {d["date"]: d["totalTokens"] for d in result["recentDays"]}
        self.assertEqual(days["2026-09-29"], 2200)
        self.assertEqual(days["2026-09-26"], 1100)
        # All-time still comes from session metadata.
        self.assertIn("model-a", result["modelUsage"])

    def test_fork_copies_counted_once(self):
        self.use_zone("UTC")
        now = dt.datetime(2026, 9, 29, 12, 0)
        parent_msgs = [
            cline_msg("m1", local_ms(2026, 9, 29, 9, 0), "model-a", input_t=1000),
        ]
        fork_msgs = parent_msgs + [
            cline_msg("m2", local_ms(2026, 9, 29, 10, 0), "model-a", input_t=500),
        ]
        p1 = self.write_messages("parent", parent_msgs)
        p2 = self.write_messages("fork", fork_msgs)
        self.add_session("parent", "model-a", "2026-09-29T08:00:00+00:00",
                         usage_meta(input_t=1000), p1)
        self.add_session("fork", "model-a", "2026-09-29T09:30:00+00:00",
                         usage_meta(input_t=1500), p2)
        result = scanner.scan(self.db_path, now=now)
        self.assertEqual(result["todayTotalTokens"], 1500)
        self.assertEqual(result["todaySessions"], 2)

    def test_partial_file_capped_at_session_aggregate(self):
        self.use_zone("UTC")
        now = dt.datetime(2026, 9, 29, 12, 0)
        path = self.write_messages("s1", [
            cline_msg("m1", local_ms(2026, 9, 29, 9, 0), "model-a", input_t=4000),
        ])
        self.add_session("s1", "model-a", "2026-09-29T08:00:00+00:00",
                         usage_meta(input_t=1000), path)
        result = scanner.scan(self.db_path, now=now)
        self.assertEqual(result["todayTotalTokens"], 1000)

    def test_missing_file_falls_back_to_started_at(self):
        self.use_zone("UTC")
        now = dt.datetime(2026, 9, 29, 12, 0)
        self.add_session("s1", "model-a", "2026-09-29T08:00:00+00:00",
                         usage_meta(input_t=700), "/nonexistent/file.json")
        import contextlib
        import io

        with contextlib.redirect_stderr(io.StringIO()):
            result = scanner.scan(self.db_path, now=now)
        self.assertEqual(result["todayTotalTokens"], 700)
        self.assertEqual(result["todayTokensByModel"], {"model-a": 700})


if __name__ == "__main__":
    unittest.main()
