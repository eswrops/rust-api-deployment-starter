#!/usr/bin/env bash
# Test suite for ops/verify-feedapi-isolation.sh, run against a fixture tree
# with the verify script's env hooks (VERIFY_PREFIX / VERIFY_AS_FEEDAPI /
# VERIFY_SUDO / VERIFY_SYSTEMCTL). "feedapi" is simulated by running the
# checks as the current user against fixture modes; no root, no users, no VM.
# Covers: the all-clear matrix; an unexpected ALLOW (secret made readable);
# a lost ALLOW (own database unreadable); the service identity check; and
# the sudo-rights check.
set -Eeuo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
verify="$repo/ops/verify-feedapi-isolation.sh"
temp="$(mktemp -d)"
cleanup() {
  # The fixtures include no-read directories; restore traversal explicitly
  # before removing (chmod -R alone cannot descend into a 000 directory).
  chmod u+rwx "$temp" "$temp/var" "$temp/var/lib" "$temp/var/lib/rust-api" \
    "$temp/var/lib/rust-api/backups" 2>/dev/null || true
  chmod -R u+rwx "$temp" 2>/dev/null || true
  rm -rf "$temp"
}
trap cleanup EXIT

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS $1"; }

# run_verify — sets $rc and $out; hooks point at the fixture
run_verify() {
  set +e
  out="$(VERIFY_PREFIX="$temp" \
    VERIFY_AS_FEEDAPI="$temp/bin/as-feedapi" \
    VERIFY_SUDO="$temp/bin/fake-sudo" \
    VERIFY_SYSTEMCTL="$temp/bin/fake-systemctl" \
    bash "$verify" 2>&1)"
  rc=$?
  set -e
}

# --- fixtures + fakes ----------------------------------------------------------
mkdir -p "$temp/bin" "$temp/state" \
  "$temp/etc/rust-api" "$temp/etc/feed-api" \
  "$temp/var/lib/rust-api/backups" "$temp/var/lib/feed-api" \
  "$temp/opt/feed-api/current" "$temp/home/deploy/.ssh"

printf 'secret\n' >"$temp/etc/rust-api/app.env"
printf 'secret\n' >"$temp/etc/rust-api/backup.env"
printf 'key\n' >"$temp/etc/rust-api/backup-gcs-key.json"
printf 'db\n' >"$temp/var/lib/rust-api/app.db"
printf 'snapshot\n' >"$temp/var/lib/rust-api/backups/snap.db"
printf 'feed\n' >"$temp/var/lib/feed-api/feed.db"
printf 'env\n' >"$temp/etc/feed-api/env"
printf 'binary\n' >"$temp/opt/feed-api/current/feed-api"
printf 'ssh-key\n' >"$temp/home/deploy/.ssh/id_ed25519"

# The "feedapi" identity is the current user; fixture modes decide outcomes.
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$temp/bin/as-feedapi"

# fake sudo: -l -U feedapi reads a scenario file; the deploy-chain probe is
# denied unless the scenario says otherwise.
cat >"$temp/bin/fake-sudo" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-l" ]; then
  if [ -f "$STATE_DIR/sudo-allowed" ]; then
    echo "User feedapi may run the following commands"
    exit 0
  fi
  echo "User feedapi is not allowed to run sudo on host."
  exit 1
fi
exit 1
SH

cat >"$temp/bin/fake-systemctl" <<'SH'
#!/usr/bin/env bash
unit="${*: -1}"
if [ "${1:-}" = "show" ]; then
  cat "$STATE_DIR/unit-user.$unit" 2>/dev/null || echo "root"
  exit 0
fi
if [ "${1:-}" = "is-active" ]; then
  [ "$(cat "$STATE_DIR/unit-active.$unit" 2>/dev/null || echo no)" = "yes" ] || exit 3
  exit 0
fi
exit 1
SH

printf '#!/usr/bin/env bash\nexec "$@"\n' >"$temp/bin/as-feedapi"
chmod +x "$temp/bin/as-feedapi" "$temp/bin/fake-sudo" "$temp/bin/fake-systemctl"
export STATE_DIR="$temp/state"

reset_fixture() {
  chmod 000 "$temp/etc/rust-api/app.env" "$temp/etc/rust-api/backup.env" \
    "$temp/etc/rust-api/backup-gcs-key.json" "$temp/var/lib/rust-api/app.db"
  chmod 000 "$temp/var/lib/rust-api/backups"
  chmod 000 "$temp/home/deploy/.ssh/id_ed25519"
  chmod 0644 "$temp/var/lib/feed-api/feed.db" "$temp/etc/feed-api/env"
  chmod 0755 "$temp/opt/feed-api/current/feed-api"
  chmod 0755 "$temp/var/lib/feed-api"
  printf 'feedapi\n' >"$temp/state/unit-user.feed-api.service"
  printf 'rustapi\n' >"$temp/state/unit-user.rust-api.service"
  printf 'yes\n' >"$temp/state/unit-active.feed-api.service"
  printf 'yes\n' >"$temp/state/unit-active.rust-api.service"
  rm -f "$temp/state/sudo-allowed"
}

# --- 1. the all-clear matrix passes ---------------------------------------------
reset_fixture
run_verify
[ "$rc" -eq 0 ] || die "clean matrix failed (rc=$rc): $out"
grep -q "ISOLATION VERIFIED" <<<"$out" || die "no verification banner: $out"
pass "clean isolation matrix passes"

# --- 2. an unexpected ALLOW (secret readable) fails ------------------------------
chmod 0644 "$temp/etc/rust-api/backup-gcs-key.json"
run_verify
[ "$rc" -eq 1 ] || die "readable backup key must fail"
if grep -q "read /etc/rust-api/backup-gcs-key.json" <<<"$out" \
  && grep -q "allowed!" <<<"$out"; then
  : # failure correctly attributed
else
  die "failure not attributed to the backup key: $out"
fi
reset_fixture
pass "unexpected ALLOW (backup key readable) fails the run"

# --- 3. a lost ALLOW (own database unreadable) fails ------------------------------
chmod 000 "$temp/var/lib/feed-api/feed.db"
run_verify
[ "$rc" -eq 1 ] || die "unreadable own database must fail"
grep -q "read own feed.db" <<<"$out" || die "own-db failure not reported: $out"
reset_fixture
pass "lost ALLOW (own feed.db unreadable) fails the run"

# --- 4. wrong service identity fails ----------------------------------------------
printf 'rustapi\n' >"$temp/state/unit-user.feed-api.service"
run_verify
[ "$rc" -eq 1 ] || die "feed-api running as rustapi must fail"
grep -q "expected feedapi" <<<"$out" || die "identity failure not reported: $out"
reset_fixture
pass "feed-api.service running as the wrong user fails"

# --- 5. feedapi sudo rights fail ----------------------------------------------------
printf 'allowed\n' >"$temp/state/sudo-allowed"
run_verify
[ "$rc" -eq 1 ] || die "feedapi sudo rights must fail"
grep -q "hold sudo rights" <<<"$out" || die "sudo failure not reported: $out"
reset_fixture
pass "feedapi holding sudo rights fails"

echo "all verify-feedapi-isolation tests passed"
