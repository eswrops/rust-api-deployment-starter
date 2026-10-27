#!/usr/bin/env bash
# Run ON THE VM (as root, via the operator IAP session) after the feedapi
# isolation rollout: verifies the full permission matrix from
# docs/feed-api-isolation-plan.md. The public feedapi identity must NOT be
# able to read production secrets or SQLite, and must retain exactly its own
# paths. Every negative test must FAIL to pass; any unexpected ALLOW (or
# lost ALLOW) is a hard failure with a non-zero exit.
#
#   sudo bash ops/verify-feedapi-isolation.sh
#
# Test hooks (used by ops/test/test-verify-feedapi-isolation.sh; production
# uses the defaults):
#   VERIFY_PREFIX   path prefix prepended to every checked path [""]
#   VERIFY_AS_FEEDAPI  command prefix running a command as feedapi
#                      ["sudo runuser -u feedapi --"]
#   VERIFY_SUDO     command standing in for sudo (the -l check) ["sudo"]
#   VERIFY_SYSTEMCTL   command standing in for systemctl ["systemctl"]
set -Eeuo pipefail

VERIFY_PREFIX="${VERIFY_PREFIX:-}"
VERIFY_AS_FEEDAPI="${VERIFY_AS_FEEDAPI:-sudo runuser -u feedapi --}"
VERIFY_SUDO="${VERIFY_SUDO:-sudo}"
VERIFY_SYSTEMCTL="${VERIFY_SYSTEMCTL:-systemctl}"

# shellcheck disable=SC2086  # VERIFY_AS_FEEDAPI is an intentional word-split prefix
# shellcheck disable=SC2329  # invoked indirectly via check_deny/check_allow
as_feedapi() { $VERIFY_AS_FEEDAPI "$@"; }
p() { printf '%s%s' "$VERIFY_PREFIX" "$1"; }

passed=0
failed=0

# check_deny LABEL CMD... — the command must FAIL (permission denied).
check_deny() {
  local label="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "FAIL   (allowed!): $label"
    failed=$((failed + 1))
  else
    echo "ok  denied: $label"
    passed=$((passed + 1))
  fi
}

# check_allow LABEL CMD... — the command must SUCCEED.
check_allow() {
  local label="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "ok  allowed: $label"
    passed=$((passed + 1))
  else
    echo "FAIL   (denied!): $label"
    failed=$((failed + 1))
  fi
}

echo "== feedapi must NOT reach production material"
check_deny "read /etc/rust-api/app.env" as_feedapi test -r "$(p /etc/rust-api/app.env)"
check_deny "read /etc/rust-api/backup.env" as_feedapi test -r "$(p /etc/rust-api/backup.env)"
check_deny "read /etc/rust-api/backup-gcs-key.json" as_feedapi test -r "$(p /etc/rust-api/backup-gcs-key.json)"
check_deny "read production SQLite" as_feedapi test -r "$(p /var/lib/rust-api/app.db)"
check_deny "write production SQLite" as_feedapi test -w "$(p /var/lib/rust-api/app.db)"
check_deny "enter /var/lib/rust-api/backups/" as_feedapi test -r "$(p /var/lib/rust-api/backups/)"
check_deny "read deployment SSH material" as_feedapi test -r "$(p /home/deploy/.ssh/id_ed25519)"
check_deny "execute rust-api-activate as deploy via sudo" \
  sh -c "$VERIFY_SUDO -u deploy $VERIFY_SUDO -n $(p /usr/local/sbin/rust-api-activate)"

echo "== feedapi must retain its own paths"
check_allow "read own feed.db" as_feedapi test -r "$(p /var/lib/feed-api/feed.db)"
check_allow "write own state directory" as_feedapi test -w "$(p /var/lib/feed-api/)"
check_allow "read /etc/feed-api/env" as_feedapi test -r "$(p /etc/feed-api/env)"
check_allow "execute /opt/feed-api/current/feed-api" as_feedapi test -x "$(p /opt/feed-api/current/feed-api)"

echo "== feedapi has no sudo rights of its own"
# `sudo -l -U` exits 1 precisely when the user is NOT allowed, so the exit
# code cannot be trusted under pipefail — decide on the output text only.
sudo_l="$($VERIFY_SUDO -l -U feedapi 2>/dev/null || true)"
if grep -qi "not allowed" <<<"$sudo_l"; then
  echo "ok  denied: feedapi has no sudoers entries"
  passed=$((passed + 1))
else
  echo "FAIL   (allowed!): feedapi appears to hold sudo rights"
  failed=$((failed + 1))
fi

echo "== service identities"
unit_user() { $VERIFY_SYSTEMCTL show -p User --value "$1" 2>/dev/null; }
# shellcheck disable=SC2329  # invoked indirectly via check_allow
unit_active() { $VERIFY_SYSTEMCTL is-active --quiet "$1" 2>/dev/null; }
if [ "$(unit_user feed-api.service)" = "feedapi" ]; then
  echo "ok  feed-api.service runs as feedapi"
  passed=$((passed + 1))
else
  echo "FAIL: feed-api.service User is '$(unit_user feed-api.service)', expected feedapi"
  failed=$((failed + 1))
fi
if [ "$(unit_user rust-api.service)" = "rustapi" ]; then
  echo "ok  rust-api.service still runs as rustapi"
  passed=$((passed + 1))
else
  echo "FAIL: rust-api.service User is '$(unit_user rust-api.service)', expected rustapi"
  failed=$((failed + 1))
fi
check_allow "feed-api.service active" unit_active feed-api.service
check_allow "rust-api.service active" unit_active rust-api.service

echo
if [ "$failed" -eq 0 ]; then
  echo "ISOLATION VERIFIED: $passed check(s) passed"
  exit 0
fi
echo "ISOLATION FAILURE: $failed check(s) failed, $passed passed" >&2
exit 1
