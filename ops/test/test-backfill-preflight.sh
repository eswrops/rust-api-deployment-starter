#!/usr/bin/env bash
# Unit tests for backfill_preflight_check (ops/install-rust-api-activation-lib.sh)
# — the fail-closed gate between the backfill dry run and `--apply`.
# Covers: successful dry run; nonzero exit without a summary; malformed
# summary; refused releases (digest mismatch shape); lock contention; and a
# dry run whose tool exits 0 but emits FAIL diagnostics (partial failure).
# Pure fixtures — no SSH, no sudo, no VM, no filesystem side effects.
set -Eeuo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ops/install-rust-api-activation-lib.sh
. "$repo/ops/install-rust-api-activation-lib.sh"

temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS $1"; }

# run_check RC — writes $1 as the fixture output, runs the gate, sets rc/reason
run_check() {
  local rc="$1"
  printf '%s\n' "$FIXTURE" >"$temp/out"
  set +e
  reason="$(backfill_preflight_check "$rc" "$temp/out")"
  gate_rc=$?
  set -e
}

CLEAN_SUMMARY="backfill: APPLY summary: 3 release(s) scanned, 2 digest(s) recorded, 1 already correct, 0 refused"

# --- 1. successful dry run permits apply ---------------------------------------
FIXTURE="backfill: $CLEAN_SUMMARY"
run_check 0
[ "$gate_rc" -eq 0 ] || die "clean dry run rejected: $reason"
pass "successful dry run (exit 0, clean summary, 0 refused) permits --apply"

# --- 2. nonzero exit without a summary ------------------------------------------
FIXTURE="backfill: an activation is in progress; refusing to run concurrently"
run_check 4
[ "$gate_rc" -eq 1 ] || die "lock contention must deny (rc=$gate_rc)"
grep -q "exited with status 4" <<<"$reason" || die "wrong reason: $reason"
pass "nonzero exit without summary denied (lock contention shape)"

# --- 3. malformed summary --------------------------------------------------------
FIXTURE="backfill: APPLY summary: scanned 3 releases, looks fine"
run_check 0
[ "$gate_rc" -eq 1 ] || die "malformed summary must deny"
grep -q "malformed" <<<"$reason" || die "wrong reason: $reason"
pass "malformed summary line denied"

# --- 4. digest mismatch: refusals reported --------------------------------------
FIXTURE="backfill: FAIL: abc: existing .digest (deadbeef) does not match the binary (1234) — NOT overwriting; investigate this release
backfill: DRY RUN summary: 3 release(s) scanned, 0 digest(s) recorded, 2 already correct, 1 refused"
run_check 1
[ "$gate_rc" -eq 1 ] || die "digest mismatch must deny"
pass "digest mismatch (refused=1) denied"

# --- 4b. refusals are denied even if the exit code were somehow 0 ----------------
run_check 0
[ "$gate_rc" -eq 1 ] || die "refused>0 must deny regardless of exit status"
pass "nonzero refused count denied even with exit 0"

# --- 5. lock contention with a well-formed summary but nonzero exit --------------
FIXTURE="backfill: $CLEAN_SUMMARY"
run_check 4
[ "$gate_rc" -eq 1 ] || die "nonzero exit must deny even with clean summary"
pass "nonzero exit denied despite well-formed summary"

# --- 6. partial failure: exit 0 but FAIL diagnostics present ---------------------
FIXTURE="backfill: FAIL: xyz: could not compute SHA-256 — refusing
backfill: $CLEAN_SUMMARY"
run_check 0
[ "$gate_rc" -eq 1 ] || die "FAIL diagnostics must deny"
grep -q "diagnostic failures" <<<"$reason" || die "wrong reason: $reason"
pass "exit 0 with FAIL diagnostics denied"

# --- 7. empty output --------------------------------------------------------------
FIXTURE=""
: >"$temp/out"
set +e
reason="$(backfill_preflight_check 0 "$temp/out")"
gate_rc=$?
set -e
[ "$gate_rc" -eq 1 ] || die "empty output must deny"
pass "empty dry-run output denied"

echo "all backfill-preflight tests passed"
