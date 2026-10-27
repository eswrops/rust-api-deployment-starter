#!/usr/bin/env bash
# Test suite for ops/rust-api-backfill-digests. Fixtures represent releases
# created by BOTH activation-script generations: old-style installs have an
# executable binary but no .digest (the previous script did not record one);
# new-style installs carry a .digest recorded at install time.
#
# Covers: dry-run default, atomic recording on --apply, idempotent re-runs,
# mismatched-digest refusal (never overwritten), invalid/ambiguous paths
# (bad names, symlinks, missing/non-executable binaries), lock conflict with
# an in-flight activation, and the integration property the tool exists for:
# a backfilled old-style release becomes usable as a manual-rollback target
# via ops/rust-api-activate's re-activation path (mocked service manager and
# health endpoints; nothing touches systemd, the VM, or production).
set -Eeuo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
backfill="$repo/ops/rust-api-backfill-digests"
activate="$repo/ops/rust-api-activate"
temp="$(mktemp -d)"
server_pid=""

cleanup() {
  [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
  pkill -f "mock-backfill-service.py $temp" 2>/dev/null || true
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

fresh_root() {
  rm -rf "$temp/root"
  mkdir -p "$temp/root/releases"
}

# run_backfill ARGS... — sets $rc and $out
run_backfill() {
  set +e
  out="$(env \
    RUST_API_TEST_MODE=1 \
    RUST_API_ROOT="$temp/root" \
    RUST_API_LOCK_FILE="$temp/lock" \
    bash "$backfill" "$@" 2>&1)"
  rc=$?
  set -e
}

# mk_old_release SHA — old-generation install: executable binary, NO .digest
mk_old_release() {
  mkdir -p "$temp/root/releases/$1"
  printf '#!/bin/sh\n# rust-api %s (installed before digests existed)\n' "$1" >"$temp/root/releases/$1/rust-api"
  chmod 0755 "$temp/root/releases/$1/rust-api"
}

# --- fixture: one old-style and one new-style release --------------------------
OLD="$(sha_of a)"
NEW="$(sha_of b)"
fresh_root
mk_old_release "$OLD"
mkdir -p "$temp/root/releases/$NEW"
printf '#!/bin/sh\n# rust-api %s\n' "$NEW" >"$temp/root/releases/$NEW/rust-api"
chmod 0755 "$temp/root/releases/$NEW/rust-api"
printf '%s\n' "$(digest_of "$temp/root/releases/$NEW/rust-api")" >"$temp/root/releases/$NEW/.digest"
ln -sfn "$temp/root/releases/$OLD" "$temp/root/current"

# --- 1. dry run is the default: nothing is written ------------------------------
run_backfill
[ "$rc" -eq 0 ] || die "dry run failed (rc=$rc): $out"
grep -q "would record digest" <<<"$out" || die "dry run did not report the plan: $out"
grep -q "already recorded and correct" <<<"$out" || die "new-style release not recognised: $out"
[ ! -e "$temp/root/releases/$OLD/.digest" ] || die "dry run wrote a digest file"
[ "$(basename "$(readlink "$temp/root/current")")" = "$OLD" ] || die "dry run touched current"
pass "dry-run default: reports actions, writes nothing"

# --- 2. --apply records the missing digest atomically ---------------------------
old_binary_digest="$(digest_of "$temp/root/releases/$OLD/rust-api")"
run_backfill --apply
[ "$rc" -eq 0 ] || die "apply failed (rc=$rc): $out"
[ "$(cat "$temp/root/releases/$OLD/.digest")" = "$old_binary_digest" ] || die "recorded digest does not match the binary"
[ "$(stat -f '%Lp' "$temp/root/releases/$OLD/.digest" 2>/dev/null || stat -c '%a' "$temp/root/releases/$OLD/.digest")" = "644" ] || die "digest file mode not 0644"
[ "$(digest_of "$temp/root/releases/$OLD/rust-api")" = "$old_binary_digest" ] || die "binary contents changed by backfill"
[ "$(basename "$(readlink "$temp/root/current")")" = "$OLD" ] || die "apply touched current"
pass "--apply: digest recorded from the installed binary, binary and current untouched"

# --- 3. idempotent re-run --------------------------------------------------------
run_backfill --apply
[ "$rc" -eq 0 ] || die "idempotent re-run failed (rc=$rc): $out"
grep -q "already recorded and correct" <<<"$out" || die "re-run did not recognise recorded digest: $out"
grep -q "0 digest(s) recorded" <<<"$out" || die "re-run recorded something: $out"
pass "idempotent: second apply records nothing new"

# --- 4. mismatched existing digest is refused, never overwritten -----------------
BAD="$(sha_of c)"
mk_old_release "$BAD"
printf '%s\n' "$(printf '0%.0s' $(seq 64))" >"$temp/root/releases/$BAD/.digest"
run_backfill --apply
[ "$rc" -eq 1 ] || die "mismatched digest must fail the run (rc=$rc): $out"
[ "$(cat "$temp/root/releases/$BAD/.digest")" = "$(printf '0%.0s' $(seq 64))" ] || die "mismatched digest was overwritten"
grep -q "NOT overwriting" <<<"$out" || die "mismatch not reported loudly: $out"
pass "mismatched existing digest refused and preserved"

# --- 5. invalid release entries are refused --------------------------------------
NOTEXEC="$(sha_of d)"
mk_old_release "$NOTEXEC"
chmod 0644 "$temp/root/releases/$NOTEXEC/rust-api"
NOBIN="$(sha_of e)"
mkdir -p "$temp/root/releases/$NOBIN"
LINKY="$(sha_of f)"
mkdir -p "$temp/elsewhere/$LINKY"
printf '#!/bin/sh\n' >"$temp/elsewhere/$LINKY/rust-api"
ln -sfn "$temp/elsewhere/$LINKY" "$temp/root/releases/$LINKY"
mkdir -p "$temp/root/releases/lost+found"
run_backfill --apply
[ "$rc" -eq 1 ] || die "invalid entries must fail the run (rc=$rc): $out"
grep -q "not executable" <<<"$out" || die "non-executable binary not reported: $out"
grep -q "missing or not a regular file" <<<"$out" || die "missing binary not reported: $out"
grep -q "symlink (ambiguous)" <<<"$out" || die "symlinked release not reported: $out"
grep -q "not a 40-hex release name" <<<"$out" || die "invalid name not reported: $out"
[ ! -e "$temp/root/releases/$NOTEXEC/.digest" ] || die "digest written for non-executable binary"
[ ! -e "$temp/root/releases/$NOBIN/.digest" ] || die "digest written for missing binary"
[ ! -e "$temp/elsewhere/$LINKY/.digest" ] || die "digest written outside the releases tree"
pass "invalid, non-executable, missing and symlinked entries refused fail-visibly"

# --- 6. lock conflict: refuse while an activation holds the lock -----------------
LOCKED="$(sha_of g)"
mk_old_release "$LOCKED"
if command -v flock >/dev/null 2>&1; then
  flock "$temp/lock" -c 'sleep 4' &
  lock_pid=$!
  sleep 0.3
  run_backfill --apply
  [ "$rc" -eq 4 ] || die "flock-held lock not honoured (rc=$rc): $out"
  [ ! -e "$temp/root/releases/$LOCKED/.digest" ] || die "backfill ran despite held lock"
  kill "$lock_pid" 2>/dev/null || true
  wait "$lock_pid" 2>/dev/null || true
else
  mkdir "$temp/lock.d"
  sleep 5 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" >"$temp/lock.d/pid"
  run_backfill --apply
  [ "$rc" -eq 4 ] || die "mkdir lock not honoured (rc=$rc): $out"
  [ ! -e "$temp/root/releases/$LOCKED/.digest" ] || die "backfill ran despite held lock"
  kill "$holder_pid" 2>/dev/null || true
  rm -rf "$temp/lock.d"
fi
pass "activation lock held elsewhere: backfill refuses (exit 4)"

# --- 7. end-to-end: backfilled old release becomes a manual-rollback target ------
# Mock service manager + health endpoints, mirroring test-rust-api-activate.
rm -rf "$temp/root" "$temp/incoming" "$temp/ctrl" "$temp/port"
mkdir -p "$temp/root/releases" "$temp/incoming" "$temp/ctrl"

cat >"$temp/mock-backfill-service.py" <<'PY'
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
            body = b'{"status":"ok"}' if ok else b'{"status":"degraded"}'
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
set -Eeuo pipefail
ctrl="${RUST_API_CTRL:?}"
root="${RUST_API_ROOT:?}"
sha="$(basename "$(readlink "$root/current")")"
echo 0 >"$ctrl/ready"
echo "$sha" >"$ctrl/serve_sha"
echo 1 >"$ctrl/ready"
SH
chmod +x "$temp/systemctl-mock"

rm -f "$temp/port"
python3 "$temp/mock-backfill-service.py" "$temp" &
server_pid=$!
for _ in $(seq 1 50); do
  [ -s "$temp/port" ] && break
  sleep 0.1
done
port="$(cat "$temp/port")"

run_activate() { # run_activate SHA DIGEST — sets $rc and $out
  set +e
  out="$(env \
    RUST_API_TEST_MODE=1 \
    RUST_API_ROOT="$temp/root" \
    RUST_API_INCOMING="$temp/incoming" \
    RUST_API_LOCK_FILE="$temp/lock" \
    RUST_API_RESTART_CMD="$temp/systemctl-mock" \
    RUST_API_HEALTH_BASE="http://127.0.0.1:${port}" \
    RUST_API_READY_ATTEMPTS=6 \
    RUST_API_CTRL="$temp/ctrl" \
    bash "$activate" "$1" "$2" 2>&1)"
  rc=$?
  set -e
}

# PREV is an OLD-generation release (no .digest), installed and serving.
PREV="$(sha_of 1a)"
mk_old_release "$PREV"
ln -sfn "$temp/root/releases/$PREV" "$temp/root/current"
echo "$PREV" >"$temp/ctrl/serve_sha"
echo 1 >"$temp/ctrl/ready"

# A newer release is deployed through the normal upload path, so PREV becomes
# a retained older release and its incoming copy is removed after success.
NEXT="$(sha_of 2b)"
printf '#!/bin/sh\n# rust-api %s\n' "$NEXT" >"$temp/incoming/rust-api-$NEXT"
ND="$(digest_of "$temp/incoming/rust-api-$NEXT")"
run_activate "$NEXT" "$ND"
[ "$rc" -eq 0 ] || die "deployment of NEXT failed (rc=$rc): $out"
[ ! -e "$temp/incoming/rust-api-$NEXT" ] || die "upload not removed after success"

# Manual rollback to the old-generation release WITHOUT a backfilled digest
# must fail closed: the re-activation path cannot verify what it would run.
PD="$(digest_of "$temp/root/releases/$PREV/rust-api")"
run_activate "$PREV" "$PD"
[ "$rc" -eq 3 ] || die "rollback without digest must be refused (rc=$rc): $out"
grep -q "missing regular uploaded binary" <<<"$out" || die "unexpected refusal reason: $out"

# Backfill the old release, then the SAME manual rollback succeeds end-to-end:
# digest verified from the installed binary, symlink swapped, service
# restarted, /health/live verified serving the rolled-back SHA.
run_backfill --apply
[ "$rc" -eq 0 ] || die "backfill before rollback failed (rc=$rc): $out"
grep -q "digest(s) recorded" <<<"$out" || die "backfill summary missing: $out"
run_activate "$PREV" "$PD"
[ "$rc" -eq 0 ] || die "manual rollback to backfilled release failed (rc=$rc): $out"
[ "$(basename "$(readlink "$temp/root/current")")" = "$PREV" ] || die "rollback did not switch current"
curl -fsS "http://127.0.0.1:${port}/health/live" | grep -q "$PREV" || die "not serving the rolled-back release"
pass "manual rollback uses an older retained release only after its digest is backfilled"

echo "all rust-api-backfill-digests tests passed"
