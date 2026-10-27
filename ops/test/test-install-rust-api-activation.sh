#!/usr/bin/env bash
# End-to-end test suite for ops/install-rust-api-activation.sh, run against
# the isolated mock VM (ops/test/mock-install-vm.sh): a fake gcloud journals
# and executes ssh payloads inside a sandbox, sudo models the production
# sudoers rule, and systemctl/curl model the two services' real endpoints
# (feed-api answers ONLY /health). No network, no gcloud, no production
# resource is contacted.
#
# Scenarios: dry-run performs no mutations; successful installation; the
# feed-api endpoint must be /health (a regressed installer fails its own
# health gate); backfill dry-run failures (nonzero exit, malformed summary,
# digest mismatch, lock contention) and backfill apply failure all stop the
# rollout and restore the previous script; post-install validation failure
# restores; installation is idempotent; services are never restarted.
set -Eeuo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
installer="$repo/ops/install-rust-api-activation.sh"
# shellcheck source=ops/test/mock-install-vm.sh
. "$repo/ops/test/mock-install-vm.sh"

temp="$(mktemp -d)"
cleanup() { rm -rf "$temp"; }
trap cleanup EXIT

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS $1"; }

digest_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" | awk '{print $1}'
  else
    shasum -a 256 "$@" | awk '{print $1}'
  fi
}

sbin() { printf '%s/usr/local/sbin/%s' "$MOCK_VM_ROOT" "$1"; }
installed() { digest_of "$(sbin rust-api-activate)"; }

fresh_scenario() { # fresh_scenario — clean mock VM with production-like state
  mock_vm_init "$temp/mockvm"
  mock_vm_fixture
  mock_vm_clear_journal
  ORIGINAL_SHA="$(installed)"
  NEW_SCRIPT_SHA="$(digest_of "$repo/ops/rust-api-activate")"
}

# A backfill stub standing in for the installed tool, emitting canned
# dry-run/apply behaviour from state files.
write_stub() { # write_stub DRY_EXIT DRY_OUT_FILE APPLY_EXIT
  cat >"$temp/backfill-stub.sh" <<STUB
#!/usr/bin/env bash
set -Eeuo pipefail
case "\${1:-}" in
  --apply)
    if [ -f "$MOCK_VM_STATE/stub-apply-exit" ]; then
      printf 'backfill: apply failing per scenario\n' >&2
      exit "\$(cat "$MOCK_VM_STATE/stub-apply-exit")"
    fi
    exit 0
    ;;
  *)
    if [ -f "$MOCK_VM_STATE/stub-dry-out" ]; then
      cat "$MOCK_VM_STATE/stub-dry-out"
    fi
    if [ -f "$MOCK_VM_STATE/stub-dry-exit" ]; then
      exit "\$(cat "$MOCK_VM_STATE/stub-dry-exit")"
    fi
    exit 0
    ;;
esac
STUB
  chmod +x "$temp/backfill-stub.sh"
  printf '%s\n' "$temp/backfill-stub.sh" >"$MOCK_VM_STATE/backfill-stub"
  printf '%s\n' "$1" >"$MOCK_VM_STATE/stub-dry-exit"
  if [ "$2" != "none" ]; then printf '%s\n' "$2" >"$MOCK_VM_STATE/stub-dry-out"; fi
  if [ "${3:-none}" != "none" ]; then printf '%s\n' "$3" >"$MOCK_VM_STATE/stub-apply-exit"; fi
}

# suite-local copy of the repo used for the endpoint-regression scenario
# (the installer derives REPO from its own path, so the patched copy needs a
# functioning git tree with the committed ops tooling).
make_repo_copy() {
  git clone -q --shared "$repo" "$temp/repo"
  cp "$installer" "$temp/repo/ops/install-rust-api-activation.sh"
  cp "$repo/ops/install-rust-api-activation-lib.sh" "$temp/repo/ops/"
}

# --- 1. dry run performs no mutations -------------------------------------------
fresh_scenario
run_installer "$installer"
[ "$rc" -eq 0 ] || die "dry run failed (rc=$rc): $out"
grep -q "dry run — plan" <<<"$out" || die "dry run did not plan: $out"
for mutation in "install -m 0755" "cp -p" "mv -Tf" "rust-api-backfill-digests" "=== scp ==="; do
  grep -qF "$mutation" "$MOCK_VM_JOURNAL" && die "dry run mutated: $mutation"
done
[ "$(installed)" = "$ORIGINAL_SHA" ] || die "dry run changed the installed script"
[ -z "$(find "$(dirname "$(sbin rust-api-activate)")" -name 'rust-api-activate.bak-*')" ] || die "dry run created a backup"
[ ! -e "$MOCK_VM_ROOT/opt/rust-api/releases/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/.digest" ] || die "dry run wrote a digest"
[ "$(grep -c '=== ssh ===' "$MOCK_VM_JOURNAL")" -eq 1 ] || die "dry run should issue exactly one read-only ssh command"
pass "dry run: read-only preflight only, no mutations, no uploads"

# --- 2. successful installation ---------------------------------------------------
fresh_scenario
run_installer "$installer" --apply
[ "$rc" -eq 0 ] || die "apply failed (rc=$rc): $out"
grep -q "DONE" <<<"$out" || die "no completion record: $out"
[ "$(installed)" = "$NEW_SCRIPT_SHA" ] || die "installed script is not the reviewed replacement"
backup_count="$(find "$(dirname "$(sbin rust-api-activate)")" -name 'rust-api-activate.bak-*' ! -name '*.owner' | wc -l | tr -d ' ')"
[ "$backup_count" -eq 1 ] || die "expected exactly one backup, found $backup_count"
backup_file="$(find "$(dirname "$(sbin rust-api-activate)")" -name 'rust-api-activate.bak-*' ! -name '*.owner')"
[ "$(digest_of "$backup_file")" = "$ORIGINAL_SHA" ] || die "backup is not the previous script"
[ "$(cat "$(sbin rust-api-activate).owner")" = "root:root 755" ] || die "installed ownership/mode not modeled root:root 755"
[ -f "$MOCK_VM_ROOT/opt/rust-api/releases/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/.digest" ] \
  || die "backfill did not record the missing digest"
[ -z "$(find "$MOCK_VM_ROOT/home/operator" -name 'rust-api-activate.stage.*')" ] || die "staged copy not removed"
grep -q "feed-api /health OK" <<<"$out" || die "feed-api health not verified: $out"
grep -q "unexpectedly invoked" <<<"$out" && die "mock gcloud saw an unexpected invocation: $out"
grep -q "MUTATION" "$MOCK_VM_JOURNAL" && die "successful apply mutated a systemd unit"
pass "apply: replacement installed, backup kept, digests backfilled, staging cleaned"

# --- 3. feed-api endpoint: /health, never /health/live (regression guard) --------
# Checked against the successful run's journal: the URL is followed by a
# closing paren in the installer source, so this match cannot hit /health/live.
grep -q "127.0.0.1:8081/health)" "$MOCK_VM_JOURNAL" || die "feed-api probe missing: /health"
grep -qE "8081/health/live|8081/health/ready" "$MOCK_VM_JOURNAL" \
  && die "installer probed a nonexistent feed-api endpoint (only /health exists)"
grep -q "http://127.0.0.1:8080/health/live" "$MOCK_VM_JOURNAL" || die "rust-api live probe missing"
grep -q "http://127.0.0.1:8080/health/ready" "$MOCK_VM_JOURNAL" || die "rust-api ready probe missing"
pass "endpoints: rust-api live+ready on 8080, feed-api /health (JSON verified) on 8081"

# --- 3b. a regressed installer probing 8081/health/live fails its own gate --------
# The fake curl models feed-api as answering ONLY /health: any other path is a
# 404, so an installer that regresses to /health/live fails its health gate and
# restores the previous script.
fresh_scenario
make_repo_copy
sed 's#127.0.0.1:8081/health)#127.0.0.1:8081/health/live)#' \
  "$temp/repo/ops/install-rust-api-activation.sh" >"$temp/repo/ops/patched.tmp"
mv "$temp/repo/ops/patched.tmp" "$temp/repo/ops/install-rust-api-activation.sh"
run_installer "$temp/repo/ops/install-rust-api-activation.sh" --apply
[ "$rc" -ne 0 ] || die "regressed endpoint probe did not fail the rollout"
grep -q "post-install health verification failed" <<<"$out" || die "wrong failure: $out"
[ "$(installed)" = "$ORIGINAL_SHA" ] || die "regressed run left a changed script behind"
pass "regressed feed-api probe (8081/health/live, 404 in the model) fails and restores"

# --- 4. backfill dry-run failures prevent --apply and restore ----------------------
deny_case() { # deny_case LABEL DRY_EXIT DRY_OUT
  fresh_scenario
  write_stub "$2" "$3" none
  run_installer "$installer" --apply
  [ "$rc" -ne 0 ] || die "$1: rollout must fail"
  grep -q "backfill dry run rejected" <<<"$out" || die "$1: no rejection reason: $out"
  grep -q -- "--apply" "$MOCK_VM_JOURNAL" && die "$1: apply ran despite rejected dry run"
  [ "$(installed)" = "$ORIGINAL_SHA" ] || die "$1: previous script not restored"
  [ -z "$(find "$(dirname "$(sbin rust-api-activate)")" -name 'rust-api-activate.bak-*')" ] \
    || die "$1: backup not moved back during restore"
}
deny_case "nonzero exit without summary" 1 "backfill: boom without a summary line"
deny_case "malformed summary" 0 "backfill: APPLY summary: scanned 3 releases, looks fine"
deny_case "digest mismatch refusal" 1 "backfill: FAIL: abc: existing .digest does not match — NOT overwriting
backfill: DRY RUN summary: 2 release(s) scanned, 0 digest(s) recorded, 1 already correct, 1 refused"
deny_case "lock contention" 4 "backfill: an activation is in progress; refusing to run concurrently"
pass "backfill dry-run failures (exit/malformed/mismatch/lock) all fail closed and restore"

# --- 5. partial failure: dry run passes, apply fails --------------------------------
fresh_scenario
write_stub 0 "backfill: APPLY summary: 2 release(s) scanned, 2 digest(s) recorded, 0 already correct, 0 refused" 1
run_installer "$installer" --apply
[ "$rc" -ne 0 ] || die "apply failure must fail the rollout"
grep -q "backfill apply failed" <<<"$out" || die "wrong failure: $out"
[ "$(installed)" = "$ORIGINAL_SHA" ] || die "previous script not restored after apply failure"
grep -q -- "--apply" "$MOCK_VM_JOURNAL" || die "apply should have been attempted"
pass "backfill apply failure: rollout fails and previous script is restored"

# --- 6. post-install validation failure restores -------------------------------------
fresh_scenario
printf '3\n' >"$MOCK_VM_STATE/probe-exit"
run_installer "$installer" --apply
[ "$rc" -ne 0 ] || die "validation failure must fail the rollout"
grep -q "post-install validation failed" <<<"$out" || die "wrong failure: $out"
grep -q "previous script restored and verified" <<<"$out" || die "restore not verified: $out"
[ "$(installed)" = "$ORIGINAL_SHA" ] || die "previous script not restored after validation failure"
pass "validation failure: automatic restore to the verified previous script"

# --- 7. idempotent re-installation ----------------------------------------------------
fresh_scenario
run_installer "$installer" --apply
[ "$rc" -eq 0 ] || die "first apply failed: $out"
mock_vm_clear_journal
run_installer "$installer" --apply
[ "$rc" -eq 0 ] || die "second apply failed (rc=$rc): $out"
grep -q "already matches the reviewed replacement" <<<"$out" || die "second run not idempotent: $out"
grep -qF "cp -p /usr/local/sbin/rust-api-activate" "$MOCK_VM_JOURNAL" && die "second run created another backup"
grep -qF ".rust-api-activate.new" "$MOCK_VM_JOURNAL" && die "second run reinstalled the script"
[ "$(installed)" = "$NEW_SCRIPT_SHA" ] || die "script changed by idempotent re-run"
[ "$(cat "$MOCK_VM_STATE/service.rust-api")" = "active" ] || die "rust-api no longer active"
[ "$(cat "$MOCK_VM_STATE/service.feed-api")" = "active" ] || die "feed-api no longer active"
pass "idempotent: second apply skips backup/install, services still active"

# --- 8. services are never restarted by any scenario ------------------------------------
grep -q "MUTATION" "$MOCK_VM_JOURNAL" && die "a scenario mutated a systemd unit"
pass "no restart/stop/start of any systemd unit across all scenarios"

echo "all install-rust-api-activation tests passed"
