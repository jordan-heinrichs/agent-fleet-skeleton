#!/usr/bin/env python3
"""Fleet monitor — serves a live dashboard by reading workspace files directly."""
import json
import os
import pathlib
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, HTTPServer

WORKSPACE = pathlib.Path(os.environ.get("WORKDIR", "/workspace"))
PORT = int(os.environ.get("MONITOR_PORT", "8080"))
HTML = (pathlib.Path(__file__).parent / "dashboard.html").read_bytes()

THROTTLE_STATUSES = {"exhausted", "fast_fail"}


def build_state():
    orch = WORKSPACE / "orchestrator"

    stuck = (orch / "STUCK.md").exists()

    all_sup = []
    sup = orch / "SUPERVISOR_LOG.jsonl"
    if sup.exists():
        for line in sup.read_text(errors="replace").splitlines():
            try:
                all_sup.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    fires = list(reversed(all_sup[-10:]))

    ns = {}
    ns_path = orch / "NORTH_STAR.json"
    if ns_path.exists():
        try:
            ns = json.loads(ns_path.read_text(errors="replace"))
        except json.JSONDecodeError:
            pass

    ledger_lines = []
    ledger_path = orch / "ANTI_LOOP_LEDGER.md"
    if ledger_path.exists():
        all_lines = ledger_path.read_text(errors="replace").splitlines()
        ledger_lines = list(reversed([l for l in all_lines if l.startswith("- ")][-20:]))

    last_fire_id = fires[0]["fire_id"] if fires else 0

    # Read ALL worker reports once; derive the per-last-fire slice from them.
    all_reports = []
    reports_dir = orch / "WORKER_REPORTS"
    if reports_dir.exists():
        for f in sorted(reports_dir.glob("fire-*.json")):
            try:
                all_reports.append(json.loads(f.read_text(errors="replace")))
            except (json.JSONDecodeError, OSError):
                pass

    reports = [r for r in all_reports if r.get("fire_id") == last_fire_id] if last_fire_id else []

    if stuck:
        status = "stuck"
    elif fires:
        d = fires[0].get("decision", "unknown")
        status = "stuck" if d.startswith("stuck") else d
    else:
        status = "waiting"

    runtime_config = {}
    rc_path = orch / "RUNTIME_CONFIG.json"
    if rc_path.exists():
        try:
            runtime_config = json.loads(rc_path.read_text(errors="replace"))
        except json.JSONDecodeError:
            pass

    # --- Activity metrics ---
    total_fires = len(all_sup)
    total_files = sum(e.get("files_written_total", 0) for e in all_sup)
    now = datetime.now(timezone.utc)
    fires_last_hour = 0
    for e in all_sup:
        try:
            ts = datetime.fromisoformat(e["ts"].replace("Z", "+00:00"))
            if ts >= now - timedelta(hours=1):
                fires_last_hour += 1
        except (KeyError, ValueError):
            pass

    durations = [
        r["duration_seconds"]
        for r in all_reports
        if isinstance(r.get("duration_seconds"), (int, float))
    ]
    avg_duration = round(sum(durations) / len(durations)) if durations else 0

    # --- Throttle metrics: last 20 worker sessions, newest first ---
    all_reports_by_time = sorted(all_reports, key=lambda r: r.get("ts", ""), reverse=True)
    recent20 = all_reports_by_time[:20]
    throttle_count = sum(1 for r in recent20 if r.get("status") in THROTTLE_STATUSES)
    throttle_total = len(recent20)
    throttle_pct = round(100 * throttle_count / throttle_total) if throttle_total else 0
    last_throttle_ts = next(
        (r.get("ts") for r in recent20 if r.get("status") in THROTTLE_STATUSES), None
    )

    return {
        "status": status,
        "stuck": stuck,
        "last_fire": fires[0] if fires else None,
        "recent_fires": fires,
        "recent_ledger": ledger_lines,
        "worker_reports": reports,
        "mission": ns.get("mission", ""),
        "runtime_config": runtime_config,
        "activity": {
            "total_fires": total_fires,
            "total_files": total_files,
            "fires_last_hour": fires_last_hour,
            "avg_duration": avg_duration,
        },
        "throttle": {
            "count": throttle_count,
            "total": throttle_total,
            "pct": throttle_pct,
            "last_ts": last_throttle_ts,
            "sessions": [
                {
                    "status": r.get("status"),
                    "role": r.get("role"),
                    "ts": r.get("ts"),
                }
                for r in recent20
            ],
        },
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/state":
            body = json.dumps(build_state()).encode()
            self._respond(200, "application/json", body)
        elif self.path in ("/", "/index.html"):
            self._respond(200, "text/html; charset=utf-8", HTML)
        else:
            self.send_response(404)
            self.end_headers()

    def _respond(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[monitor] http://localhost:{PORT}", flush=True)
    server.serve_forever()