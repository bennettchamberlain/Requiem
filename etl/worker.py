"""One ETL job: stdin JSON {data: {person_id, platform}} -> MemoryItem rows."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import httpx
from dotenv import load_dotenv

from etl.adapters import normalize
from etl import one_client

load_dotenv(Path(__file__).resolve().parents[1] / ".env")

INTENTS = {
    "gmail": ("list recent messages", "pull recent gmail into memory"),
    "google-calendar": ("list upcoming events", "pull calendar events into memory"),
    "github": ("list user events", "pull github activity into memory"),
}


def main() -> int:
    job = json.load(sys.stdin)
    data = job.get("data") or {}
    platform = data.get("platform")

    base = os.environ.get("SCORIA_API_URL", "http://127.0.0.1:8080").rstrip("/")
    token = str(data.get("token") or os.environ.get("SCORIA_API_TOKEN") or "").strip()
    headers = {"authorization": f"Bearer {token}"} if token else {}

    result: dict = {"platform": platform, "upserted": 0}
    try:
        payload = _pull(platform, person_id=str(data.get("person_id") or ""))
        memories = normalize(platform, payload)
        with httpx.Client(timeout=30) as http:
            for item in memories:
                r = http.post(f"{base}/memory", json=item, headers=headers)
                r.raise_for_status()
                result["upserted"] += 1
            http.put(
                f"{base}/one/cursors",
                json={
                    "platform": platform,
                    "endpoint": "default",
                    "cursor": {"count": result["upserted"]},
                },
                headers=headers,
            )
    except Exception as exc:  # noqa: BLE001 — job runner wants the error text
        result["error"] = str(exc)
        try:
            with httpx.Client(timeout=15) as http:
                http.put(
                    f"{base}/one/cursors",
                    json={
                        "platform": platform,
                        "endpoint": "default",
                        "last_error": str(exc)[:500],
                    },
                    headers=headers,
                )
        except Exception:
            pass
        print(json.dumps(result))
        return 1
    print(json.dumps(result))
    return 0


def _pull(platform: str, *, person_id: str) -> object:
    connect = (os.environ.get("CONNECT_URL") or "http://127.0.0.1:8788").rstrip("/")
    if person_id:
        intent, _task = INTENTS.get(platform, ("list recent records", ""))
        try:
            response = httpx.post(
                f"{connect}/api/one/pull",
                json={"person": person_id, "platform": platform, "intent": intent},
                timeout=45,
            )
        except httpx.HTTPError as exc:
            raise RuntimeError(f"One Connect sidecar is not reachable at {connect}") from exc
        if response.status_code == 200:
            return response.json()
        detail = response.text
        if response.headers.get("content-type", "").startswith("application/json"):
            body = response.json()
            if isinstance(body, dict) and body.get("error"):
                detail = str(body["error"])
        if detail == "reconnect_required":
            raise RuntimeError("One grant needs a reconnect")
        raise RuntimeError(detail or f"One pull failed ({response.status_code})")
    fixture = os.environ.get("SCORIA_ETL_FIXTURE")
    if fixture:
        data = json.loads(Path(fixture).read_text())
        if isinstance(data, dict) and platform in data:
            return data[platform]
        return data
    if not os.environ.get("ONE_SECRET") and not os.environ.get("ONE_CONNECTION_KEYS"):
        raise RuntimeError("ONE_SECRET not set; connect One or set SCORIA_ETL_FIXTURE")
    intent, task = INTENTS.get(
        platform,
        ("list recent records", f"pull recent {platform} records into memory"),
    )
    model = os.environ.get("PARASAIL_MODEL", "parasail-glm-53-flash")
    conns = [
        c
        for c in one_client.list_connections(platform)
        if str(c.get("platform") or "") == platform
    ]
    if not conns:
        raise RuntimeError(f"no One connection for {platform}")
    key = conns[0].get("key") or conns[0].get("connectionKey")
    found = one_client.find_action(platform, intent, task, model)
    action_id = found.get("actionId") or found.get("action_id")
    if not action_id or not key:
        raise RuntimeError(f"could not resolve {platform} action")
    return one_client.execute(platform, action_id, str(key))


if __name__ == "__main__":
    raise SystemExit(main())
