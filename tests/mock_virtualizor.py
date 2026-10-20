#!/usr/bin/env python3
"""Minimal Virtualizor Admin API mock: act=vs (list, search, bwreset) and act=managevps.

Usage: mock_virtualizor.py <state.json> <port file>
Serves on a free 127.0.0.1 port (written to <port file>) and saves state.json after each change.
"""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

KEY, PASS = "key", 'p@ss&w"rd $x'
FAIL_ID = os.environ.get("MOCK_FAIL_MANAGEVPS", "")  # managevps fails for this vpsid
state_file, port_file = sys.argv[1], sys.argv[2]
with open(state_file) as f:
    vps = json.load(f)
lock = threading.Lock()


def save():
    with open(state_file, "w") as f:
        json.dump(vps, f)


def handle(q, form):
    if q.get("adminapikey") != KEY or q.get("adminapipass") != PASS:
        return {"error": {"auth": "Invalid API credentials"}}
    if q.get("api") != "json":
        return {"error": ["api=json expected"]}
    act = q.get("act")
    if act == "vs" and "bwreset" in q:
        vps[q["bwreset"]]["used_bandwidth"] = "0"
        save()
        return {"title": "Virtual Servers", "done_msg": "The Bandwidth was reset successfully", "done": 1}
    if act == "vs":
        items = sorted(vps.values(), key=lambda v: int(v["vpsid"]))
        if q.get("search") and q.get("vpsid"):
            items = [v for v in items if q["vpsid"] in v["vpsid"]]  # LIKE match, as the panel's filter
        page, reslen = max(int(q.get("page", 1)), 1), int(q.get("reslen", 50))  # 1-based; 0 acts as 1
        chunk = items[(page - 1) * reslen : page * reslen]
        return {"title": "Virtual Servers", "vs": {v["vpsid"]: v for v in chunk} if chunk else []}
    if act == "managevps":
        if form.get("editvps") != "1" or form.get("theme_edit") != "1":
            return {"error": ["editvps and theme_edit are required"]}
        if q["vpsid"] == FAIL_ID:
            return {"error": ["mock failure"]}
        v = vps[q["vpsid"]]
        v["bandwidth"], v["plid"] = form["bandwidth"], form["plid"]
        save()
        return {"title": "Manage VPS", "done": {"done": True}, "error": [], "vps": v}
    return {"error": ["unknown act"]}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self, form=None):
        q = {k: v[0] for k, v in parse_qs(urlparse(self.path).query).items()}
        with lock:
            body = json.dumps(handle(q, form or {})).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        self.do_GET({k: v[0] for k, v in parse_qs(raw).items()})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
