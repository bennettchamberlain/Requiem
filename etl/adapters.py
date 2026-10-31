"""Normalize One payloads into MemoryUpsert dicts."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Iterable


def _iso(value: Any) -> str:
    if isinstance(value, datetime):
        return value.astimezone(timezone.utc).isoformat()
    if isinstance(value, (int, float)):
        ms = int(value)
        if ms < 10_000_000_000:
            ms *= 1000
        return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).isoformat()
    if isinstance(value, str) and value:
        digits = value.strip()
        if digits.isdigit():
            return _iso(int(digits))
        return value
    return datetime.now(timezone.utc).isoformat()


def gmail(payload: Any) -> list[dict[str, Any]]:
    rows = _walk(payload, ("messages", "threads", "data", "result"))
    out: list[dict[str, Any]] = []
    for row in rows:
        mid = str(row.get("id") or row.get("threadId") or row.get("source_id") or "")
        if not mid:
            continue
        headers = {
            h.get("name", "").lower(): h.get("value", "")
            for h in (row.get("payload") or {}).get("headers") or []
            if isinstance(h, dict)
        }
        subject = headers.get("subject") or row.get("subject") or row.get("snippet") or "(email)"
        sender = headers.get("from") or row.get("from") or ""
        snippet = row.get("snippet") or row.get("body") or ""
        out.append(
            {
                "kind": "email",
                "title": subject,
                "body": f"From: {sender}\n{snippet}".strip(),
                "occurred_at": _iso(row.get("internalDate") or row.get("date") or row.get("occurred_at")),
                "source": "one:gmail",
                "source_id": mid,
            }
        )
    return out


def google_calendar(payload: Any) -> list[dict[str, Any]]:
    rows = _walk(payload, ("items", "events", "data", "result"))
    out: list[dict[str, Any]] = []
    for row in rows:
        eid = str(row.get("id") or row.get("iCalUID") or "")
        if not eid:
            continue
        start = (row.get("start") or {}).get("dateTime") or (row.get("start") or {}).get("date")
        attendees = ", ".join(
            a.get("email", "")
            for a in row.get("attendees") or []
            if isinstance(a, dict) and a.get("email")
        )
        out.append(
            {
                "kind": "event",
                "title": row.get("summary") or "(event)",
                "body": "\n".join(
                    p
                    for p in (
                        row.get("description"),
                        f"Location: {row['location']}" if row.get("location") else None,
                        f"Attendees: {attendees}" if attendees else None,
                    )
                    if p
                ),
                "occurred_at": _iso(start),
                "source": "one:google-calendar",
                "source_id": eid,
            }
        )
    return out


def github(payload: Any) -> list[dict[str, Any]]:
    rows = _walk(payload, ("events", "data", "result", "items"))
    out: list[dict[str, Any]] = []
    for row in rows:
        eid = str(row.get("id") or "")
        if not eid:
            continue
        repo = (row.get("repo") or {}).get("name") or row.get("repo") or ""
        typ = row.get("type") or "Event"
        out.append(
            {
                "kind": "activity",
                "title": f"{typ} {repo}".strip(),
                "body": json_preview(row.get("payload") or row),
                "occurred_at": _iso(row.get("created_at")),
                "source": "one:github",
                "source_id": eid,
            }
        )
    return out


ADAPTERS = {
    "gmail": gmail,
    "google-calendar": google_calendar,
    "github": github,
}


def generic(platform: str, payload: Any) -> list[dict[str, Any]]:
    """Best-effort rows for any One platform that is not specially shaped."""
    rows = _walk(
        payload,
        (
            "items",
            "data",
            "results",
            "records",
            "messages",
            "events",
            "issues",
            "nodes",
            "values",
        ),
    )
    out: list[dict[str, Any]] = []
    for row in rows:
        source_id = str(row.get("id") or row.get("gid") or row.get("url") or "")
        if not source_id:
            continue
        title = (
            row.get("title")
            or row.get("name")
            or row.get("summary")
            or row.get("subject")
            or platform
        )
        body = row.get("body") or row.get("description") or row.get("snippet") or ""
        out.append(
            {
                "kind": "note",
                "title": str(title),
                "body": str(body),
                "occurred_at": _iso(
                    row.get("updated_at")
                    or row.get("created_at")
                    or row.get("date")
                    or row.get("occurred_at")
                ),
                "source": f"one:{platform}",
                "source_id": source_id,
            }
        )
    return out


def normalize(platform: str, payload: Any) -> list[dict[str, Any]]:
    fn = ADAPTERS.get(platform, lambda value: generic(platform, value))
    return fn(payload)


def json_preview(value: Any, limit: int = 800) -> str:
    import json

    text = json.dumps(value, default=str)
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _walk(payload: Any, keys: Iterable[str]) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return [x for x in payload if isinstance(x, dict)]
    if not isinstance(payload, dict):
        return []
    for key in keys:
        val = payload.get(key)
        if isinstance(val, list):
            return [x for x in val if isinstance(x, dict)]
        if isinstance(val, dict):
            nested = _walk(val, keys)
            if nested:
                return nested
    return [payload] if payload.get("id") else []
