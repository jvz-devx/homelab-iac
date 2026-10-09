#!/usr/bin/env python3
"""netmon: tiny webhook that stores network-monitoring events in SQLite.

Stdlib only. Endpoints:
  GET  /healthz     unauthenticated liveness/readiness check
  POST /v1/events   store one event (JSON object) or a batch (JSON array)
  GET  /v1/events   query events as JSON or CSV
  GET  /v1/outages  down windows and heartbeat gaps derived from events

Tokens are files in NETMON_TOKEN_DIR: "site.<name>" (or "site.<name>.<suffix>",
so an old and a new token can overlap during rotation) may write and read that
site only; "admin" may read every site. Tokens are never logged.
"""

import csv
import hmac
import io
import json
import logging
import os
import re
import signal
import sqlite3
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

DB_PATH = os.environ.get("NETMON_DB", "/data/netmon.db")
TOKEN_DIR = os.environ.get("NETMON_TOKEN_DIR", "/etc/netmon/tokens")
PORT = int(os.environ.get("NETMON_PORT", "8080"))
RETENTION_DAYS = int(os.environ.get("NETMON_RETENTION_DAYS", "400"))

MAX_BODY = 64 * 1024
MAX_BATCH = 500
MAX_STR = 255
MAX_ATTRS = 16 * 1024
DEFAULT_LIMIT = 1000
MAX_LIMIT = 20000
TOKEN_TTL = 30.0
PRUNE_EVERY = 3600.0

SITE_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
RELATIVE_RE = re.compile(r"^(\d+)([mhd])$")
COLUMNS = ("id", "site", "source", "entity_id", "target", "state", "previous_state",
           "previous_state_since", "last_changed", "ts", "received_at", "client_ip",
           "attributes")
INSERT_COLUMNS = COLUMNS[1:]
# States that count as "down" when deriving outage windows.
DOWN_STATES = ("off", "unavailable", "unknown")
HEARTBEAT_ENTITY = "netmon.heartbeat"
DEFAULT_GAP_MINUTES = 12

SCHEMA = """
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS events (
  id             INTEGER PRIMARY KEY,
  site           TEXT NOT NULL,
  source         TEXT,
  entity_id      TEXT NOT NULL,
  target         TEXT,
  state          TEXT NOT NULL,
  previous_state TEXT,
  previous_state_since TEXT,
  last_changed   TEXT,
  ts             TEXT NOT NULL,
  received_at    TEXT NOT NULL,
  client_ip      TEXT,
  attributes     TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS events_site_ts ON events (site, ts);
CREATE INDEX IF NOT EXISTS events_site_entity_ts ON events (site, entity_id, ts);
CREATE INDEX IF NOT EXISTS events_received_at ON events (received_at);
"""

log = logging.getLogger("netmon")


class HTTPError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


# --- storage -----------------------------------------------------------------

def connect():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.execute("PRAGMA busy_timeout = 10000")
    return conn


def init_db():
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    with connect() as conn:
        conn.executescript(SCHEMA)


_prune = {"at": 0.0}
_prune_lock = threading.Lock()


def maybe_prune(conn):
    with _prune_lock:
        if time.monotonic() - _prune["at"] < PRUNE_EVERY:
            return
        _prune["at"] = time.monotonic()
    cutoff = fmt_time(datetime.now(timezone.utc) - timedelta(days=RETENTION_DAYS))
    deleted = conn.execute("DELETE FROM events WHERE received_at < ?", (cutoff,)).rowcount
    if deleted:
        log.info("pruned %d events older than %d days", deleted, RETENTION_DAYS)


# --- auth --------------------------------------------------------------------

_tokens = {"at": float("-inf"), "entries": []}
_tokens_lock = threading.Lock()


def load_tokens():
    entries = []
    for name in sorted(os.listdir(TOKEN_DIR)):
        if name == "admin":
            scope = "*"
        elif name.startswith("site.") and SITE_RE.match(name[5:].split(".", 1)[0]):
            scope = name[5:].split(".", 1)[0]  # site.<name>[.<suffix>] for rotation overlap
        else:
            continue
        with open(os.path.join(TOKEN_DIR, name), encoding="utf-8") as fh:
            token = fh.read().strip()
        if len(token) >= 24:
            entries.append((token.encode(), scope))
        else:
            log.warning("ignoring token %s: shorter than 24 characters", name)
    return entries


def token_entries():
    with _tokens_lock:
        if time.monotonic() - _tokens["at"] > TOKEN_TTL:
            try:
                _tokens["entries"] = load_tokens()
            except OSError as exc:
                log.error("cannot read token dir: %s", type(exc).__name__)
            _tokens["at"] = time.monotonic()
        return _tokens["entries"]


def authenticate(header):
    """Return "*" for admin, a site name for a site token, or None."""
    if not header or not header.startswith("Bearer "):
        return None
    presented = header[7:].strip().encode()
    scope = None
    for token, entry_scope in token_entries():
        if hmac.compare_digest(presented, token):
            scope = entry_scope
    return scope


# --- validation --------------------------------------------------------------

def fmt_time(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def parse_time(value):
    value = value.strip()
    try:
        dt = datetime.fromisoformat(value)
    except ValueError:
        # "+02:00" arrives as " 02:00" when not URL-encoded in a query string.
        dt = datetime.fromisoformat(value.replace(" ", "+"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def parse_query_time(value, name):
    match = RELATIVE_RE.match(value.strip())
    if match:
        unit = {"m": "minutes", "h": "hours", "d": "days"}[match.group(2)]
        return fmt_time(datetime.now(timezone.utc) - timedelta(**{unit: int(match.group(1))}))
    try:
        return fmt_time(parse_time(value))
    except ValueError:
        raise HTTPError(400, f"{name} must be ISO 8601 or a relative age like 30m, 24h, 7d")


def text(event, key, required=False):
    value = event.get(key)
    if value is None or value == "":
        if required:
            raise ValueError(f"{key} is required")
        return None
    if isinstance(value, bool):
        value = "true" if value else "false"
    elif isinstance(value, (int, float)):
        value = str(value)
    if not isinstance(value, str):
        raise ValueError(f"{key} must be a string")
    if len(value) > MAX_STR:
        raise ValueError(f"{key} is longer than {MAX_STR} characters")
    return value


def event_time(event, key):
    value = text(event, key)
    if not value:
        return None
    try:
        return fmt_time(parse_time(value))
    except ValueError:
        raise ValueError(f"{key} must be ISO 8601")


def normalize(event, scope, received_at, client_ip):
    if not isinstance(event, dict):
        raise ValueError("event must be a JSON object")
    site = text(event, "site") or (scope if scope != "*" else None)
    if not site or not SITE_RE.match(site):
        raise ValueError("site is required and must match [a-z0-9-]")
    if scope != site:
        raise PermissionError(f"token may not write site {site!r}")
    ts = event_time(event, "ts") or received_at
    attributes = event.get("attributes") or {}
    if isinstance(attributes, str):
        # HA falls back to a string when a template result is not a literal;
        # keep it rather than dropping the event.
        attributes = {"raw": attributes}
    if not isinstance(attributes, dict):
        raise ValueError("attributes must be a JSON object")
    attributes = json.dumps(attributes, separators=(",", ":"), sort_keys=True, default=str)
    if len(attributes) > MAX_ATTRS:
        raise ValueError(f"attributes exceed {MAX_ATTRS} bytes")
    return (site, text(event, "source"), text(event, "entity_id", required=True),
            text(event, "target"), text(event, "state", required=True),
            text(event, "previous_state"), event_time(event, "previous_state_since"),
            event_time(event, "last_changed"), ts, received_at, client_ip, attributes)


# --- HTTP --------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "netmon/1"
    sys_version = ""
    timeout = 30

    def log_message(self, fmt, *args):  # replaced by access()
        pass

    def access(self, status, note=""):
        path = urlsplit(self.path).path
        log.info("%s %s %s %d %s", self.client_ip(), self.command, path, status, note)

    def client_ip(self):
        # Only cloudflared reaches the ClusterIP Service, so these headers come
        # from Cloudflare's edge, not from the caller.
        for header in ("CF-Connecting-IP", "X-Forwarded-For"):
            value = self.headers.get(header)
            if value:
                return value.split(",")[0].strip()[:64]
        return self.client_address[0]

    def send(self, status, body, content_type="application/json", headers=None, note=""):
        if not isinstance(body, bytes):
            body = (json.dumps(body, separators=(",", ":")) + "\n").encode()
        self.send_response_only(status)
        self.send_header("Date", self.date_time_string())
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        self.access(status, note)

    def route(self, handler):
        try:
            handler()
        except HTTPError as exc:
            headers = {"WWW-Authenticate": "Bearer"} if exc.status == 401 else None
            self.send(exc.status, {"error": exc.message}, headers=headers, note=exc.message)
        except Exception:
            log.exception("unhandled error")
            self.send(500, {"error": "internal error"})

    def require_auth(self):
        scope = authenticate(self.headers.get("Authorization"))
        if scope is None:
            raise HTTPError(401, "unauthorized")
        return scope

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/healthz":
            self.route(self.healthz)
        elif path == "/v1/events":
            self.route(self.query_events)
        elif path == "/v1/outages":
            self.route(self.query_outages)
        else:
            self.send(404, {"error": "not found"})

    def do_POST(self):
        if urlsplit(self.path).path == "/v1/events":
            self.route(self.post_events)
        else:
            self.send(404, {"error": "not found"})

    def healthz(self):
        try:
            with connect() as conn:
                conn.execute("SELECT 1").fetchone()
        except sqlite3.Error:
            raise HTTPError(503, "database unavailable")
        self.send(200, {"status": "ok"})

    def post_events(self):
        scope = self.require_auth()
        if scope == "*":
            raise HTTPError(403, "admin token is read-only; use a site token")
        if self.headers.get("Transfer-Encoding"):
            raise HTTPError(411, "Content-Length required")
        content_type = (self.headers.get("Content-Type") or "").split(";")[0].strip()
        if content_type != "application/json":
            raise HTTPError(415, "Content-Type must be application/json")
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            raise HTTPError(411, "Content-Length required")
        if length < 0 or length > MAX_BODY:
            raise HTTPError(413, f"body exceeds {MAX_BODY} bytes")
        try:
            payload = json.loads(self.rfile.read(length))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise HTTPError(400, "body is not valid JSON")
        events = payload if isinstance(payload, list) else [payload]
        if not events:
            raise HTTPError(400, "empty batch")
        if len(events) > MAX_BATCH:
            raise HTTPError(413, f"batch exceeds {MAX_BATCH} events")

        received_at = fmt_time(datetime.now(timezone.utc))
        client_ip = self.client_ip()
        rows = []
        for index, event in enumerate(events):
            try:
                rows.append(normalize(event, scope, received_at, client_ip))
            except PermissionError as exc:
                raise HTTPError(403, f"event {index}: {exc}")
            except ValueError as exc:
                raise HTTPError(400, f"event {index}: {exc}")

        with connect() as conn:
            conn.executemany(
                f"INSERT INTO events ({', '.join(INSERT_COLUMNS)})"
                f" VALUES ({','.join('?' * len(INSERT_COLUMNS))})",
                rows,
            )
            maybe_prune(conn)
        self.send(202, {"accepted": len(rows), "received_at": received_at},
                  note=f"site={scope} accepted={len(rows)}")

    def params(self):
        params = parse_qs(urlsplit(self.path).query)
        return params, (lambda name: (params.get(name) or [None])[-1])

    def filters(self, scope, params, one):
        """Build the WHERE clause shared by /v1/events and /v1/outages."""
        site = one("site")
        if scope != "*":
            if site and site != scope:
                raise HTTPError(403, f"token may not read site {site!r}")
            site = scope
        where, args = [], []
        if site:
            where.append("site = ?")
            args.append(site)
        entities = [e for v in params.get("entity", []) for e in v.split(",") if e]
        if entities:
            where.append(f"entity_id IN ({','.join('?' * len(entities))})")
            args.extend(entities)
        for name, op in (("since", ">="), ("until", "<")):
            value = one(name)
            if value:
                where.append(f"ts {op} ?")
                args.append(parse_query_time(value, name))
        return (" WHERE " + " AND ".join(where)) if where else "", args

    def fetch(self, where, args, order, limit):
        sql = (f"SELECT {', '.join(COLUMNS)} FROM events{where}"
               f" ORDER BY ts {order}, id {order} LIMIT ?")
        with connect() as conn:
            return [dict(zip(COLUMNS, row)) for row in conn.execute(sql, (*args, limit))]

    def query_events(self):
        scope = self.require_auth()
        params, one = self.params()
        where, args = self.filters(scope, params, one)
        try:
            limit = max(1, min(int(one("limit") or DEFAULT_LIMIT), MAX_LIMIT))
        except ValueError:
            raise HTTPError(400, "limit must be an integer")
        order = "DESC" if one("order") == "desc" else "ASC"
        fmt = one("format") or "json"
        if fmt not in ("json", "csv"):
            raise HTTPError(400, "format must be json or csv")

        events = self.fetch(where, args, order, limit)
        note = f"scope={scope} rows={len(events)}"
        if fmt == "csv":
            buf = io.StringIO()
            writer = csv.DictWriter(buf, COLUMNS)
            writer.writeheader()
            writer.writerows(events)
            self.send(200, buf.getvalue().encode(), "text/csv; charset=utf-8", note=note)
            return
        for event in events:
            event["attributes"] = json.loads(event["attributes"])
        self.send(200, {"count": len(events), "limit": limit, "events": events}, note=note)

    def query_outages(self):
        scope = self.require_auth()
        params, one = self.params()
        where, args = self.filters(scope, params, one)
        try:
            gap = timedelta(minutes=int(one("gap_minutes") or DEFAULT_GAP_MINUTES))
        except ValueError:
            raise HTTPError(400, "gap_minutes must be an integer")
        events = self.fetch(where, args, "ASC", MAX_LIMIT)
        result = derive_outages(events, gap, datetime.now(timezone.utc))
        result["truncated"] = len(events) >= MAX_LIMIT
        self.send(200, result, note=f"scope={scope} rows={len(events)}")


def seconds_between(start, end):
    return round((parse_time(end) - parse_time(start)).total_seconds(), 3)


def derive_outages(events, gap, now):
    """Turn raw events into down windows and heartbeat gaps.

    A recovery event (previous_state down, state up) carries previous_state_since,
    so it closes a window even when the matching "went down" POST never arrived.
    The last known state of an entity that is still down yields an open window.
    """
    windows, latest, heartbeats = [], {}, []
    for event in events:
        if event["entity_id"] == HEARTBEAT_ENTITY:
            heartbeats.append(event)
            continue
        key = (event["site"], event["entity_id"])
        latest[key] = event
        if (event["previous_state"] in DOWN_STATES and event["state"] not in DOWN_STATES
                and event["previous_state_since"]):
            end = event["last_changed"] or event["ts"]
            windows.append({
                "site": event["site"], "entity_id": event["entity_id"],
                "target": event["target"], "state": event["previous_state"],
                "start": event["previous_state_since"], "end": end,
                "duration_s": seconds_between(event["previous_state_since"], end),
            })
    for event in latest.values():
        if event["state"] in DOWN_STATES:
            start = event["last_changed"] or event["ts"]
            windows.append({
                "site": event["site"], "entity_id": event["entity_id"],
                "target": event["target"], "state": event["state"],
                "start": start, "end": None,
                "duration_s": seconds_between(start, fmt_time(now)),
            })
    windows.sort(key=lambda w: (w["start"], w["entity_id"]))

    gaps, previous = [], {}
    for event in heartbeats:
        before = previous.get(event["site"])
        if before and parse_time(event["ts"]) - parse_time(before["ts"]) > gap:
            gaps.append({"site": event["site"], "start": before["ts"], "end": event["ts"],
                         "duration_s": seconds_between(before["ts"], event["ts"])})
        previous[event["site"]] = event
    for site, event in previous.items():
        if now - parse_time(event["ts"]) > gap:
            gaps.append({"site": site, "start": event["ts"], "end": None,
                         "duration_s": seconds_between(event["ts"], fmt_time(now))})
    return {"gap_minutes": int(gap.total_seconds() // 60),
            "down_windows": windows, "heartbeat_gaps": gaps}

def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    init_db()
    if not token_entries():
        log.warning("no tokens loaded from %s; every request will get 401", TOKEN_DIR)
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=httpd.shutdown).start())
    log.info("listening on :%d, database %s", PORT, DB_PATH)
    httpd.serve_forever()
    httpd.server_close()
    log.info("stopped")


if __name__ == "__main__":
    main()
