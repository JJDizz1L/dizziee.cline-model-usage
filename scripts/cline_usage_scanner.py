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


def recent_date_strings(now: dt.datetime) -> list[str]:
    today = now.date()
    return [date_string(today - dt.timedelta(days=offset)) for offset in range(6, -1, -1)]


def local_date_string(now: dt.datetime) -> str:
    return date_string(now.date())


def number(value: Any) -> int:
    try:
        return int(value or 0)
    except Exception:
        return 0


def session_columns(conn: sqlite3.Connection) -> set[str]:
    try:
        return {row[1] for row in conn.execute("PRAGMA table_info(sessions)")}
    except Exception:
        return set()


def message_events(
    path: str, seen_ids: set[str]
) -> tuple[list[tuple[int, str, int]], int]:
    """Per-message (ts_ms, model, tokens) from a Cline messages file.

    Message ids are deduped globally: forked sessions copy their parent's
    messages file, and counting both copies would double-count. Returns the
    events plus the file's total token sum (used to cap day attribution at
    the session's aggregate total).
    """
    events: list[tuple[int, str, int]] = []
    file_total = 0
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    messages = data.get("messages", [])
    if not isinstance(messages, list):
        return (events, file_total)
    for message in messages:
        if not isinstance(message, dict):
            continue
        mid = message.get("id")
        if mid is None or mid in seen_ids:
            continue
        seen_ids.add(mid)
        metrics = message.get("metrics") or {}
        if not isinstance(metrics, dict):
            continue
        total = (
            number(metrics.get("inputTokens"))
            + number(metrics.get("outputTokens"))
            + number(metrics.get("cacheReadTokens"))
            + number(metrics.get("cacheWriteTokens"))
        )
        if total <= 0:
            continue
        try:
            ts = int(message.get("ts") or 0)
        except Exception:
            continue
        if ts <= 0:
            continue
        model_info = message.get("modelInfo") or {}
        model = model_info.get("id") if isinstance(model_info, dict) else None
        events.append((ts, str(model) if model else "", total))
        file_total += total
    return (events, file_total)


def day_of(ts_ms: int) -> str | None:
    try:
        return date_string(
            dt.datetime.fromtimestamp(ts_ms / 1000).astimezone().date()
        )
    except Exception:
        return None


def attribute_days_from_messages(
    sessions: list[tuple[str, str, str, int]],
    file_paths: dict[str, str],
    recent: dict[str, dict[str, Any]],
    today: str,
    today_sessions: set[str],
    today_tokens_by_model: dict[str, int],
) -> set[str]:
    """Attribute session totals to days using per-message timestamps.

    A session's whole total bucketed on started_at misattributes every
    session that spans midnight (12 such sessions in the wild, including a
    650M-token one). Messages carry their own ts plus the model that
    actually produced them, fixing day and per-model attribution at once.
    Returns the session ids whose files parsed OK (the rest fall back to
    started_at bucketing).
    """
    handled: set[str] = set()
    seen_ids: set[str] = set()
    for session_id, model, _started_day, total in sessions:
        path = file_paths.get(session_id)
        if not path:
            continue
        try:
            events, file_total = message_events(path, seen_ids)
        except Exception as exc:
            print(f"Error reading cline messages file {path}: {exc}", file=sys.stderr)
            continue
        handled.add(session_id)
        if not events or total <= 0:
            continue
        scale = total / file_total if file_total > total else 1.0
        for ts, msg_model, toks in events:
            day = day_of(ts)
            if day is None or day not in recent:
                continue
            amount = int(toks * scale)
            key_model = msg_model or model
            recent[day]["totalTokens"] += amount
            if day == today:
                today_sessions.add(session_id)
                today_tokens_by_model[key_model] = (
                    today_tokens_by_model.get(key_model, 0) + amount
                )
    return handled


def parse_iso_date(iso_string: str) -> dt.date | None:
    if not iso_string:
        return None
    try:
        return dt.datetime.fromisoformat(iso_string.replace("Z", "+00:00")).astimezone().date()
    except Exception:
        return None


def scan(db_path: Path, now: dt.datetime | None = None) -> dict[str, Any]:
    now = now or dt.datetime.now()
    today = local_date_string(now)
    recent_dates = recent_date_strings(now)
    recent = {day: {"date": day, "totalTokens": 0} for day in recent_dates}

    today_sessions: set[str] = set()
    today_total_tokens = 0
    today_tokens_by_model: dict[str, int] = {}

    total_sessions: set[str] = set()
    model_usage: dict[str, dict[str, int]] = {}

    if not db_path.exists():
        return empty_result()

    try:
        conn = sqlite3.connect(f"{db_path.as_uri()}?mode=ro", uri=True, timeout=5)
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
        """)

        # All-time aggregates come from session metadata (authoritative
        # totals). Day attribution prefers per-message data below.
        sessions: list[tuple[str, str, str, int]] = []

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
                except ValueError:
                    meta = None
                if isinstance(meta, dict) and isinstance(meta.get("usage"), dict):
                    usage = meta["usage"]

            input_t = number(usage.get("inputTokens", 0))
            output_t = number(usage.get("outputTokens", 0))
            cache_read = number(usage.get("cacheReadTokens", 0))
            cache_write = number(usage.get("cacheWriteTokens", 0))
            total = input_t + output_t + cache_read + cache_write

            if total <= 0:
                continue

            total_sessions.add(session_id)

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

            sessions.append((session_id, model, day, total))

        has_message_paths = "messages_path" in session_columns(conn)
        file_paths: dict[str, str] = {}
        if has_message_paths:
            for sid, path in conn.execute(
                "SELECT session_id, messages_path FROM sessions"
                " WHERE is_subagent = 0 AND messages_path IS NOT NULL AND messages_path != ''"
            ):
                file_paths[str(sid)] = str(path)

        if file_paths:
            handled = attribute_days_from_messages(
                sessions, file_paths, recent, today,
                today_sessions, today_tokens_by_model,
            )
            # Sessions without a usable messages file keep the legacy
            # behavior: whole total on the started_at day.
            for session_id, model, day, total in sessions:
                if session_id in handled:
                    continue
                if day in recent:
                    recent[day]["totalTokens"] += total
                if day == today:
                    today_sessions.add(session_id)
                    today_tokens_by_model[model] = today_tokens_by_model.get(model, 0) + total
            today_total_tokens = sum(today_tokens_by_model.values())
        else:
            for session_id, model, day, total in sessions:
                if day in recent:
                    recent[day]["totalTokens"] += total

                if day == today:
                    today_sessions.add(session_id)
                    today_total_tokens += total
                    today_tokens_by_model[model] = today_tokens_by_model.get(model, 0) + total

        conn.close()
    except Exception as exc:
        print(f"Error querying cline db: {exc}", file=sys.stderr)
        return empty_result()

    return {
        "schemaVersion": 1,
        "todaySessions": len(today_sessions),
        "todayTotalTokens": today_total_tokens,
        "todayTokensByModel": today_tokens_by_model,
        "recentDays": [recent[day] for day in recent_dates],
        "modelUsage": model_usage,
        "totalSessions": len(total_sessions),
        "ready": True,
        "hasLocalStats": True,
    }


def empty_result(now: dt.datetime | None = None) -> dict[str, Any]:
    recent_dates = recent_date_strings(now or dt.datetime.now())
    return {
        "schemaVersion": 1,
        "todaySessions": 0,
        "todayTotalTokens": 0,
        "todayTokensByModel": {},
        "recentDays": [{"date": day, "totalTokens": 0} for day in recent_dates],
        "modelUsage": {},
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
