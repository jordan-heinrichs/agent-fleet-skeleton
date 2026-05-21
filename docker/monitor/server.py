#!/usr/bin/env python3
"""Fleet monitor — serves a live dashboard by reading workspace files directly."""
import json
import os
import pathlib
from http.server import BaseHTTPRequestHandler, HTTPServer

WORKSPACE = pathlib.Path(os.environ.get("WORKDIR", "/workspace"))
PORT = int(os.environ.get("MONITOR_PORT", "8080"))
HTML = (pathlib.Path(__file__).parent / "dashboard.html").read_bytes()


def build_state():
    orch = WORKSPACE / "orchestrator"

    stuck = (orch / "STUCK.md").exists()

    fires = []
    sup = orch / "SUPERVISOR_LOG.jsonl"
    if sup.exists():
        for line in sup.read_text(errors="replace").splitlines():
            try:
                fires.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    fires = list(reversed(fires[-10:]))

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
    reports = []
    reports_dir = orch / "WORKER_REPORTS"
    if reports_dir.exists() and last_fire_id:
        for f in sorted(reports_dir.glob(f"fire-{last_fire_id}-*.json")):
            try:
                reports.append(json.loads(f.read_text(errors="replace")))
            except (json.JSONDecodeError, OSError):
                pass

    if stuck:
        status = "stuck"
    elif fires:
        d = fires[0].get("decision", "unknown")
        status = "stuck" if d.startswith("stuck") else d
    else:
        status = "waiting"

    return {
        "status": status,
        "stuck": stuck,
        "last_fire": fires[0] if fires else None,
        "recent_fires": fires,
        "recent_ledger": ledger_lines,
        "worker_reports": reports,
        "mission": ns.get("mission", ""),
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
