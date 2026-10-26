#!/usr/bin/env bash
# Test suite for the backup tooling (ops/backup/*) against a local mock of
# the GCS JSON API (mock-gcs.py). Covers listing pagination, retention
# failure visibility, minimum-snapshot preservation, retention races, and
# the restore drill's newest-snapshot selection. Nothing leaves the machine:
# no Google access, no production bucket, no production database.
set -Eeuo pipefail
test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
backup_dir="$(cd -- "$test_dir/.." && pwd)"
temp="$(mktemp -d)"
mock_pid=""
port=""

cleanup() {
  if [ -n "$mock_pid" ]; then
    kill "$mock_pid" 2>/dev/null || true
    wait "$mock_pid" 2>/dev/null || true
  fi
  rm -rf "$temp"
}
trap cleanup EXIT

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS $1"; }

# --- one-time fixtures ------------------------------------------------------

openssl genrsa -out "$temp/sa-key.pem" 2048 2>/dev/null
python3 - "$temp/sa-key.pem" "$temp/sa-key.json" <<'PY'
import json, sys
json.dump({"client_email": "backup-test@example.iam.gserviceaccount.com",
           "private_key": open(sys.argv[1]).read(),
           "token_uri": "https://oauth2.googleapis.com/token"},
          open(sys.argv[2], "w"))
PY

# Seed database shaped like production (users/posts/likes + sqlx table).
python3 - "$temp/seed-db" <<'PY'
import os, sqlite3, sys
os.makedirs(sys.argv[1], exist_ok=True)
con = sqlite3.connect(os.path.join(sys.argv[1], "app.db"))
con.executescript("""
CREATE TABLE _sqlx_migrations (version BIGINT PRIMARY KEY, description TEXT);
CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER);
CREATE TABLE likes (id INTEGER PRIMARY KEY, post_id INTEGER);
INSERT INTO _sqlx_migrations VALUES (1, 'init');
INSERT INTO users VALUES (1, 'a'), (2, 'b');
INSERT INTO posts VALUES (1, 1);
INSERT INTO likes VALUES (1, 1);
""")
con.commit()
con.close()
PY
seed_db="$temp/seed-db/app.db"

cat > "$temp/fake-api" <<'EOF'
#!/usr/bin/env python3
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health/ready":
            body = b'{"status":"ok","version":"drill-stub"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):
        pass

bind = os.environ.get("APP_BIND", "127.0.0.1:18081")
host, port_s = bind.rsplit(":", 1)
HTTPServer((host, int(port_s)), H).serve_forever()
EOF
chmod +x "$temp/fake-api"

start_mock() {  # start_mock STATE_FILE [BEHAVIOR_FILE]
  local state="$1" behavior="${2:-}"
  local args=(--state "$state" --port-file "$temp/port")
  [ -n "$behavior" ] && args+=(--behavior "$behavior")
  python3 "$test_dir/mock-gcs.py" "${args[@]}" 2>/dev/null &
  mock_pid=$!
  for _ in $(seq 1 50); do [ -s "$temp/port" ] && break; sleep 0.1; done
  [ -s "$temp/port" ] || die "mock gcs did not start"
  port="$(cat "$temp/port")"
}

stop_mock() {
  [ -n "$mock_pid" ] || return 0
  kill "$mock_pid" 2>/dev/null || true
  wait "$mock_pid" 2>/dev/null || true
  mock_pid=""
  rm -f "$temp/port"
}

mock_dump() { curl -fsS "http://127.0.0.1:$port/_/dump"; }

# begin NAME: fresh scenario directory + env file; sets S (dir), S_STATE,
# S_BEHAVIOR, S_OUT (captured output), S_RC (exit status).
S=""
S_STATE=""
S_BEHAVIOR=""
S_OUT=""
S_RC=0
begin() {
  local name="$1"
  stop_mock
  S="$temp/$name"
  S_STATE="$S/state.json"
  S_BEHAVIOR="$S/behavior.json"
  mkdir -p "$S/backups"
  echo '{"objects": {}}' > "$S_STATE"
  cat > "$S/env" <<EOF
GCS_BUCKET=test-bucket
GCS_KEY_FILE=$temp/sa-key.json
DATABASE_URL=sqlite://$seed_db
BACKUP_DIR=$S/backups
LOCAL_KEEP_DAYS=7
OFFSITE_KEEP_DAYS=30
MIN_LIVE_SNAPSHOTS=3
EOF
}

run_backup() {
  set +e
  S_OUT="$(BACKUP_ENV_FILE="$S/env" \
    GCS_API_BASE="http://127.0.0.1:$port" \
    GCS_TOKEN_URL="http://127.0.0.1:$port/token" \
    GCS_HTTP_TIMEOUT=10 GCS_UPLOAD_TIMEOUT=10 \
    "$backup_dir/rust-api-backup" 2>&1)"
  S_RC=$?
  set -e
}

run_drill() {
  set +e
  S_OUT="$(BACKUP_ENV_FILE="$S/env" \
    GCS_API_BASE="http://127.0.0.1:$port" \
    GCS_TOKEN_URL="http://127.0.0.1:$port/token" \
    GCS_HTTP_TIMEOUT=10 \
    DRILL_BIN="$temp/fake-api" \
    DRILL_PORT=18499 \
    "$backup_dir/rust-api-restore-drill" 2>&1)"
  S_RC=$?
  set -e
}

expect_rc() {
  [ "$S_RC" -eq "$1" ] || die "$2: exit $S_RC != $1
--- output ---
$S_OUT"
}

expect_contains() {
  grep -qF "$1" <<<"$S_OUT" || die "$2: output missing '$1'
--- output ---
$S_OUT"
}

expect_absent() {
  grep -qF "$1" <<<"$S_OUT" && die "$2: output must not contain '$1'
--- output ---
$S_OUT" || true
}

expect_deletes() {  # expect_deletes DESC EXPECTED_JSON_ARRAY_OF_LOG
  dump="$(mock_dump)"
  python3 - "$dump" "$2" <<-"PY"
	import json, sys
	dump = json.loads(sys.argv[1])
	expected = json.loads(sys.argv[2])
	got = [{k: d[k] for k in ("name", "generation", "status")} for d in dump["delete_log"]]
	assert got == expected, f"delete_log mismatch:\n got: {got}\nwant: {expected}"
	print("ok")
	PY
}

expected_log() {  # expected_log PYTHON_LIST_EXPRESSION -> JSON array on stdout
  python3 -c 'import json, sys; print(json.dumps(eval(sys.argv[1])))' "$1"
}

gen_objects() {  # gen_objects OUT_FILE PYTHON_EXPRESSION_EVALUATING_TO_OBJECTS_DICT
  python3 - "$1" "$2" <<'PY'
import base64, datetime, json, sys
out, expr = sys.argv[1], sys.argv[2]
objects = eval(expr, {"base64": base64, "datetime": datetime})
json.dump({"objects": objects}, open(out, "w"))
PY
}

# --- scenarios --------------------------------------------------------------

# 1. Empty listing: retention succeeds with nothing to do.
begin empty_listing
start_mock "$S_STATE"
run_backup
expect_rc 0 "empty_listing"
expect_contains "off-site retention: 0 object(s) expired" "empty_listing"
pass empty_listing

# 2. Lib-level pagination: >1000 objects must yield every row. Timestamps
#    descend from "now" so the filler snapshots never age into expiry.
begin pagination_lib
python3 - "$S_STATE" <<'PY'
import datetime, json, sys
objects = {}
for i in range(1250):
    ts = (datetime.datetime.now(datetime.timezone.utc)
          - datetime.timedelta(minutes=i + 1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    name = f"snapshots/app-{i:04d}.db"
    objects[name] = {"versions": [{"generation": 1, "updated": ts,
                                   "timeDeleted": None, "content_b64": ""}]}
json.dump({"objects": objects}, open(sys.argv[1], "w"))
PY
start_mock "$S_STATE"
rows="$(
  export GCS_API_BASE="http://127.0.0.1:$port" GCS_TOKEN_URL="http://127.0.0.1:$port/token"
  . "$backup_dir/rust-api-backup-lib.sh"
  gcs_list "$temp/sa-key.json" test-bucket "" | wc -l | tr -d ' '
)"
[ "$rows" = "1250" ] || die "pagination_lib: gcs_list returned $rows rows, expected 1250"
pass pagination_lib

# 3. Retention over a >1000-object listing: the 10 expired snapshots sort
#    onto the second page (names zold-*), so a truncated listing would
#    silently expire none of them.
begin pagination_retention
gen_objects "$S_STATE" '{
  **{f"snapshots/app-{i:04d}.db": {"versions": [{"generation": 1, "updated": (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=i+1)).strftime("%Y-%m-%dT%H:%M:%SZ"), "timeDeleted": None, "content_b64": ""}]} for i in range(1250)},
  **{f"snapshots/zold-{i:02d}.db": {"versions": [{"generation": 1, "updated": "2020-01-01T00:00:00Z", "timeDeleted": None, "content_b64": ""}]} for i in range(10)}
}'
start_mock "$S_STATE"
run_backup
expect_rc 0 "pagination_retention"
expect_contains "off-site retention: 10 object(s) expired" "pagination_retention"
expect_deletes "pagination_retention" "$(expected_log '[
  {"name": f"snapshots/zold-{i:02d}.db", "generation": None, "status": 204} for i in range(10)
]')"
pass pagination_retention

# 4-6. Listing failures (403/429/500): retention must not run and nothing
#      may be deleted; the run must exit non-zero so the alert unit fires.
for code in 403 429 500; do
  begin "list_${code}"
  gen_objects "$S_STATE" '{
    "snapshots/app-old.db": {"versions": [{"generation": 1, "updated": "2020-01-01T00:00:00Z", "timeDeleted": None, "content_b64": ""}]}
  }'
  echo "{\"list_status\": $code}" > "$S_BEHAVIOR"
  start_mock "$S_STATE" "$S_BEHAVIOR"
  run_backup
  expect_rc 1 "list_${code}"
  expect_contains "retention NOT attempted" "list_${code}"
  expect_deletes "list_${code}" "[]"
  pass "list_${code}"
done

# 7. Listing network timeout: run must fail, not skip retention. The mock
#    stalls longer than the test's GCS_HTTP_TIMEOUT.
begin list_timeout
echo '{"list_delay": 15}' > "$S_BEHAVIOR"
start_mock "$S_STATE" "$S_BEHAVIOR"
run_backup
expect_rc 1 "list_timeout"
expect_contains "retention NOT attempted" "list_timeout"
expect_deletes "list_timeout" "[]"
pass list_timeout

# 8. Malformed listing JSON: must fail instead of looking empty.
begin malformed_list
echo '{"list_body": "{\"items\": [not valid json"}' > "$S_BEHAVIOR"
start_mock "$S_STATE" "$S_BEHAVIOR"
run_backup
expect_rc 1 "malformed_list"
expect_contains "malformed listing response" "malformed_list"
expect_deletes "malformed_list" "[]"
pass malformed_list

# 9. Delete returning 404 is a safe retention race, not a failure. (Three
#    fresh snapshots fill the MIN_LIVE_SNAPSHOTS protection so the old one
#    is genuinely expiry-eligible.)
begin delete_404_race
gen_objects "$S_STATE" '{
  **{f"snapshots/app-fresh-{i}.db": {"versions": [{"generation": 1, "updated": (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=i+1)).strftime("%Y-%m-%dT00:00:00Z"), "timeDeleted": None, "content_b64": ""}]} for i in range(3)},
  "snapshots/app-2020.db": {"versions": [{"generation": 1, "updated": "2020-01-01T00:00:00Z", "timeDeleted": None, "content_b64": ""}]}
}'
echo '{"delete_fail": {"snapshots/app-2020.db": 404}}' > "$S_BEHAVIOR"
start_mock "$S_STATE" "$S_BEHAVIOR"
run_backup
expect_rc 0 "delete_404_race"
expect_contains "off-site retention: 1 object(s) expired" "delete_404_race"
expect_deletes "delete_404_race" '[{"name": "snapshots/app-2020.db", "generation": null, "status": 404}]'
pass delete_404_race

# 10. Partial deletion failure: others deleted, failure reported, run fails,
#     and the failed object is never reported as deleted. (Six old snapshots
#     leave four outside the MIN_LIVE_SNAPSHOTS protection.)
begin partial_delete_failure
gen_objects "$S_STATE" '{
  **{f"snapshots/app-{l}.db": {"versions": [{"generation": 1, "updated": f"2020-0{i}-01T00:00:00Z", "timeDeleted": None, "content_b64": ""}]} for i, l in enumerate("abcdef", start=1)}
}'
echo '{"delete_fail": {"snapshots/app-b.db": 500}}' > "$S_BEHAVIOR"
start_mock "$S_STATE" "$S_BEHAVIOR"
run_backup
expect_rc 1 "partial_delete_failure"
expect_contains "1 deletion(s) failed" "partial_delete_failure"
expect_contains "deleted snapshots/app-a.db" "partial_delete_failure"
expect_contains "deleted snapshots/app-c.db" "partial_delete_failure"
expect_absent "deleted snapshots/app-b.db" "partial_delete_failure"
expect_deletes "partial_delete_failure" '[
  {"name": "snapshots/app-a.db", "generation": null, "status": 204},
  {"name": "snapshots/app-b.db", "generation": null, "status": 500},
  {"name": "snapshots/app-c.db", "generation": null, "status": 204},
  {"name": "snapshots/app-d.db", "generation": null, "status": 204}
]'
pass partial_delete_failure

# 11. A single remaining (old) snapshot must never be expired.
begin last_snapshot_protected
gen_objects "$S_STATE" '{
  "snapshots/app-2020.db": {"versions": [{"generation": 1, "updated": "2020-01-01T00:00:00Z", "timeDeleted": None, "content_b64": ""}]}
}'
start_mock "$S_STATE"
run_backup
expect_rc 0 "last_snapshot_protected"
expect_contains "off-site retention: 0 object(s) expired" "last_snapshot_protected"
expect_deletes "last_snapshot_protected" "[]"
pass last_snapshot_protected

# 12. MIN_LIVE_SNAPSHOTS: exactly the oldest (5-3) live snapshots expire.
begin min_snapshots
gen_objects "$S_STATE" '{
  **{f"snapshots/app-2020-{i:02d}.db": {"versions": [{"generation": 1, "updated": f"2020-01-{i:02d}T00:00:00Z", "timeDeleted": None, "content_b64": ""}]} for i in range(1, 6)}
}'
start_mock "$S_STATE"
run_backup
expect_rc 0 "min_snapshots"
# 6 live snapshots total (5 old + the fresh upload); the newest 3 are
# protected, so exactly the three oldest expire.
expect_contains "off-site retention: 3 object(s) expired" "min_snapshots"
expect_deletes "min_snapshots" '[
  {"name": "snapshots/app-2020-01.db", "generation": null, "status": 204},
  {"name": "snapshots/app-2020-02.db", "generation": null, "status": 204},
  {"name": "snapshots/app-2020-03.db", "generation": null, "status": 204}
]'
pass min_snapshots

# 13. Heartbeat upload failure: snapshot upload succeeded, but the run must
#     fail before writing last-backup-success or touching retention.
begin heartbeat_upload_failure
echo '{"upload_fail": {"heartbeat.txt": 500}}' > "$S_BEHAVIOR"
start_mock "$S_STATE" "$S_BEHAVIOR"
run_backup
expect_rc 1 "heartbeat_upload_failure"
expect_contains "gcs_upload heartbeat.txt -> HTTP 500" "heartbeat_upload_failure"
[ ! -f "$S/backups/last-backup-success" ] || die "heartbeat_upload_failure: last-backup-success written despite heartbeat failure"
dump="$(mock_dump)"
python3 - "$dump" <<'PY'
import json, sys
dump = json.loads(sys.argv[1])
snapshots = [n for n in dump["objects"] if n.startswith("snapshots/")]
assert len(snapshots) == 1, f"expected the uploaded snapshot in the bucket, got {snapshots}"
assert dump["delete_log"] == [], f"retention must not run after heartbeat failure: {dump['delete_log']}"
PY
pass heartbeat_upload_failure

# 14. Versioned expiry: old live snapshot expired without a generation,
#     old noncurrent version purged WITH its generation, recent noncurrent
#     version kept, drill reports expired, heartbeat object untouched.
begin superseded_versions
gen_objects "$S_STATE" '{
  **{f"snapshots/app-fresh-{i}.db": {"versions": [{"generation": 1, "updated": (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=i+1)).strftime("%Y-%m-%dT00:00:00Z"), "timeDeleted": None, "content_b64": ""}]} for i in range(4)},
  "snapshots/app-y.db": {"versions": [
      {"generation": 1, "updated": (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=5)).strftime("%Y-%m-%dT00:00:00Z"), "timeDeleted": None, "content_b64": ""}]},
  "snapshots/app-x.db": {"versions": [
      {"generation": 1, "updated": "2020-06-01T00:00:00Z", "timeDeleted": "2020-06-05T00:00:00Z", "content_b64": ""},
      {"generation": 2, "updated": "2020-07-01T00:00:00Z", "timeDeleted": None, "content_b64": ""}]},
  "drills/drill-2020.txt": {"versions": [{"generation": 1, "updated": "2020-01-01T00:00:00Z", "timeDeleted": None, "content_b64": ""}]},
  "heartbeat.txt": {"versions": [{"generation": 1, "updated": "2020-01-01T00:00:00Z", "timeDeleted": None, "content_b64": ""}]}
}'
start_mock "$S_STATE"
run_backup
expect_rc 0 "superseded_versions"
expect_contains "off-site retention: 3 object(s) expired" "superseded_versions"
expect_deletes "superseded_versions" "$(expected_log '[
  {"name": "drills/drill-2020.txt", "generation": None, "status": 204},
  {"name": "snapshots/app-x.db", "generation": "1", "status": 204},
  {"name": "snapshots/app-x.db", "generation": None, "status": 204}
]')"
python3 - "$(mock_dump)" <<'PY'
import json, sys
dump = json.loads(sys.argv[1])
kept = dump["objects"]["snapshots/app-y.db"]["versions"]
assert len(kept) == 1 and kept[0]["timeDeleted"] is None, f"recent version must be kept: {kept}"
assert "heartbeat.txt" in dump["objects"], "heartbeat object must never be expired"
PY
pass superseded_versions

# 15. Restore drill across a paginated listing: the newest snapshot by
#     updated timestamp sits mid-list (name app-1249) and must win.
begin drill_pagination
python3 - "$S_STATE" "$seed_db" <<'PY'
import base64, datetime, json, sys
objects = {}
for i in range(1250):
    ts = (datetime.datetime(2026, 10, 26, tzinfo=datetime.timezone.utc)
          + datetime.timedelta(minutes=i)).strftime("%Y-%m-%dT%H:%M:%SZ")
    content = open(sys.argv[2], "rb").read() if i == 1249 else b"junk"
    objects[f"snapshots/app-{i:04d}.db"] = {
        "versions": [{"generation": 1, "updated": ts, "timeDeleted": None,
                      "content_b64": base64.b64encode(content).decode()}]}
json.dump({"objects": objects}, open(sys.argv[1], "w"))
PY
start_mock "$S_STATE"
run_drill
expect_rc 0 "drill_pagination"
expect_contains "DRILL PASS" "drill_pagination"
expect_contains "newest off-site snapshot: snapshots/app-1249.db" "drill_pagination"
pass drill_pagination

# 16. Restore drill with no snapshots must fail loudly.
begin drill_no_snapshots
start_mock "$S_STATE"
run_drill
expect_rc 1 "drill_no_snapshots"
expect_contains "no snapshot found" "drill_no_snapshots"
pass drill_no_snapshots

# 17. Restore drill over a failed listing must fail visibly.
begin drill_list_failure
gen_objects "$S_STATE" '{
  "snapshots/app-1.db": {"versions": [{"generation": 1, "updated": "2026-10-26T00:00:00Z", "timeDeleted": None, "content_b64": ""}]}
}'
echo '{"list_status": 403}' > "$S_BEHAVIOR"
start_mock "$S_STATE" "$S_BEHAVIOR"
run_drill
expect_rc 1 "drill_list_failure"
expect_contains "listing gs://test-bucket/snapshots/ failed" "drill_list_failure"
pass drill_list_failure

echo "all scenarios passed"
