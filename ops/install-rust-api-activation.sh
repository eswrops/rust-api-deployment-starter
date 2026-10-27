#!/usr/bin/env bash
# Narrowly scoped operator procedure: replace the activation script installed
# on the production VM (rust-api-prod @ us-west1-b) with the reviewed copy
# from this repository, then backfill release digests — WITHOUT rerunning VM
# bootstrap and WITHOUT touching the running service, the `current` symlink,
# or any release binary.
#
#   ops/install-rust-api-activation.sh            # dry run: preflight + plan
#   ops/install-rust-api-activation.sh --apply    # perform the rollout
#
# DRY RUN IS THE DEFAULT. --apply performs VM changes; nothing else here
# asks again — that flag IS the operator approval (plus --allow-dirty below
# if you insist on installing an uncommitted working-tree script).
#
# What --apply does, in order:
#   1. verifies the current service, its health endpoints and active SHA;
#   2. verifies the currently installed activation script (records its
#      SHA-256 as the rollback anchor; skips installation if identical);
#   3. backs up the installed script to
#      /usr/local/sbin/rust-api-activate.bak-<utc-timestamp>;
#   4. installs the reviewed replacement atomically (staged copy + single
#      rename on the same filesystem — the sudoers rule references the
#      path, which does not change);
#   5. validates ownership (root:root 0755), content SHA, bash syntax, the
#      sudoers rule, and the full deploy-user chain
#      (`sudo -u deploy sudo -n /usr/local/sbin/rust-api-activate` must
#      exit 2 = usage error, proving NOPASSWD + script both work);
#   6. uploads rust-api-backfill-digests, runs it in dry-run, then --apply
#      (idempotent; never overwrites; never touches binaries or the
#      symlink);
#   7. re-checks service health: rust-api /health/live (200 + expected
#      build SHA) and /health/ready (200), feed-api /health/live (200);
#   8. on ANY validation failure after installation, restores the backup
#      atomically, verifies its SHA, and exits non-zero.
#
# The VM access pattern matches ops/first-sqlite-deploy.sh: gcloud
# authenticated operator workstation, everything through IAP.
set -Eeuo pipefail

APPLY=0
ALLOW_DIRTY=0
PROJECT="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
ZONE="${GCE_ZONE:-us-west1-b}"
INSTANCE="${GCE_INSTANCE:-rust-api-prod}"
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

usage() { grep '^#' "$0" | head -22; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --project) PROJECT="$2"; shift ;;
    --zone) ZONE="$2"; shift ;;
    --instance) INSTANCE="$2"; shift ;;
    *) usage ;;
  esac
  shift
done
[ -n "$PROJECT" ] || { echo "no GCP project resolved (set GCP_PROJECT_ID)" >&2; exit 1; }

SSH=(gcloud --project="$PROJECT" compute ssh "$INSTANCE" --zone="$ZONE" --tunnel-through-iap --quiet)
SCP=(gcloud --project="$PROJECT" compute scp --tunnel-through-iap --zone="$ZONE")
vm() { "${SSH[@]}" --command="$1"; }
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
sha_local() { sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- resolve the reviewed replacement -----------------------------------------
step "1/7 resolve the reviewed replacement script"
SOURCE_SCRIPT="$TMP/rust-api-activate"
if [ "$ALLOW_DIRTY" -eq 1 ]; then
  echo "WARNING: installing the WORKING TREE copy (uncommitted changes allowed)"
  cp "$REPO/ops/rust-api-activate" "$SOURCE_SCRIPT"
else
  if [ -n "$(git -C "$REPO" status --porcelain -- ops/rust-api-activate)" ]; then
    fail "ops/rust-api-activate has uncommitted changes; commit (or review) first, or pass --allow-dirty"
  fi
  git -C "$REPO" show "HEAD:ops/rust-api-activate" >"$SOURCE_SCRIPT"
fi
NEW_SHA="$(sha_local "$SOURCE_SCRIPT")"
echo "replacement sha256: $NEW_SHA"
bash -n "$SOURCE_SCRIPT" || fail "replacement script does not parse"

# --- remote preflight (read-only) ----------------------------------------------
step "2/7 remote preflight: service, active release, installed script, sudoers"
PREFLIGHT="$(vm 'bash -s' <<'REMOTE'
set -Eeuo pipefail
systemctl is-active --quiet rust-api || { echo "rust-api service not active"; exit 1; }
current="$(readlink -f /opt/rust-api/current)"
live="$(curl --fail --silent --max-time 5 http://127.0.0.1:8080/health/live)"
echo "$live" | grep -q "$(basename "$current")" || { echo "/health/live does not report the active release"; exit 1; }
curl --fail --silent --max-time 5 http://127.0.0.1:8080/health/ready >/dev/null
echo "active_release=$(basename "$current")"
echo "installed_sha=$(sha256sum /usr/local/sbin/rust-api-activate | awk '{print $1}')"
echo "installed_perms=$(stat -c '%U:%G %a' /usr/local/sbin/rust-api-activate)"
sudo grep -h "rust-api-activate" /etc/sudoers /etc/sudoers.d/* 2>/dev/null | head -1 || true
REMOTE
)" || fail "remote preflight failed"
echo "$PREFLIGHT"
ACTIVE_RELEASE="$(sed -n 's/^active_release=//p' <<<"$PREFLIGHT")"
INSTALLED_SHA="$(sed -n 's/^installed_sha=//p' <<<"$PREFLIGHT")"
INSTALLED_PERMS="$(sed -n 's/^installed_perms=//p' <<<"$PREFLIGHT")"
[ -n "$ACTIVE_RELEASE" ] && [ -n "$INSTALLED_SHA" ] || fail "preflight did not report release/script state"
grep -q "NOPASSWD: /usr/local/sbin/rust-api-activate" <<<"$PREFLIGHT" \
  || fail "sudoers rule for /usr/local/sbin/rust-api-activate not found"
if [ "$INSTALLED_SHA" = "$NEW_SHA" ]; then
  echo "installed script already matches the reviewed replacement (idempotent run)"
  NEEDS_INSTALL=0
else
  echo "installed script sha: $INSTALLED_SHA ($INSTALLED_PERMS) -> will be replaced"
  NEEDS_INSTALL=1
fi
BACKUP_PATH="/usr/local/sbin/rust-api-activate.bak-$(date -u +%Y%m%dT%H%M%SZ)"

if [ "$APPLY" -ne 1 ]; then
  step "dry run — plan (no VM changes made)"
  if [ "$NEEDS_INSTALL" -eq 1 ]; then
    echo "1. backup /usr/local/sbin/rust-api-activate -> $BACKUP_PATH"
    echo "2. install reviewed replacement ($NEW_SHA) atomically (staged rename)"
    echo "3. validate perms root:root 0755, sudoers chain (deploy -> sudo, exit 2 usage)"
  else
    echo "1.-3. skipped: installed script already matches"
  fi
  echo "4. upload rust-api-backfill-digests, dry-run report, then --apply"
  echo "5. re-verify rust-api /health/live and /health/ready and feed-api health"
  echo "6. rollback on failure: restore $BACKUP_PATH (automatic during validation)"
  echo "manual rollback afterwards: sudo mv $BACKUP_PATH /usr/local/sbin/rust-api-activate"
  exit 0
fi

# --- upload + backup + install --------------------------------------------------
# Staged copies land in the operator's home directory (relative paths); the
# operator home is the sanctioned upload area — /home/deploy/incoming is
# 0700 deploy-owned and not writable by this connection.
step "3/7 upload staged copy and back up the installed script"
REMOTE_STAGE="rust-api-activate.stage.$(date -u +%s)"
"${SCP[@]}" "$SOURCE_SCRIPT" "${INSTANCE}:${REMOTE_STAGE}" \
  || fail "scp of staged script failed"
vm "test \"\$(sha256sum \$HOME/$REMOTE_STAGE | cut -d' ' -f1)\" = '$NEW_SHA'" \
  || fail "staged script digest mismatch on VM"
if [ "$NEEDS_INSTALL" -eq 1 ]; then
  vm "sudo cp -p /usr/local/sbin/rust-api-activate '$BACKUP_PATH'" \
    || fail "backup of installed script failed"
  echo "backup: $BACKUP_PATH ($(vm "sha256sum '$BACKUP_PATH' | cut -d' ' -f1"))"
  # Atomic replacement: stage inside /usr/local/sbin, then one rename. The
  # active symlink, the service and the running process are never touched.
  vm "sudo install -m 0755 -o root -g root '$REMOTE_STAGE' /usr/local/sbin/.rust-api-activate.new \
        && sudo mv -Tf /usr/local/sbin/.rust-api-activate.new /usr/local/sbin/rust-api-activate" \
    || fail "atomic installation failed (installed script untouched; remove ~/$REMOTE_STAGE)"
fi
vm "rm -f \$HOME/$REMOTE_STAGE"

restore_backup() {
  echo "!! validation failed — restoring the previous script" >&2
  if [ "$NEEDS_INSTALL" -eq 1 ]; then
    if vm "sudo test -f '$BACKUP_PATH' \
        && sudo mv -Tf '$BACKUP_PATH' /usr/local/sbin/rust-api-activate \
        && [ \"\$(sha256sum /usr/local/sbin/rust-api-activate | cut -d' ' -f1)\" = '$INSTALLED_SHA' ]"; then
      echo "previous script restored and verified ($(echo "$INSTALLED_SHA" | cut -c1-12)...)" >&2
    else
      echo "CRITICAL: automatic restore failed; manual recovery: sudo mv $BACKUP_PATH /usr/local/sbin/rust-api-activate" >&2
    fi
  fi
}

# --- validation ------------------------------------------------------------------
step "4/7 validate installation (ownership, sudoers chain, script behaviour)"
VALIDATE="$(vm 'bash -s' <<'REMOTE'
set -Eeuo pipefail
perms="$(stat -c '%U:%G %a' /usr/local/sbin/rust-api-activate)"
[ "$perms" = "root:root 755" ] || { echo "wrong perms after install: $perms"; exit 1; }
bash -n /usr/local/sbin/rust-api-activate
# The deploy-user chain must work end to end and stay non-destructive:
# with no arguments the script exits 2 (invalid git SHA) without touching
# anything — that exit code is the proof.
rc=0
sudo -u deploy sudo -n /usr/local/sbin/rust-api-activate >/tmp/activate-probe.out 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "deploy->sudo chain probe failed (rc=$rc):"; cat /tmp/activate-probe.out; exit 1; }
grep -q "invalid git SHA" /tmp/activate-probe.out
REMOTE
)" || { restore_backup; fail "post-install validation failed"; }
echo "validation: $VALIDATE (perms OK, sudoers chain OK, usage exit 2 OK)"

# --- digest backfill -------------------------------------------------------------
step "5/7 backfill release digests (dry run, then apply)"
REMOTE_BACKFILL="rust-api-backfill-digests.stage.$(date -u +%s)"
"${SCP[@]}" "$REPO/ops/rust-api-backfill-digests" "${INSTANCE}:${REMOTE_BACKFILL}" \
  || fail "scp of backfill tool failed"
vm "test \"\$(sha256sum \$HOME/$REMOTE_BACKFILL | cut -d' ' -f1)\" = '$(sha_local "$REPO/ops/rust-api-backfill-digests")'" \
  || fail "staged backfill tool digest mismatch on VM"
vm "sudo install -m 0755 -o root -g root \$HOME/$REMOTE_BACKFILL /usr/local/sbin/rust-api-backfill-digests && rm -f \$HOME/$REMOTE_BACKFILL"
echo "--- backfill dry run ---"
DRYRUN_TAIL="$(vm 'sudo /usr/local/sbin/rust-api-backfill-digests | tail -n 1')" \
  || { restore_backup; fail "backfill dry run reported problems — nothing backfilled"; }
echo "$DRYRUN_TAIL"
# The summary always ends "..., N already correct, K refused". Any refusal is
# a stop condition the operator must resolve manually; the backfill tool
# itself never overwrites, so nothing was written either way.
if grep -qE ', [1-9][0-9]* refused$' <<<"$DRYRUN_TAIL"; then
  restore_backup
  fail "backfill dry run reports refusals; resolve them manually before applying"
fi
echo "--- backfill apply ---"
vm 'sudo /usr/local/sbin/rust-api-backfill-digests --apply' \
  || { restore_backup; fail "backfill apply failed"; }

# --- final health verification ---------------------------------------------------
step "6/7 verify service health unchanged"
HEALTH="$(vm 'bash -s' <<'REMOTE'
set -Eeuo pipefail
systemctl is-active --quiet rust-api || { echo "rust-api not active"; exit 1; }
current="$(basename "$(readlink -f /opt/rust-api/current)")"
curl --fail --silent --max-time 5 http://127.0.0.1:8080/health/live | grep -q "$current" || { echo "live mismatch"; exit 1; }
curl --fail --silent --max-time 5 http://127.0.0.1:8080/health/ready >/dev/null || { echo "ready not 200"; exit 1; }
echo "rust-api live+ready OK ($current)"
if systemctl is-active --quiet feed-api; then
  curl --fail --silent --max-time 5 http://127.0.0.1:8081/health/live >/dev/null
  echo "feed-api live OK"
else
  echo "feed-api not installed (skipped)"
fi
REMOTE
)" || { restore_backup; fail "post-install health verification failed"; }
echo "$HEALTH"

step "7/7 rollout record"
vm 'sha256sum /usr/local/sbin/rust-api-activate; stat -c "%U:%G %a" /usr/local/sbin/rust-api-activate; date -u'
echo
echo "DONE. Installed script sha256: $NEW_SHA"
[ "$NEEDS_INSTALL" -eq 1 ] && echo "Rollback if needed: ssh $INSTANCE 'sudo mv $BACKUP_PATH /usr/local/sbin/rust-api-activate'"
echo "No service restart, no symlink change, no release change was performed by this procedure."
