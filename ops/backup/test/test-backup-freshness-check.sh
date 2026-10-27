#!/usr/bin/env bash
# Test suite for ops/backup/backup-freshness-check against the local GCS
# mock (mock-gcs.py). Two properties matter more than the rest:
#   1. redaction: no substring of the access token may appear in any output
#      (happy path, HTTP failures, malformed-token refusals, gcloud errors);
#   2. transport: the tokeninfo diagnostic must carry the token in a POST
#      form body, never in a URL query string (the mock logs every
#      tokeninfo request and rejects GET outright).
# Also covers the freshness verdicts themselves (fresh, stale heartbeat,
# stale/missing drill, malformed heartbeat, network failure). Nothing
# leaves the machine: no Google access, no production bucket.
set -Eeuo pipefail
test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
backup_dir="$(cd -- "$test_dir/.." && pwd)"
temp="$(mktemp -d)"
mock_pid=""

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

SECRET="ya29.attributed-freshness-test-secret"

# Contains the token in any form? (value itself, or its unambiguous prefix)
assert_no_token() {
  local where="$1" haystack="$2"
  case "$haystack" in
    *"$SECRET"*|*"attributed-freshness-test"*)
      die "token leaked into $where" ;;
  esac
}

start_mock() { # start_mock <state-file> [behavior-file]
  local state="$1" behavior="${2:-}"
  if [ -n "$mock_pid" ]; then
    kill "$mock_pid" 2>/dev/null || true
    wait "$mock_pid" 2>/dev/null || true
    mock_pid=""
  fi
  rm -f "$temp/port"
  local args=(--state "$state" --port-file "$temp/port")
  [ -n "$behavior" ] && args+=(--behavior "$behavior")
  python3 "$test_dir/mock-gcs.py" "${args[@]}" 2>/dev/null &
  mock_pid=$!
  for _ in $(seq 1 50); do
    [ -s "$temp/port" ] && break
    kill -0 "$mock_pid" 2>/dev/null || die "mock-gcs did not start"
    sleep 0.1
  done
  port="$(cat "$temp/port")"
  api="http://127.0.0.1:${port}"
}

# run_check cmd... — captures combined output in $out and status in $rc
run_check() {
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
}

# state_with <heartbeat-iso|none|garbage> <drill-age-days|none>
write_state() {
  python3 - "$@" <<'PY'
import base64, json, sys
from datetime import datetime, timedelta, timezone

heartbeat, drill_days = sys.argv[1], sys.argv[2]
now = datetime.now(timezone.utc)
objects = {}
if heartbeat == "garbage":
    content = "everything is fine, definitely\n"
elif heartbeat != "none":
    content = f"backup ok {heartbeat}\n"
else:
    content = None
if content is not None:
    objects["heartbeat.txt"] = {"versions": [{
        "generation": 1, "updated": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "timeDeleted": None,
        "content_b64": base64.b64encode(content.encode()).decode()}]}
if drill_days != "none":
    stamp = (now - timedelta(days=int(drill_days))).strftime("%Y%m%dT%H%M%SZ")
    objects[f"drills/drill-{stamp}.txt"] = {"versions": [{
        "generation": 1, "updated": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "timeDeleted": None,
        "content_b64": base64.b64encode(b"drill: PASS\n").decode()}]}
json.dump({"objects": objects}, open(sys.argv[3], "w"))
PY
}

check_env() {
  env GCS_BUCKET=test-bucket GCS_API_BASE="$api" TOKENINFO_URL="$api/tokeninfo" \
    GCS_ACCESS_TOKEN="$SECRET" "$backup_dir/backup-freshness-check"
}

fresh_iso() { python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=2)).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }
stale_iso() { python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=40)).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }

# --- 1. fresh heartbeat + fresh drill -> pass -------------------------------

write_state "$(fresh_iso)" 1 "$temp/state.json"
start_mock "$temp/state.json"
run_check check_env
[ "$rc" -eq 0 ] || die "fresh state should pass (rc=$rc): $out"
case "$out" in *"all checks passed"*) ;; *) die "missing success line: $out" ;; esac
assert_no_token "fresh-run output" "$out"
pass "fresh heartbeat and drill pass"

# --- 2. stale heartbeat -> fail with age ------------------------------------

write_state "$(stale_iso)" 1 "$temp/state.json"
start_mock "$temp/state.json"
run_check check_env
[ "$rc" -eq 1 ] || die "stale heartbeat should fail (rc=$rc)"
case "$out" in *"40h old"*) ;; *) die "missing staleness detail: $out" ;; esac
assert_no_token "stale-heartbeat output" "$out"
pass "stale heartbeat fails with age detail"

# --- 3. malformed heartbeat body -> fail ------------------------------------

write_state garbage 1 "$temp/state.json"
start_mock "$temp/state.json"
run_check check_env
[ "$rc" -eq 1 ] || die "garbage heartbeat should fail (rc=$rc)"
case "$out" in *"no 'backup ok"*|*"no backup ok"*) ;; *) die "missing malformed-heartbeat detail: $out" ;; esac
assert_no_token "malformed-heartbeat output" "$out"
pass "malformed heartbeat fails"

# --- 4. 403 on the heartbeat object -> token identity via POST tokeninfo ----

write_state "$(fresh_iso)" 1 "$temp/state.json"
cat > "$temp/behavior.json" <<EOF
{"get_fail": {"heartbeat.txt": 403}}
EOF
start_mock "$temp/state.json" "$temp/behavior.json"
run_check check_env
[ "$rc" -eq 1 ] || die "403 heartbeat should fail (rc=$rc)"
case "$out" in *"token identity: monitor@example.iam.gserviceaccount.com"*)
  ;; *) die "tokeninfo attribution missing: $out" ;; esac
case "$out" in *"response:"*) ;; *) die "HTTP response excerpt missing: $out" ;; esac
assert_no_token "403-heartbeat output" "$out"
dump="$(curl -sS "http://127.0.0.1:${port}/_/dump")"
requests="$(jq -c '.tokeninfo_requests' <<<"$dump")"
[ "$(jq 'length' <<<"$requests")" -eq 1 ] || die "expected exactly one tokeninfo request: $requests"
[ "$(jq -r '.[0].method' <<<"$requests")" = "POST" ] || die "tokeninfo must be POST: $requests"
[ "$(jq -r '.[0].path' <<<"$requests")" = "/tokeninfo" ] || die "token must not travel in a query string: $requests"
jq -e '.[0].body | contains("access_token=ya29.attributed-freshness-test-secret")' <<<"$requests" >/dev/null \
  || die "token missing from POST body: $requests"
pass "403 heartbeat attributes identity via POST body (never URL)"

# --- 5. 403 on the drill listing -> same attribution ------------------------

write_state "$(fresh_iso)" 1 "$temp/state.json"
cat > "$temp/behavior.json" <<EOF
{"list_status": 403}
EOF
start_mock "$temp/state.json" "$temp/behavior.json"
run_check check_env
[ "$rc" -eq 1 ] || die "403 listing should fail (rc=$rc)"
case "$out" in *"token identity:"*) ;; *) die "tokeninfo attribution missing: $out" ;; esac
assert_no_token "403-listing output" "$out"
pass "403 drill listing attributes identity"

# --- 6. malformed GCS_ACCESS_TOKEN -> refusal without echoing the value -----

write_state "$(fresh_iso)" 1 "$temp/state.json"
start_mock "$temp/state.json"
bad_token="eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0aGlzLWlzLWEtc2VjcmV0LXZhbHVlIn0.x"
run_check env GCS_BUCKET=test-bucket GCS_API_BASE="$api" TOKENINFO_URL="$api/tokeninfo" \
  GCS_ACCESS_TOKEN="$bad_token" "$backup_dir/backup-freshness-check"
[ "$rc" -eq 1 ] || die "non-ya29 token should be refused (rc=$rc)"
case "$out" in *"GCS_ACCESS_TOKEN"*) ;; *) die "refusal must name the source: $out" ;; esac
case "$out" in *"$bad_token"*|*"c2VjcmV0"*) die "malformed token leaked into output" ;; esac
pass "malformed GCS_ACCESS_TOKEN refused without echo"

# --- 7. gcloud fallback: happy, failing, and wrong-type ---------------------

mkdir -p "$temp/bin"
cat > "$temp/bin/gcloud" <<'SHIM'
#!/usr/bin/env bash
case "${FAKE_GCLOUD_MODE:-ok}" in
  fail) echo "ERROR: (gcloud.auth) simulated credential failure" >&2; exit 1 ;;
  wrong) printf '%s' "${FAKE_GCLOUD_TOKEN:?}"; exit 0 ;;
  *) printf '%s' "${FAKE_GCLOUD_TOKEN:?}"; exit 0 ;;
esac
SHIM
chmod +x "$temp/bin/gcloud"

write_state "$(fresh_iso)" 1 "$temp/state.json"
start_mock "$temp/state.json"
run_check env PATH="$temp/bin:$PATH" GCS_BUCKET=test-bucket GCS_API_BASE="$api" \
  TOKENINFO_URL="$api/tokeninfo" FAKE_GCLOUD_TOKEN="$SECRET" \
  "$backup_dir/backup-freshness-check"
[ "$rc" -eq 0 ] || die "gcloud-provided token should pass (rc=$rc): $out"
assert_no_token "gcloud-happy output" "$out"
pass "gcloud token fallback passes"

run_check env PATH="$temp/bin:$PATH" GCS_BUCKET=test-bucket GCS_API_BASE="$api" \
  TOKENINFO_URL="$api/tokeninfo" FAKE_GCLOUD_MODE=fail \
  "$backup_dir/backup-freshness-check"
[ "$rc" -eq 1 ] || die "gcloud failure should fail cleanly (rc=$rc)"
case "$out" in *"cannot obtain an access token via gcloud"*) ;; *) die "missing gcloud failure message: $out" ;; esac
case "$out" in *"simulated credential failure"*) ;; *) die "gcloud stderr should stay visible: $out" ;; esac
assert_no_token "gcloud-failure output" "$out"
pass "gcloud failure surfaces error without token capture"

run_check env PATH="$temp/bin:$PATH" GCS_BUCKET=test-bucket GCS_API_BASE="$api" \
  TOKENINFO_URL="$api/tokeninfo" FAKE_GCLOUD_MODE=wrong FAKE_GCLOUD_TOKEN="$bad_token" \
  "$backup_dir/backup-freshness-check"
[ "$rc" -eq 1 ] || die "wrong-type gcloud credential should be refused (rc=$rc)"
case "$out" in *"$bad_token"*) die "wrong-type credential leaked into output" ;; esac
pass "wrong-type gcloud credential refused without echo"

# --- 8. network failure -> fail with 'network' ------------------------------

start_mock "$temp/state.json"   # state irrelevant; port reserved below
kill "$mock_pid" 2>/dev/null || true
wait "$mock_pid" 2>/dev/null || true
mock_pid=""
run_check env GCS_BUCKET=test-bucket GCS_API_BASE="http://127.0.0.1:1" \
  TOKENINFO_URL="http://127.0.0.1:1/tokeninfo" GCS_ACCESS_TOKEN="$SECRET" \
  "$backup_dir/backup-freshness-check"
[ "$rc" -eq 1 ] || die "network failure should fail (rc=$rc)"
case "$out" in *"HTTP network"*) ;; *) die "missing network detail: $out" ;; esac
assert_no_token "network-failure output" "$out"
pass "network failure reported as failure"

# --- 9. no drill reports -> fail ---------------------------------------------

write_state "$(fresh_iso)" none "$temp/state.json"
start_mock "$temp/state.json"
run_check check_env
[ "$rc" -eq 1 ] || die "missing drills should fail (rc=$rc)"
case "$out" in *"never succeeded"*) ;; *) die "missing drill detail: $out" ;; esac
pass "absent drill reports fail"

echo "all freshness-check tests passed"
