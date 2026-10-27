#!/usr/bin/env bash
# Test suite for ops/rust-api-activate. The service manager and the health
# endpoints are mocked: a restart script flips readiness after a delay and
# reports the sha of the release `current` pointed at when it ran, and a
# local HTTP server answers /health/ready and /health/live from that state.
# Covers the happy path, argument and digest validation, broken-release
# rollback (including verification of the rollback itself), double failure,
# concurrent-activation refusal, manual rollback via the installed release,
# stale-binary detection through the /health/live version, retention, the
# failed-atomic-rename path (previous release must stay active, nothing
# restarted), and a static guard keeping the non-atomic BSD swap shim inside
# the test-mode branch only.
# Nothing touches systemd, the VM, or production.
set -Eeuo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
activate="$repo/ops/rust-api-activate"
temp="$(mktemp -d)"
server_pid=""

cleanup() {
  [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
  pkill -f "mock-activate-service.py $temp" 2>/dev/null || true
  rm -rf "$temp"
}
trap cleanup EXIT

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS $1"; }

sha_of() { printf '%-40s' "$1" | tr ' ' '0'; }
digest_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" | awk '{print $1}'
  else
    shasum -a 256 "$@" | awk '{print $1}'
  fi
}

fresh_env() {
  rm -rf "$temp/root" "$temp/incoming" "$temp/ctrl"
  mkdir -p "$temp/root/releases" "$temp/incoming" "$temp/ctrl"
  : >"$temp/ctrl/broken"
  : >"$temp/ctrl/stale"
  : >"$temp/ctrl/restarts"
}

start_server() {
  [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
  rm -f "$temp/port" # otherwise the stale port of the previous mock is read
  python3 "$temp/mock-activate-service.py" "$temp" &
  server_pid=$!
  for _ in $(seq 1 50); do
    [ -s "$temp/port" ] && break
    sleep 0.1
  done
  port="$(cat "$temp/port")"
}

cat >"$temp/mock-activate-service.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ctrl = os.path.join(sys.argv[1], "ctrl")

def read(name, default=""):
    try:
        return open(os.path.join(ctrl, name)).read().strip()
    except OSError:
        return default

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/health/ready":
            ok = read("ready") == "1"
            body = b'{"status":"ok"}' if ok else b'{"status":"degraded","error":"db"}'
            self.send_response(200 if ok else 503)
        elif self.path == "/health/live":
            body = json.dumps({"status": "ok", "version": read("serve_sha", "none")}).encode()
            self.send_response(200)
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(sys.argv[1], "port"), "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY

cat >"$temp/systemctl-mock" <<'SH'
#!/usr/bin/env bash
# Models systemctl restart rust-api: readiness drops, the release that
# `current` points at RIGHT NOW becomes the serving version after a short
# startup window, unless that release is listed broken (never ready) or
# stale (ready but reports the wrong build sha).
set -Eeuo pipefail
ctrl="${RUST_API_CTRL:?}"
root="${RUST_API_ROOT:?}"
printf 'restart\n' >>"$ctrl/restarts"
sha="$(basename "$(readlink "$root/current")")"
echo 0 >"$ctrl/ready"
if grep -qx "$sha" "$ctrl/broken" 2>/dev/null; then
  exit 0  # service "starts" but never becomes ready
fi
if grep -qx "$sha" "$ctrl/stale" 2>/dev/null; then
  sleep "${MOCK_START_DELAY:-0}"
  echo "ffffffffffffffffffffffffffffffffffffffff" >"$ctrl/serve_sha"
  echo 1 >"$ctrl/ready"
  exit 0
fi
sleep "${MOCK_START_DELAY:-0}"
echo "$sha" >"$ctrl/serve_sha"
echo 1 >"$ctrl/ready"
SH
chmod +x "$temp/systemctl-mock"

# run_activate ATTEMPTS SHA DIGEST — sets $rc and $out
run_activate() {
  local attempts="$1"; shift
  set +e
  out="$(env \
    RUST_API_TEST_MODE=1 \
    RUST_API_ROOT="$temp/root" \
    RUST_API_INCOMING="$temp/incoming" \
    RUST_API_LOCK_FILE="$temp/lock" \
    RUST_API_RESTART_CMD="$temp/systemctl-mock" \
    RUST_API_HEALTH_BASE="http://127.0.0.1:${port}" \
    RUST_API_READY_ATTEMPTS="$attempts" \
    RUST_API_CTRL="$temp/ctrl" \
    MOCK_START_DELAY="${MOCK_START_DELAY:-0}" \
    bash "$activate" "$1" "$2" 2>&1)"
  rc=$?
  set -e
}

upload() { # upload SHA — fake artifact in incoming/
  local sha="$1"
  printf '#!/bin/sh\n# rust-api %s\nwhile :; do sleep 3600; done\n' "$sha" >"$temp/incoming/rust-api-$sha"
}

mkrel() { # mkrel SHA — installed release (binary + .digest), not activated
  mkdir -p "$temp/root/releases/$1"
  printf '#!/bin/sh\n# %s\n' "$1" >"$temp/root/releases/$1/rust-api"
  chmod 0755 "$temp/root/releases/$1/rust-api"
  printf '%s\n' "$(digest_of "$temp/root/releases/$1/rust-api")" >"$temp/root/releases/$1/.digest"
}

current_sha() { basename "$(readlink "$temp/root/current")"; }

# --- fixture: previous release installed and serving --------------------------
PREV="$(sha_of a)"
NEW="$(sha_of b)"
fresh_env
start_server
mkdir -p "$temp/root/releases/$PREV"
printf '#!/bin/sh\n# %s\n' "$PREV" >"$temp/root/releases/$PREV/rust-api"
chmod 0755 "$temp/root/releases/$PREV/rust-api"
printf '%s\n' "$(digest_of "$temp/root/releases/$PREV/rust-api")" >"$temp/root/releases/$PREV/.digest"
ln -sfn "$temp/root/releases/$PREV" "$temp/root/current"
echo "$PREV" >"$temp/ctrl/serve_sha"
echo 1 >"$temp/ctrl/ready"

# --- 1. happy path ------------------------------------------------------------
upload "$NEW"
DIGEST="$(digest_of "$temp/incoming/rust-api-$NEW")"
run_activate 6 "$NEW" "$DIGEST"
[ "$rc" -eq 0 ] || die "happy path failed (rc=$rc): $out"
[ "$(current_sha)" = "$NEW" ] || die "current not switched: $(current_sha)"
grep -q "deployed $NEW" <<<"$out" || die "no success line: $out"
[ ! -e "$temp/incoming/rust-api-$NEW" ] || die "uploaded copy not removed"
grep -q "activated=$NEW previous=$PREV" "$temp/root/history.log" || die "history missing: $(cat "$temp/root/history.log")"
curl -fsS "http://127.0.0.1:${port}/health/live" | grep -q "$NEW" || die "server not serving $NEW"
pass "happy path: activated, verified serving, incoming removed, history kept"

# --- 2. invalid arguments -----------------------------------------------------
run_activate 2 "tooshort" "$DIGEST"
[ "$rc" -eq 2 ] || die "bad sha accepted (rc=$rc)"
run_activate 2 "$NEW" "notadigest"
[ "$rc" -eq 2 ] || die "bad digest accepted (rc=$rc)"
pass "argument validation"

# --- 3. digest mismatch -------------------------------------------------------
upload "$NEW"
run_activate 2 "$NEW" "$(printf '0%.0s' $(seq 64))"
[ "$rc" -eq 3 ] || die "digest mismatch not rejected (rc=$rc): $out"
[ "$(current_sha)" = "$NEW" ] || die "current must be untouched by a rejected upload"
pass "digest mismatch rejected"

# --- 4. missing upload and no installed release -------------------------------
MISSING="$(sha_of c)"
run_activate 2 "$MISSING" "$(printf '0%.0s' $(seq 64))"
[ "$rc" -eq 3 ] || die "missing upload not rejected (rc=$rc)"
grep -q "missing regular uploaded binary" <<<"$out" || die "wrong error: $out"
pass "missing upload rejected"

# --- 5. broken new release rolls back and verifies the rollback ---------------
BROKEN="$(sha_of d)"
upload "$BROKEN"
BD="$(digest_of "$temp/incoming/rust-api-$BROKEN")"
echo "$BROKEN" >>"$temp/ctrl/broken"
run_activate 3 "$BROKEN" "$BD"
[ "$rc" -eq 1 ] || die "broken release must fail the job (rc=$rc): $out"
[ "$(current_sha)" = "$NEW" ] || die "rollback did not restore NEW: $(current_sha)"
grep -q "rollback complete" <<<"$out" || die "rollback not verified: $out"
[ -e "$temp/incoming/rust-api-$BROKEN" ] || die "upload must be kept on failure"
curl -fsS "http://127.0.0.1:${port}/health/live" | grep -q "$NEW" || die "server not back on NEW"
pass "broken release: rolled back to NEW, rollback verified, job failed"

# --- 6. double failure: rollback also broken ----------------------------------
echo "$NEW" >>"$temp/ctrl/broken"
run_activate 3 "$BROKEN" "$BD"
[ "$rc" -eq 1 ] || die "double failure must fail (rc=$rc)"
grep -q "manual intervention required" <<<"$out" || die "double failure not reported: $out"
pass "double failure reported as requiring manual intervention"

# --- 7. stale binary served after restart (version check) ---------------------
sed -i.bak "/^$NEW\$/d" "$temp/ctrl/broken"
rm -f "$temp/ctrl/broken.bak"
STALE="$(sha_of e)"
upload "$STALE"
SD="$(digest_of "$temp/incoming/rust-api-$STALE")"
echo "$STALE" >>"$temp/ctrl/stale"
run_activate 4 "$STALE" "$SD"
[ "$rc" -eq 1 ] || die "stale binary must fail activation (rc=$rc): $out"
grep -q "stale binary" <<<"$out" || die "stale-binary reason missing: $out"
[ "$(current_sha)" = "$NEW" ] || die "stale-binary rollback wrong: $(current_sha)"
pass "stale binary detected via /health/live version and rolled back"

# --- 8. concurrent activation refused -----------------------------------------
CONC="$(sha_of f)"
upload "$CONC"
CD="$(digest_of "$temp/incoming/rust-api-$CONC")"
MOCK_START_DELAY=3 env \
  RUST_API_TEST_MODE=1 RUST_API_ROOT="$temp/root" RUST_API_INCOMING="$temp/incoming" \
  RUST_API_LOCK_FILE="$temp/lock" RUST_API_RESTART_CMD="$temp/systemctl-mock" \
  RUST_API_HEALTH_BASE="http://127.0.0.1:${port}" RUST_API_READY_ATTEMPTS=6 \
  RUST_API_CTRL="$temp/ctrl" MOCK_START_DELAY=3 \
  bash "$activate" "$CONC" "$CD" >/dev/null 2>&1 &
slow_pid=$!
sleep 0.5
run_activate 6 "$CONC" "$CD"
[ "$rc" -eq 4 ] || die "concurrent activation not refused (rc=$rc): $out"
wait "$slow_pid" || die "slow first activation failed"
pass "concurrent activation refused while first in flight"

# --- 9. manual rollback via installed release ---------------------------------
# The happy path deleted the upload; re-activating PREV must work from the
# installed release directory and its recorded digest.
PD="$(cat "$temp/root/releases/$PREV/.digest")"
run_activate 6 "$PREV" "$PD"
[ "$rc" -eq 0 ] || die "manual rollback failed (rc=$rc): $out"
[ "$(current_sha)" = "$PREV" ] || die "manual rollback did not switch: $(current_sha)"
curl -fsS "http://127.0.0.1:${port}/health/live" | grep -q "$PREV" || die "not serving PREV"
pass "manual rollback re-activates the installed previous release"

# --- 10. retention ------------------------------------------------------------
# Add seven extra releases with staggered ages, activate once more, then
# expect exactly current + previous + RUST_API_RETAIN_EXTRA to survive.
AGED1="$(sha_of 1a)"
AGED2="$(sha_of 1b)"
AGED3="$(sha_of 1c)"
AGED4="$(sha_of 1d)"
AGED5="$(sha_of 1e)"
AGED6="$(sha_of 1f)"
AGED7="$(sha_of 1g)"
for s in "$AGED1" "$AGED2" "$AGED3" "$AGED4" "$AGED5" "$AGED6" "$AGED7"; do
  mkdir -p "$temp/root/releases/$s"
  printf '#!/bin/sh\n# %s\n' "$s" >"$temp/root/releases/$s/rust-api"
  printf '%s\n' "$(digest_of "$temp/root/releases/$s/rust-api")" >"$temp/root/releases/$s/.digest"
  touch -t 202601010000 "$temp/root/releases/$s"
done
upload "$NEW"
ND="$(digest_of "$temp/incoming/rust-api-$NEW")"
run_activate 6 "$NEW" "$ND"
[ "$rc" -eq 0 ] || die "retention activation failed (rc=$rc): $out"
[ "$(current_sha)" = "$NEW" ] || die "current changed by retention"
[ -d "$temp/root/releases/$PREV" ] || die "previous release pruned"
remaining="$(find "$temp/root/releases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[ "$remaining" -eq 5 ] || die "expected current+previous+3 retained, found $remaining: $(ls "$temp/root/releases")"
for s in "$AGED1" "$AGED2" "$AGED3" "$AGED4" "$AGED5" "$AGED6" "$AGED7"; do
  [ -d "$temp/root/releases/$s" ] && die "aged release $s not pruned"
done
grep -q "retention: removing" <<<"$out" || die "retention not logged: $out"
pass "retention keeps current + previous + 3 newest, logs removals"

# --- 11. failed atomic rename: previous release stays active and serving ------
# Production must never fall back to rm+mv of the active symlink. The test
# hook RUST_API_FAIL_ATOMIC_SWAP makes the rename fail (as a real EBUSY or
# cross-device rename would on the VM); activation must fail non-zero with
# the previous release still live and nothing restarted.
fresh_env
start_server
mkrel "$PREV"
ln -sfn "$temp/root/releases/$PREV" "$temp/root/current"
echo "$PREV" >"$temp/ctrl/serve_sha"
echo 1 >"$temp/ctrl/ready"
upload "$NEW"
ND2="$(digest_of "$temp/incoming/rust-api-$NEW")"
restarts_before="$(wc -l <"$temp/ctrl/restarts" | tr -d ' ')"
RUST_API_FAIL_ATOMIC_SWAP=1 run_activate 3 "$NEW" "$ND2"
[ "$rc" -eq 1 ] || die "failed atomic rename must fail activation (rc=$rc): $out"
grep -q "atomic current-symlink replacement failed" <<<"$out" || die "no atomic-failure message: $out"
[ "$(current_sha)" = "$PREV" ] || die "current changed by failed rename: $(current_sha)"
curl -fsS "http://127.0.0.1:${port}/health/live" | grep -q "$PREV" || die "previous release not still serving"
[ "$(wc -l <"$temp/ctrl/restarts" | tr -d ' ')" = "$restarts_before" ] || die "service was restarted despite the swap failing"
[ -e "$temp/incoming/rust-api-$NEW" ] || die "upload must be kept on swap failure"
[ -e "$temp/root/releases/$NEW/rust-api" ] || die "validated artifact should still be installed pre-swap"
[ ! -e "$temp/root/.current-next" ] || die "staging symlink not cleaned up after failed rename"
pass "failed atomic rename: previous release untouched, activation failed, no restart"

# --- 12. production atomicity guard (static) ----------------------------------
# The non-atomic rm+mv of the active symlink must exist ONLY inside the
# test-only BSD shim, and its single call site must be test-mode guarded.
# shellcheck disable=SC2016  # the grep pattern is intentionally a literal
[ "$(grep -c 'rm -f "$current"' "$activate")" -eq 1 ] \
  || die "non-atomic removal of the active symlink appears more than once"
grep -q 'swap_to_bsd_nonatomic()' "$activate" || die "BSD shim function missing"
call_lines="$(grep -n 'swap_to_bsd_nonatomic' "$activate" | grep -v '()' \
  | awk -F: '$2 !~ /^[[:space:]]*#/ {print $1}')"
[ "$(printf '%s\n' "$call_lines" | wc -l | tr -d ' ')" -eq 1 ] || die "BSD shim call sites: $call_lines"
call_line="$(printf '%s\n' "$call_lines")"
prev_line="$(sed -n "$((call_line - 1))p" "$activate")"
grep -q 'test_mode' <<<"$prev_line" || die "BSD fallback call is not test-mode guarded: $prev_line"
pass "static guard: non-atomic fallback exists only under the test-mode branch"

echo "all rust-api-activate tests passed"
