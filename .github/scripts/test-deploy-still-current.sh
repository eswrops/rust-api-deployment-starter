#!/usr/bin/env bash
# Test suite for .github/scripts/deploy-still-current.sh, run against a
# throwaway bare repository acting as origin (no GitHub access).
#
# Covered deployments-ordering decisions:
#   * a current deployment: EXPECTED_SHA == tip -> proceed (exit 0);
#   * an older run superseded on main -> exit 1, new tip reported;
#   * main advancing during deployment preparation is the same decision at a
#     later point in time (the script is called twice by the deploy job);
#   * unverifiable state (remote unreachable, missing ref) -> exit 2 so the
#     caller fails closed instead of activating an unverified artifact;
#   * exact-match strictness: a prefix of the tip is "superseded", not equal.
set -Eeuo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS $1"; }

# origin.git — bare remote; work — clone used to advance it
git init -q --bare -b main "$temp/origin.git"
git clone -q "$temp/origin.git" "$temp/work"
git -C "$temp/work" config user.email ci-test@example.invalid
git -C "$temp/work" config user.name "CI test"

commit() {
  echo "$1" >"$temp/work/file.txt"
  git -C "$temp/work" add -A
  git -C "$temp/work" commit -qm "$1"
  git -C "$temp/work" push -q origin main
}

tip() { git -C "$temp/origin.git" rev-parse refs/heads/main; }

# run_check EXPECTED_SHA — sets $rc and $out
run_check() {
  set +e
  out="$(cd "$temp/work" && EXPECTED_SHA="$1" \
    bash "$script_dir/deploy-still-current.sh" 2>&1)"
  rc=$?
  set -e
}

# --- 1. a current deployment ---------------------------------------------------
commit c1
first="$(tip)"
run_check "$first"
[ "$rc" -eq 0 ] || die "current run not recognised (rc=$rc): $out"
[ "$out" = "$first" ] || die "script did not report the tip: $out"
pass "current deployment: EXPECTED_SHA is the tip of main"

# --- 2. older run superseded before artifact upload -----------------------------
commit c2
second="$(tip)"
run_check "$first"
[ "$rc" -eq 1 ] || die "superseded run not detected (rc=$rc): $out"
[ "$out" = "$second" ] || die "script did not report the NEW tip: $out"
pass "superseded run: main advanced, older SHA refused with the new tip named"

# --- 3. main advances during deployment preparation -----------------------------
# Same call as the final pre-activation re-check: the tip moved AGAIN between
# the first check and this one.
commit c3
run_check "$second"
[ "$rc" -eq 1 ] || die "mid-flight supersede not detected (rc=$rc): $out"
pass "main advancing during preparation is caught by the re-check"

# --- 4. unverifiable: unreachable remote ----------------------------------------
set +e
out="$(cd "$temp/work" && EXPECTED_SHA="$first" REMOTE="$temp/does-not-exist" \
  bash "$script_dir/deploy-still-current.sh" 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 2 ] || die "unreachable remote must be exit 2, got $rc"
[ -z "$out" ] || die "unverifiable run must print no tip: $out"
pass "unreachable remote: exit 2 (fail closed), no tip printed"

# --- 5. unverifiable: missing ref -----------------------------------------------
set +e
out="$(cd "$temp/work" && EXPECTED_SHA="$first" REMOTE_REF="refs/heads/nope" \
  bash "$script_dir/deploy-still-current.sh" 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 2 ] || die "missing ref must be exit 2, got $rc"
pass "missing ref: exit 2 (fail closed)"

# --- 6. strict equality: a SHA prefix is superseded ------------------------------
run_check "${second:0:12}"
[ "$rc" -eq 1 ] || die "SHA prefix wrongly accepted (rc=$rc): $out"
pass "partial SHA is not a match"

# --- 7. missing EXPECTED_SHA is a usage error ------------------------------------
set +e
out="$(cd "$temp/work" && bash "$script_dir/deploy-still-current.sh" 2>/dev/null)"
rc=$?
set -e
[ "$rc" -ne 0 ] || die "missing EXPECTED_SHA must not pass"
pass "missing EXPECTED_SHA refused"

echo "all deploy-still-current tests passed"
