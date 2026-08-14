#!/usr/bin/env python3
"""Query Cline's sqlite database and emit compact usage stats."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sqlite3
import sys
from pathlib import Path
from typing import Any


def expand_path(value: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(value))).resolve()


def date_string(value: dt.date) -> str:
    return value.strftime("%Y-%m-%d")


def recent_date_strings() -> list[str]:
    today = dt.datetime.now().date()
    return [date_string(today - dt.timedelta(days=offset)) for offset in range(6, -1, -1)]


def local_date_string() -> str:
    return date_string(dt.datetime.now().date())


def number(value: Any) -> int:
    try:
        return int(value or 0)
    except Exception:
        return 0


def parse_iso_date(iso_string: str) -> dt.date | None:
    if not iso_string:
        return None
    try:
        return dt.datetime.fromisoformat(iso_string.replace("Z", "+00:00")).astimezone().date()
    except Exception:
        return None


def scan(db_path: Path) -> dict[str, Any]:
    today = local_date_string()
    recent_dates = recent_date_strings()
    recent = {day: {"date": day, "messageCount": 0} for day in recent_dates}

    today_prompts = 0
    today_sessions: set[str] = set()
    today_total_tokens = 0
    today_tokens_by_model: dict[str, int] = {}

    total_prompts = 0
    total_sessions: set[str] = set()
    model_usage: dict[str, dict[str, int]] = {}

    if not db_path.exists():
        return empty_result()

    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=5)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()

        cursor.execute("""
            SELECT
                session_id,
                started_at,
                model,
                metadata_json
            FROM sessions
            WHERE is_subagent = 0
              AND started_at IS NOT NULL
            ORDER BY started_at DESC
        """)

        for row in cursor:
            session_id = str(row["session_id"])
            model = str(row["model"] or "unknown")
            started_at = row["started_at"]

            day_obj = parse_iso_date(started_at)
            day = date_string(day_obj) if day_obj else today

            metadata_str = row["metadata_json"]
            usage = {}
            if metadata_str:
                try:
                    meta = json.loads(metadata_str)
                    usage = meta.get("usage", {})
                except json.JSONDecodeError:
                    pass

            input_t = number(usage.get("inputTokens", 0))
            output_t = number(usage.get("outputTokens", 0))
            cache_read = number(usage.get("cacheReadTokens", 0))
            cache_write = number(usage.get("cacheWriteTokens", 0))
            total = input_t + output_t + cache_read + cache_write

            if total <= 0:
                continue

            total_sessions.add(session_id)
            total_prompts += 1

            bucket = model_usage.setdefault(model, {
                "inputTokens": 0,
                "outputTokens": 0,
                "cacheReadInputTokens": 0,
                "cacheCreationInputTokens": 0,
            })
            bucket["inputTokens"] += input_t
            bucket["outputTokens"] += output_t
            bucket["cacheReadInputTokens"] += cache_read
            bucket["cacheCreationInputTokens"] += cache_write

            if day in recent:
                recent[day]["messageCount"] += total

            if day == today:
                today_prompts += 1
                today_sessions.add(session_id)
                today_total_tokens += total
                today_tokens_by_model[model] = today_tokens_by_model.get(model, 0) + total

        conn.close()
    except Exception as exc:
        print(f"Error querying cline db: {exc}", file=sys.stderr)
        return empty_result()

    return {
        "schemaVersion": 1,
        "todayPrompts": today_prompts,
        "todaySessions": len(today_sessions),
        "todayTotalTokens": today_total_tokens,
        "todayTokensByModel": today_tokens_by_model,
        "recentDays": [recent[day] for day in recent_dates],
        "modelUsage": model_usage,
        "totalPrompts": total_prompts,
        "totalSessions": len(total_sessions),
        "ready": True,
        "hasLocalStats": True,
    }


def empty_result() -> dict[str, Any]:
    recent_dates = recent_date_strings()
    return {
        "schemaVersion": 1,
        "todayPrompts": 0,
        "todaySessions": 0,
        "todayTotalTokens": 0,
        "todayTokensByModel": {},
        "recentDays": [{"date": day, "messageCount": 0} for day in recent_dates],
        "modelUsage": {},
        "totalPrompts": 0,
        "totalSessions": 0,
        "ready": True,
        "hasLocalStats": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("db_path", nargs="?", default="~/.cline/data/db/sessions.db")
    args = parser.parse_args()

    db_path = expand_path(args.db_path)
    summary = scan(db_path)
    print(json.dumps(summary, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
