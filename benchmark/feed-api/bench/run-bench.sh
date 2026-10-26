#!/usr/bin/env bash
# Local performance harness (measurement tooling only — not part of the
# submission). Copies the seed database, starts the release server with the
# requested tuning knobs, runs a k6 profile, samples RSS/CPU, and prints one
# markdown table row.
#
#   SEED_DB=…/seed/feed.db TOKENS=…/seed/tokens.json \
#   LABEL="rp2 NORMAL" READ_POOL=2 SYNC=NORMAL VUS=200 DURATION=90s \
#     bash bench/run-bench.sh [k6-script]
#
# Environment:
#   SEED_DB   path to the generated seed/feed.db (required)
#   TOKENS    path to seed/tokens.json (required)
#   LABEL     row label (required)
#   SCRIPT    k6 script; default bench/stress.js ("upstream" alias loads upstream profile)
#   VUS / DURATION / RAMP_UP   k6 parameters
#   READ_POOL / SYNC / CACHE_KIB / MMAP_KIB  server tuning knobs
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${BIN:-$HERE/../target/release/feed-api}"
SEED_DB="${SEED_DB:?set SEED_DB}"
TOKENS="${TOKENS:?set TOKENS}"
LABEL="${LABEL:?set LABEL}"
SCRIPT="${1:-}"
case "${SCRIPT:-stress}" in
  upstream) SCRIPT="$SCRIPT_UPSTREAM" ;;
  "" | stress) SCRIPT="$HERE/stress.js" ;;
esac
VUS="${VUS:-100}"
DURATION="${DURATION:-60s}"
RAMP_UP="${RAMP_UP:-15s}"
PORT="${BENCH_PORT:-3100}"

# k6 holds one socket per VU; raise the fd limit to the hard limit if allowed.
ulimit -n "$(ulimit -Hn)" 2>/dev/null || true

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill -TERM "$SERVER_PID" 2>/dev/null || true
  [ -n "$SERVER_PID" ] && wait "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

cp "$SEED_DB" "$WORK/feed.db"

export JWT_SECRET=twelve-dollar-challenge
export HOST=127.0.0.1
export PORT
export SQLITE_PATH="$WORK/feed.db"
export SQLITE_READ_POOL="${READ_POOL:-2}"
export SQLITE_SYNCHRONOUS="${SYNC:-NORMAL}"
[ -n "${CACHE_KIB:-}" ] && export SQLITE_CACHE_KIB="$CACHE_KIB" || true
[ -n "${MMAP_KIB:-}" ] && export SQLITE_MMAP_KIB="$MMAP_KIB" || true

# /usr/bin/time reports peak RSS when the server exits; server logs land in
# the same file (the 60 s metrics line carries SQLite busy/locked counters).
/usr/bin/time -l "$BIN" >"$WORK/server.log" 2>&1 &
TIME_PID=$!
for _ in $(seq 1 50); do
  SERVER_PID="$(pgrep -P "$TIME_PID" | head -1 || true)"
  [ -n "$SERVER_PID" ] && curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.2
done
[ -n "$SERVER_PID" ] || { echo "server failed to start"; cat "$WORK/server.log"; exit 1; }

# Sample CPU% and RSS once a second while the load runs.
(
  while kill -0 "$SERVER_PID" 2>/dev/null; do
    ps -o %cpu=,rss= -p "$SERVER_PID" >>"$WORK/samples.txt" 2>/dev/null || break
    sleep 1
  done
) &

K6_RC=0
k6 run --summary-export "$WORK/summary.json" \
  -e "BASE_URL=http://127.0.0.1:$PORT" -e "VUS=$VUS" -e "DURATION=$DURATION" -e "RAMP_UP=$RAMP_UP" \
  -e "TOKENS=$TOKENS" "$SCRIPT" >"$WORK/k6.log" 2>&1 || K6_RC=$?

kill -TERM "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

if [ "$K6_RC" -ne 0 ]; then
  echo "k6 failed (rc=$K6_RC); tail:"; tail -20 "$WORK/k6.log"
  exit "$K6_RC"
fi

RPS="$(jq -r '.metrics.http_reqs.rate' "$WORK/summary.json")"
COUNT="$(jq -r '.metrics.http_reqs.count' "$WORK/summary.json")"
P50="$(jq -r '.metrics.http_req_duration.med' "$WORK/summary.json")"
P95="$(jq -r '.metrics.http_req_duration["p(95)"]' "$WORK/summary.json")"
P99="$(jq -r '.metrics.http_req_duration["p(99)"]' "$WORK/summary.json")"
FAIL="$(jq -r '(.metrics.http_req_failed.value // 0) * 100' "$WORK/summary.json")"
CPU_AVG="$(awk '{s+=$1; n++} END {if (n) printf "%.1f", s/n; else print "n/a"}' "$WORK/samples.txt")"
CPU_MAX="$(awk 'BEGIN{m=0} {if ($1>m) m=$1} END {printf "%.1f", m}' "$WORK/samples.txt")"
RSS_KB="$(awk 'BEGIN{m=0} {if ($2>m) m=$2} END {print m}' "$WORK/samples.txt")"
MAXRSS_BYTES="$(grep -i 'maximum resident set size' "$WORK/server.log" | awk '{print $1}' || echo n/a)"
BUSY="$(grep -o 'sqlite_busy_errors=[0-9]*' "$WORK/server.log" | tail -1 | cut -d= -f2 || echo 0)"
LOCKED="$(grep -o 'sqlite_locked_errors=[0-9]*' "$WORK/server.log" | tail -1 | cut -d= -f2 || echo 0)"

printf '| %s | %.0f | %.1f | %.1f | %.1f | %.2f%% | %s / %s | %s | %s | %s |\n' \
  "$LABEL" "$RPS" "$P50" "$P95" "$P99" "$FAIL" "$CPU_AVG" "$CPU_MAX" "$RSS_KB" "${BUSY:-0}" "${LOCKED:-0}"
echo "# requests=$COUNT maxrss_bytes=$MAXRSS_BYTES" >&2
