#!/usr/bin/env bash
# Installs the benchmark feed API on the production VM (default:
# rust-api-prod @ us-west1-b) as a SECOND service beside the existing
# rust-api, driven over IAP from an operator workstation. The Caddy site
# then routes the SPEC.md endpoints (/health, /feed, /posts*) to feed-api
# on 127.0.0.1:8081 and keeps /health/live, /health/ready and everything
# else on rust-api (127.0.0.1:8080).
#
#   ops/install-feed-api.sh --run-id <feed-api-build workflow run id> \
#                           --seed-db <path to seed/feed.db>
#
#   --binary <file>  installs a locally built binary instead of a CI artifact
#   --skip-seed      do not upload/verify the seed database (already present)
#
# The seed database (~250 MB) is relayed through the private backup bucket
# (workstation -> gs://<bucket>/imports/, VM -> JSON API download with the
# existing rust-api-backup key), then the imports/ object is deleted.
# Operator-approved infrastructure change; not part of CI.
set -Eeuo pipefail

PROJECT="${GCP_PROJECT_ID:-rust-product-foundry-4bd846}"
ZONE="${GCE_ZONE:-us-west1-b}"
INSTANCE="${GCE_INSTANCE:-rust-api-prod}"
REPOSITORY="${GITHUB_REPOSITORY_NAME:-eswrops/rust-api-deployment-starter}"
BUCKET="${GCS_BUCKET:-rust-api-prod-backups-650296500144}"
SITE="${FEED_SITE:-api-bench.thetechs.top}"
FEED_PORT=8081

RUN_ID=""
BINARY=""
SEED_DB="${SEED_DB:-/Users/eswr/code/arjaythedev/twelve-dollar-server-challenge/seed/feed.db}"
SKIP_SEED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    --seed-db) SEED_DB="$2"; shift 2 ;;
    --skip-seed) SKIP_SEED=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

GC=(gcloud --project="$PROJECT" compute)
SSH=("${GC[@]}" ssh "$INSTANCE" --zone="$ZONE" --tunnel-through-iap --quiet)
SCP=("${GC[@]}" scp --tunnel-through-iap --zone="$ZONE" --quiet)
vm() { "${SSH[@]}" --command="$1"; }
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
sha_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

GIT_SHA="$(git -C "$HERE" rev-parse HEAD)"
release="/opt/feed-api/releases/${GIT_SHA}"

# 1/6 Obtain the Linux AMD64 binary.
step "1/6 obtain feed-api binary"
if [ -n "$BINARY" ]; then
  [ -f "$BINARY" ] || fail "binary not found: $BINARY"
  cp "$BINARY" "$work/feed-api"
else
  [ -n "$RUN_ID" ] || fail "pass --run-id <workflow run> or --binary <file>"
  gh run download "$RUN_ID" --repo "$REPOSITORY" -n feed-api-linux-amd64 -D "$work/artifact"
  mv "$work/artifact/feed-api" "$work/feed-api"
fi
digest="$(sha_of "$work/feed-api")"
echo "binary digest: $digest"

"${SCP[@]}" "$work/feed-api" "${INSTANCE}:/home/$(whoami)/feed-api-${GIT_SHA}" \
  || fail "binary upload failed"

# 2/6 Seed database through the backup bucket relay.
step "2/6 seed database"
if [ "$SKIP_SEED" -eq 1 ]; then
  echo "skipped (--skip-seed)"
elif vm "test -s /var/lib/feed-api/feed.db"; then
  echo "seed already present; skipped"
else
  [ -f "$SEED_DB" ] || fail "seed database not found: $SEED_DB (pass --seed-db)"
  seed_digest="$(sha_of "$SEED_DB")"
  echo "uploading $(du -h "$SEED_DB" | cut -f1) seed to gs://${BUCKET}/imports/feed.db"
  gcloud storage cp "$SEED_DB" "gs://${BUCKET}/imports/feed.db" || fail "seed upload to GCS failed"
  echo "downloading on the VM via the backup identity (GCS relay)"
  vm "set -e
    sudo install -d -o rustapi -g rustapi -m 0750 /var/lib/feed-api
    sudo sh -c 'set -a; . /etc/rust-api/backup.env; set +a; GCS_HTTP_TIMEOUT=600; export GCS_HTTP_TIMEOUT; . /usr/local/sbin/rust-api-backup-lib.sh; gcs_download \"\$GCS_KEY_FILE\" \"\$GCS_BUCKET\" imports/feed.db /var/lib/feed-api/feed.db.partial'
    sudo mv /var/lib/feed-api/feed.db.partial /var/lib/feed-api/feed.db
    sudo chown rustapi:rustapi /var/lib/feed-api/feed.db
    sudo chmod 0640 /var/lib/feed-api/feed.db
    actual=\$(sha256sum /var/lib/feed-api/feed.db | awk '{print \$1}')
    [ \"\$actual\" = '${seed_digest}' ] || { echo 'seed digest mismatch' >&2; exit 1; }
    echo 'seed verified: sha256 match'" || fail "seed relay failed"
  gcloud storage rm "gs://${BUCKET}/imports/feed.db" >/dev/null 2>&1 || echo "warning: could not delete gs://${BUCKET}/imports/feed.db (retention will expire it)" >&2
fi

# 3/6 Binary + env file.
step "3/6 install binary and environment"
vm "set -e
  sudo install -d -m 0755 -o root -g root /opt/feed-api/releases '${release%/*}'
  sudo install -m 0755 -o root -g root '/home/$(whoami)/feed-api-${GIT_SHA}' '${release}/feed-api'
  actual=\$(sha256sum '${release}/feed-api' | awk '{print \$1}')
  [ \"\$actual\" = '${digest}' ] || { echo 'binary digest mismatch' >&2; exit 1; }
  sudo ln -sfn '${release}' /opt/feed-api/.current-next
  sudo mv -Tf /opt/feed-api/.current-next /opt/feed-api/current
  sudo install -d -m 0750 -o root -g rustapi /etc/feed-api
  printf 'HOST=127.0.0.1\nPORT=${FEED_PORT}\nSQLITE_PATH=/var/lib/feed-api/feed.db\nJWT_SECRET=twelve-dollar-challenge\nRUST_LOG=info,tower_http=warn\n' \
    | sudo tee /etc/feed-api/env >/dev/null
  sudo chown root:rustapi /etc/feed-api/env
  sudo chmod 0640 /etc/feed-api/env
  rm -f '/home/$(whoami)/feed-api-${GIT_SHA}'
  echo 'binary installed: ${release}/feed-api (sha256 verified)'" || fail "binary/env install failed"

# 4/6 systemd unit.
step "4/6 install and start feed-api.service"
"${SCP[@]}" "$HERE/../config/feed-api.service" "${INSTANCE}:/home/$(whoami)/feed-api.service" || fail "unit upload failed"
vm "set -e
  sudo install -m 0644 -o root -g root '/home/$(whoami)/feed-api.service' /etc/systemd/system/feed-api.service
  rm -f '/home/$(whoami)/feed-api.service'
  sudo systemctl daemon-reload
  sudo systemctl enable --now feed-api.service
  for _ in \$(seq 1 30); do
    curl -fsS --max-time 2 http://127.0.0.1:${FEED_PORT}/health >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS http://127.0.0.1:${FEED_PORT}/health" || fail "feed-api service did not become healthy"

# 5/6 Caddy routing.
step "5/6 update Caddy routing"
"${SCP[@]}" "$HERE/../config/Caddyfile" "${INSTANCE}:/home/$(whoami)/Caddyfile.new" || fail "Caddyfile upload failed"
vm "set -e
  caddy validate --config '/home/$(whoami)/Caddyfile.new' >/dev/null
  sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak-\$(date -u +%Y%m%dT%H%M%SZ)
  sudo install -m 0644 -o root -g root '/home/$(whoami)/Caddyfile.new' /etc/caddy/Caddyfile
  rm -f '/home/$(whoami)/Caddyfile.new'
  sudo systemctl reload caddy
  echo 'caddy reloaded'" || fail "caddy update failed"

# 6/6 End-to-end verification through the public site.
step "6/6 verify through ${SITE}"
sleep 3
echo "-- ${SITE}/health (feed API):"
curl -fsS --max-time 10 "https://${SITE}/health" || fail "public /health failed"
echo
echo "-- ${SITE}/health/ready (rust-api, must keep working):"
curl -fsS --max-time 10 "https://${SITE}/health/ready" || fail "public /health/ready failed"
echo
echo "-- ${SITE}/feed (feed API):"
curl -fsS --max-time 10 "https://${SITE}/feed" | head -c 200
echo
echo
echo "feed API deployed: ${release} serving on 127.0.0.1:${FEED_PORT} behind ${SITE}"
echo "spec verification: bash <upstream>/test/test.sh https://${SITE}"
