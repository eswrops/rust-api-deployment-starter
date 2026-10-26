#!/usr/bin/env python3
"""Mock Google Cloud Storage JSON API for the backup test suite.

Emulates the subset of the JSON API that ops/backup uses, entirely
in-memory, with enough fidelity to exercise pagination, versioning and
failure injection:

  POST   /token                                     -> {"access_token": "..."}
  GET    /storage/v1/b/<bucket>/o?prefix&versions&maxResults&pageToken
  POST   /upload/storage/v1/b/<bucket>/o?...&name=<object>
  GET    /storage/v1/b/<bucket>/o/<object>?alt=media
  DELETE /storage/v1/b/<bucket>/o/<object>?generation=<g>
  GET    /_/dump                                    -> state for assertions

State file (JSON): {"objects": {"<name>": {"versions": [
  {"generation": 1, "updated": "...Z", "timeDeleted": null, "content_b64": "..."}]}}}
The newest version (highest generation) is live when its timeDeleted is
null; noncurrent versions carry timeDeleted, mirroring versions=true
listings.

Behavior file (JSON) injects failures:
  {"list_status": 403, "list_body": "<raw body override>",
   "list_delay": 8, "delete_fail": {"<name>": 500}, "delete_delay": 5,
   "upload_fail": {"heartbeat.txt": 500}}
"""
import argparse
import base64
import json
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

LOCK = threading.Lock()
STATE = {"objects": {}, "delete_log": []}
BEHAVIOR = {}


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # keep test output quiet
        pass

    def _send(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, code, obj):
        self._send(code, json.dumps(obj).encode())

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/token":
            length = int(self.headers.get("Content-Length") or 0)
            self.rfile.read(length)
            self._send_json(200, {"access_token": "mock-token", "expires_in": 3600})
            return
        if parsed.path.startswith("/upload/storage/v1/b/"):
            name = parse_qs(parsed.query).get("name", [None])[0]
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length)
            if name is None:
                self._send_json(400, {"error": {"code": 400, "message": "missing name"}})
                return
            bucket_fail = BEHAVIOR.get("upload_fail") or {}
            if name in bucket_fail:
                self._send_json(bucket_fail[name],
                                {"error": {"code": bucket_fail[name], "message": "injected upload failure"}})
                return
            with LOCK:
                versions = STATE["objects"].setdefault(name, {"versions": []})
                for v in versions["versions"]:
                    if v["timeDeleted"] is None:
                        v["timeDeleted"] = now_iso()
                generation = max((v["generation"] for v in versions["versions"]), default=0) + 1
                versions["versions"].append({
                    "generation": generation, "updated": now_iso(),
                    "timeDeleted": None, "content_b64": base64.b64encode(body).decode()})
            self._send_json(200, {"kind": "storage#object", "name": name, "generation": generation})
            return
        self._send_json(404, {"error": {"code": 404, "message": "not found"}})

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/_/dump":
            with LOCK:
                self._send_json(200, STATE)
            return
        # /storage/v1/b/<bucket>/o  (listing)
        parts = parsed.path.split("/")
        if len(parts) == 6 and parts[1] == "storage" and parts[5] == "o":
            query = parse_qs(parsed.query)
            delay = BEHAVIOR.get("list_delay")
            if delay:
                time.sleep(delay)
            if BEHAVIOR.get("list_status"):
                code = BEHAVIOR["list_status"]
                self._send_json(code, {"error": {"code": code, "message": "injected list failure"}})
                return
            if "list_body" in BEHAVIOR:
                self._send(BEHAVIOR.get("list_status") or 200,
                           BEHAVIOR["list_body"].encode(), ctype="application/json")
                return
            prefix = query.get("prefix", [""])[0]
            versions_mode = query.get("versions", ["false"])[0] == "true"
            max_results = int(query.get("maxResults", ["1000"])[0])
            offset = int(query.get("pageToken", ["0"])[0])
            items = []
            with LOCK:
                for name in sorted(STATE["objects"]):
                    if not name.startswith(prefix):
                        continue
                    for v in sorted(STATE["objects"][name]["versions"], key=lambda v: v["generation"]):
                        if not versions_mode and v["timeDeleted"] is not None:
                            continue
                        item = {"name": name, "generation": str(v["generation"]), "updated": v["updated"]}
                        if v["timeDeleted"] is not None:
                            item["timeDeleted"] = v["timeDeleted"]
                        items.append(item)
            page = items[offset:offset + max_results]
            resp = {"kind": "storage#objects", "items": page}
            if offset + max_results < len(items):
                resp["nextPageToken"] = str(offset + max_results)
            self._send_json(200, resp)
            return
        # /storage/v1/b/<bucket>/o/<object>
        if len(parts) == 7 and parts[1] == "storage" and parts[5] == "o":
            name = unquote(parts[6])
            with LOCK:
                versions = STATE["objects"].get(name, {}).get("versions", [])
                live = [v for v in versions if v["timeDeleted"] is None]
            if not live:
                self._send_json(404, {"error": {"code": 404, "message": "no such object"}})
                return
            self._send(200, base64.b64decode(live[-1]["content_b64"]), ctype="application/octet-stream")
            return
        self._send_json(404, {"error": {"code": 404, "message": "not found"}})

    def do_DELETE(self):
        parsed = urlparse(self.path)
        parts = parsed.path.split("/")
        if len(parts) != 7 or parts[1] != "storage" or parts[5] != "o":
            self._send_json(404, {"error": {"code": 404, "message": "not found"}})
            return
        name = unquote(parts[6])
        generation = parse_qs(parsed.query).get("generation", [None])[0]
        delay = BEHAVIOR.get("delete_delay")
        if delay:
            time.sleep(delay)
        fail_map = BEHAVIOR.get("delete_fail") or {}
        if name in fail_map:
            code = fail_map[name]
            with LOCK:
                STATE["delete_log"].append({"name": name, "generation": generation, "status": code})
            self._send_json(code, {"error": {"code": code, "message": "injected delete failure"}})
            return
        with LOCK:
            versions = STATE["objects"].get(name, {}).get("versions", [])
            if generation is not None:
                remaining = [v for v in versions if str(v["generation"]) != generation]
                status = 204 if len(remaining) != len(versions) else 404
                if status == 204:
                    STATE["objects"][name]["versions"] = remaining
            else:
                live = [v for v in versions if v["timeDeleted"] is None]
                if live:
                    live[0]["timeDeleted"] = now_iso()
                    status = 204
                else:
                    status = 404
            STATE["delete_log"].append({"name": name, "generation": generation, "status": status})
        self._send_json(status, {} if status == 204 else {"error": {"code": 404, "message": "no such object"}})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", required=True, help="initial objects state JSON")
    ap.add_argument("--behavior", help="failure-injection JSON")
    ap.add_argument("--port-file", required=True)
    args = ap.parse_args()
    with open(args.state) as f:
        loaded = json.load(f)
    STATE["objects"] = loaded.get("objects", {})
    if args.behavior:
        with open(args.behavior) as f:
            BEHAVIOR.update(json.load(f))
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(args.port_file, "w") as f:
        f.write(str(server.server_address[1]))
    sys.stderr.write(f"mock-gcs listening on {server.server_address[1]}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
