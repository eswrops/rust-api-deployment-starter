#!/usr/bin/env bash
# Release-artifact smoke test: prove the built binary is a working service
# against a THROWAWAY SQLite database before it is uploaded for deployment.
# It never touches production SQLite and runs entirely in a temp directory.
#
#   release-smoke.sh <binary> <expected-git-sha>
#
# 1. the binary exists and is executable (and is a Linux x86-64 ELF);
# 2. a temporary SQLite database is created;
# 3. embedded migrations are applied by the actual release binary
#    (`rust-api migrate`);
# 4. the binary serves with that database;
# 5. /health/live answers 200 and reports the expected build SHA;
# 6. /health/ready answers 200 (real SQLite readiness, not just liveness);
# 7. SIGTERM is delivered;
# 8. the process terminates gracefully (exit code 0, within the deadline);
# 9. all temporary files are removed.
set -Eeuo pipefail

binary="${1:?usage: release-smoke.sh <binary> <expected-git-sha>}"
expected_sha="${2:?usage: release-smoke.sh <binary> <expected-git-sha>}"

[ -f "$binary" ] || { echo "smoke: $binary is not a file" >&2; exit 1; }
[ -x "$binary" ] || { echo "smoke: $binary is not executable" >&2; exit 1; }
file_output="$(file "$binary")"
grep -q 'ELF 64-bit.*x86-64' <<<"$file_output" \
  || { echo "smoke: $binary is not a Linux AMD64 ELF: $file_output" >&2; exit 1; }

smoke_dir="$(mktemp -d)"
api_pid=""
cleanup() {
  if [ -n "$api_pid" ]; then
    kill -TERM "$api_pid" 2>/dev/null || true
    wait "$api_pid" 2>/dev/null || true
  fi
  rm -rf "$smoke_dir"
}
trap cleanup EXIT

base="http://127.0.0.1:18080"
db_url="sqlite://${smoke_dir}/smoke.db?mode=rwc"

echo "smoke: applying embedded migrations with the release binary"
DATABASE_URL="$db_url" "$binary" migrate

echo "smoke: starting $binary on 18080"
APP_BIND="127.0.0.1:18080" DATABASE_URL="$db_url" "$binary" &
api_pid=$!

live_ok=0
for _ in $(seq 1 20); do
  if version="$(curl --fail --silent --max-time 2 "$base/health/live" 2>/dev/null \
    | sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p')" && [ -n "$version" ]; then
    live_ok=1
    break
  fi
  kill -0 "$api_pid" 2>/dev/null || { echo "smoke: binary exited during startup" >&2; exit 1; }
  sleep 0.5
done
[ "$live_ok" -eq 1 ] || { echo "smoke: /health/live did not answer within 10 s" >&2; exit 1; }
[ "$version" = "$expected_sha" ] \
  || { echo "smoke: /health/live reports version '$version', expected '$expected_sha'" >&2; exit 1; }
echo "smoke: /health/live 200, build SHA $version"

ready_ok=0
for _ in $(seq 1 20); do
  if curl --fail --silent --max-time 2 "$base/health/ready" >/dev/null 2>&1; then
    ready_ok=1
    break
  fi
  kill -0 "$api_pid" 2>/dev/null || { echo "smoke: binary exited before readiness" >&2; exit 1; }
  sleep 0.5
done
[ "$ready_ok" -eq 1 ] || { echo "smoke: /health/ready did not answer 200 within 10 s" >&2; exit 1; }
echo "smoke: /health/ready 200 (migrations applied, SQLite reachable)"

kill -TERM "$api_pid"
terminated=0
for _ in $(seq 1 30); do
  if ! kill -0 "$api_pid" 2>/dev/null; then
    terminated=1
    break
  fi
  sleep 0.5
done
[ "$terminated" -eq 1 ] || { echo "smoke: binary did not exit within 15 s of SIGTERM" >&2; exit 1; }
wait_rc=0
wait "$api_pid" || wait_rc=$?
api_pid=""
[ "$wait_rc" -eq 0 ] || { echo "smoke: binary exited with status $wait_rc after SIGTERM" >&2; exit 1; }
echo "smoke: SIGTERM handled gracefully (exit 0)"

echo "smoke ok: migrations applied, /health/live + /health/ready verified, graceful shutdown"
