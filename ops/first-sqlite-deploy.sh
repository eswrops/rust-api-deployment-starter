#!/usr/bin/env bash
# First deployment of the SQLite-enabled rust-api to the production VM
# (default: rust-api-prod @ us-west1-b). Run from an operator workstation with
# gcloud authenticated; all VM access goes through IAP (no public IPv4, no new
# persistent SSH material).
#
#   ops/first-sqlite-deploy.sh --git-sha <CI commit> --artifact-dir <dir>
#
# The artifact directory must contain the `rust-api` binary and
# `rust-api.sha256` downloaded from the successful CI run (gh run download).
#
# What it does, in order, each step idempotent:
#   1. verifies the artifact digest locally and on the VM
#   2. records the running release as the rollback anchor
#   3. installs the artifact into /opt/rust-api/releases/<git-sha>/ WITHOUT
#      touching the `current` symlink (the running service is never restarted)
#   4. creates /var/lib/rust-api (persistent disk, rustapi:rustapi, 0750) and
#      sets DATABASE_URL in /etc/rust-api/app.env to the exact value the
#      service will use
#   5. runs the embedded SQLx migrations AS the rustapi user, twice, proving
#      idempotency (second run must report 0 pending)
#   6. probes /health/ready of the STAGED binary as the rustapi user against
#      the real database (brief second instance on port 18080 — the systemd
#      service is not touched)
#   7. verifies the documented rollback path (activate script, sudoers rule,
#      current release)
#
# It does NOT activate the new release. Activation happens through the normal
# CI deploy once PRODUCTION_DEPLOY_ENABLED is turned on, or with --activate
# for a manual, still-readiness-gated activation via rust-api-activate.
set -Eeuo pipefail

GIT_SHA=""
ARTIFACT_DIR=""
ACTIVATE=0
PROJECT="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
ZONE="${GCE_ZONE:-us-west1-b}"
INSTANCE="${GCE_INSTANCE:-rust-api-prod}"
SSH_USER="$(gcloud config get-value account 2>/dev/null | cut -d@ -f1 | tr '.@' '__' || true)"

usage() { grep '^#' "$0" | head -30; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --git-sha) GIT_SHA="$2"; shift 2 ;;
    --artifact-dir) ARTIFACT_DIR="$2"; shift 2 ;;
    --activate) ACTIVATE=1; shift ;;
    --project) PROJECT="$2"; shift 2 ;;
    --zone) ZONE="$2"; shift 2 ;;
    --instance) INSTANCE="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$GIT_SHA" ] || usage
[ -n "$ARTIFACT_DIR" ] || usage
[ -d "$ARTIFACT_DIR" ] || { echo "artifact directory not found: $ARTIFACT_DIR"; exit 1; }
[ -n "$PROJECT" ] || { echo "no GCP project resolved (set GCP_PROJECT_ID)"; exit 1; }

GC=(gcloud --project="$PROJECT" compute)
SSH=(${GC[@]} ssh "$INSTANCE" --zone="$ZONE" --tunnel-through-iap --quiet)
SCP=(${GC[@]} scp --tunnel-through-iap --zone="$ZONE")
vm() { "${SSH[@]}" --command="$1"; }

step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

step "1/7 local artifact verification"
BINARY="$ARTIFACT_DIR/rust-api"
SUMFILE="$ARTIFACT_DIR/rust-api.sha256"
[ -f "$BINARY" ] && [ -f "$SUMFILE" ] || fail "artifact dir must contain rust-api and rust-api.sha256"
( cd "$ARTIFACT_DIR" && sha256sum --check rust-api.sha256 --status ) || fail "local digest mismatch"
DIGEST="$(awk '{print $1}' "$SUMFILE")"
echo "artifact digest $DIGEST ($(stat -f%z "$BINARY" 2>/dev/null || stat -c%s "$BINARY") bytes)"

step "2/7 remote preflight (current release = rollback anchor)"
vm 'set -e
  systemctl is-active --quiet rust-api || { echo "rust-api service not active"; exit 1; }
  echo "current: $(readlink -f /opt/rust-api/current)"
  echo "running digest: $(sha256sum /opt/rust-api/current/rust-api | cut -d" " -f1)"
  echo "operator: $(whoami)"
' | tee /tmp/first-deploy-preflight.txt
CURRENT_RELEASE="$(awk '/^current: /{print $2}' /tmp/first-deploy-preflight.txt)"
[ -n "$CURRENT_RELEASE" ] || fail "could not read current release"
if [ "$CURRENT_RELEASE" = "/opt/rust-api/releases/$GIT_SHA" ]; then
  echo "NOTE: release $GIT_SHA is already the active release; continuing with migration/verification only"
fi

step "3/7 stage the exact CI artifact onto the VM (IAP)"
# /home/deploy/incoming is 0700 deploy-owned, so upload to the operator home
# first and install into place with the ownership rust-api-activate expects.
"${SCP[@]}" "$BINARY" "$INSTANCE:first-sqlite-upload" >/dev/null
vm "set -e
  actual=\$(sha256sum ~/first-sqlite-upload | cut -d' ' -f1)
  [ \"\$actual\" = \"$DIGEST\" ] || { echo \"digest mismatch on VM: \$actual\"; exit 1; }
  sudo install -o deploy -g deploy -m 0644 ~/first-sqlite-upload /home/deploy/incoming/rust-api-$GIT_SHA
  rm ~/first-sqlite-upload
  staged=\$(sudo sha256sum /home/deploy/incoming/rust-api-$GIT_SHA | cut -d' ' -f1)
  [ \"\$staged\" = \"$DIGEST\" ] || { echo \"digest mismatch after install: \$staged\"; exit 1; }
  sudo stat -c '%U:%G %a %n' /home/deploy/incoming/rust-api-$GIT_SHA
  echo 'staged artifact digest verified: OK'"

step "4/7 prepare database directory and service environment"
vm "set -e
  # Persistent-disk + ownership checks for /var/lib/rust-api
  sudo install -d -o rustapi -g rustapi -m 0750 /var/lib/rust-api
  fstype=\$(findmnt -no FSTYPE -T /var/lib/rust-api)
  [ \"\$fstype\" != tmpfs ] || { echo '/var/lib/rust-api is on tmpfs'; exit 1; }
  echo \"filesystem for /var/lib/rust-api: \$fstype (persistent)\"
  stat -c '%U:%G %a %n' /var/lib/rust-api
  # Same DATABASE_URL for migration and service: make it explicit in app.env.
  if sudo grep -q '^# DATABASE_URL=' /etc/rust-api/app.env; then
    sudo sed -i 's|^# DATABASE_URL=.*|DATABASE_URL=sqlite:///var/lib/rust-api/app.db|' /etc/rust-api/app.env
  elif ! sudo grep -q '^DATABASE_URL=' /etc/rust-api/app.env; then
    printf '%s\n' 'DATABASE_URL=sqlite:///var/lib/rust-api/app.db' | sudo tee -a /etc/rust-api/app.env >/dev/null
  fi
  sudo stat -c '%U:%G %a %n' /etc/rust-api/app.env
  sudo grep '^DATABASE_URL=' /etc/rust-api/app.env"

step "5/7 install release (current symlink untouched) and run migrations as rustapi"
vm "set -e
  rel=/opt/rust-api/releases/$GIT_SHA
  if [ \"\$(readlink -f /opt/rust-api/current)\" = \"\$rel\" ]; then
    echo 'release already active; skipping binary install'
  elif [ -f \$rel/rust-api ] && [ \"\$(sha256sum \$rel/rust-api | cut -d' ' -f1)\" = \"$DIGEST\" ]; then
    echo 'release already installed with matching digest; skipping install'
  else
    sudo install -d -m 0755 -o root -g root \$rel
    sudo install -m 0755 -o root -g root /home/deploy/incoming/rust-api-$GIT_SHA \$rel/rust-api
    echo 'release installed:'; sudo stat -c '%U:%G %a %n' \$rel/rust-api
  fi
  dburl=\$(sudo grep '^DATABASE_URL=' /etc/rust-api/app.env | cut -d= -f2-)
  [ -n \"\$dburl\" ] || { echo 'DATABASE_URL missing from app.env'; exit 1; }
  echo \"migrating with DATABASE_URL=\$dburl as rustapi\"
  # runuser (invoked as root) drops to the rustapi service account; the
  # operator sudoers rule grants root only, so 'sudo -u rustapi' would prompt.
  sudo runuser -u rustapi -- env DATABASE_URL=\"\$dburl\" /opt/rust-api/releases/$GIT_SHA/rust-api migrate
  echo '--- second run (idempotency proof) ---'
  sudo runuser -u rustapi -- env DATABASE_URL=\"\$dburl\" /opt/rust-api/releases/$GIT_SHA/rust-api migrate
  # The 0750 database directory blocks the non-root shell; stat through root.
  sudo sh -c 'stat -c \"%U:%G %a %n\" /var/lib/rust-api/app.db*'"

step "6/7 probe staged binary readiness against the real database"
vm "set -e
  dburl=\$(sudo grep '^DATABASE_URL=' /etc/rust-api/app.env | cut -d= -f2-)
  sudo runuser -u rustapi -- env DATABASE_URL=\"\$dburl\" APP_BIND=127.0.0.1:18080 RUST_LOG=warn \
    /opt/rust-api/releases/$GIT_SHA/rust-api >/tmp/staged-readiness.log 2>&1 &
  probe=\$!
  ok=0
  for _ in \$(seq 1 20); do
    code=\$(curl -s -o /tmp/ready.json -w '%{http_code}' http://127.0.0.1:18080/health/ready || true)
    [ \"\$code\" = 200 ] && ok=1 && break
    sleep 0.5
  done
  kill \$probe 2>/dev/null || true
  wait \$probe 2>/dev/null || true
  [ \"\$ok\" = 1 ] || { echo 'staged binary readiness probe failed'; cat /tmp/staged-readiness.log; cat /tmp/ready.json 2>/dev/null; exit 1; }
  echo \"staged /health/ready: 200 \$(cat /tmp/ready.json)\"
  rm -f /tmp/ready.json /tmp/staged-readiness.log"

step "7/7 verify documented rollback path"
vm "set -e
  test -x /usr/local/sbin/rust-api-activate
  sudo stat -c '%U:%G %a %n' /usr/local/sbin/rust-api-activate
  sudo grep -q 'deploy ALL=(root) NOPASSWD: /usr/local/sbin/rust-api-activate' /etc/sudoers.d/rust-api-deploy
  test -x /opt/rust-api/current/rust-api
  echo 'current (rollback anchor):' \$(readlink -f /opt/rust-api/current)
  echo 'rollback command if needed:'
  echo '  ssh <vm> sudo /usr/local/sbin/rust-api-activate <previous-sha> <previous-digest>'
  echo '  (the activate script also auto-rolls back if a new release fails readiness)'"

if [ "$ACTIVATE" -eq 1 ]; then
  step "ACTIVATE (explicit flag): readiness-gated activation via rust-api-activate"
  vm "sudo /usr/local/sbin/rust-api-activate '$GIT_SHA' '$DIGEST'"
  echo "activated $GIT_SHA"
else
  step "done — release staged, database migrated and verified; service untouched"
  echo "next: enable the deployment gate and run the CI deploy, e.g."
  echo "  gh variable set PRODUCTION_DEPLOY_ENABLED --repo eswrops/rust-api-deployment-starter --body true"
  echo "  gh workflow run ci-deploy.yml --repo eswrops/rust-api-deployment-starter --ref main"
fi
