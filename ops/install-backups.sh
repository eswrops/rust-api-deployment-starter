#!/usr/bin/env bash
# Installs and enables the automated SQLite backup system on the production
# VM (default: rust-api-prod @ us-west1-b), driven over IAP from an operator
# workstation. Idempotent: re-running refreshes scripts/units and re-verifies
# without disturbing timers that are already correct.
#
#   ops/install-backups.sh --key-file vm-key.json
#
# Prerequisites (created once, the script verifies and reports):
#   - private bucket gs://rust-api-prod-backups-<project-number> in us-west1
#   - service account rust-api-backup@<project> with roles/storage.objectUser
#     bound at the BUCKET level only (upload, overwrite, retention delete)
#   - the service-account JSON key to install (freshly created per install)
#
# After installing it runs the backup and the restore drill once each and
# prints the verification results.
set -Eeuo pipefail

KEY_FILE=""
PROJECT="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
ZONE="${GCE_ZONE:-us-west1-b}"
INSTANCE="${GCE_INSTANCE:-rust-api-prod}"
BUCKET="${GCS_BUCKET:-rust-api-prod-backups-$(gcloud projects describe "${PROJECT:?}" --format='value(projectNumber)' 2>/dev/null)}"
SA_EMAIL="${BACKUP_SA:-rust-api-backup@${PROJECT}.iam.gserviceaccount.com}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/backup"

usage() { grep '^#' "$0" | head -20; exit 2; }
[ "${1:-}" = "--key-file" ] && { KEY_FILE="$2"; } || usage
[ -n "$KEY_FILE" ] && [ -f "$KEY_FILE" ] || usage
[ -n "$PROJECT" ] || { echo "no GCP project resolved"; exit 1; }

GC=(gcloud --project="$PROJECT" compute)
SSH=(${GC[@]} ssh "$INSTANCE" --zone="$ZONE" --tunnel-through-iap --quiet)
SCP=(${GC[@]} scp --tunnel-through-iap --zone="$ZONE")
vm() { "${SSH[@]}" --command="$1"; }
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

step "1/6 verify cloud-side prerequisites"
key_email="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["client_email"])' "$KEY_FILE")"
[ "$key_email" = "$SA_EMAIL" ] || fail "key belongs to $key_email, expected $SA_EMAIL"
gcloud storage buckets describe "gs://$BUCKET" >/dev/null 2>&1 || fail "bucket gs://$BUCKET not found"
gcloud storage buckets get-iam-policy "gs://$BUCKET" --format=json |
  jq -e --arg sa "serviceAccount:$SA_EMAIL" \
    '.bindings[] | select(.role=="roles/storage.objectUser") | .members | index($sa)' >/dev/null ||
  fail "service account lacks roles/storage.objectUser on the bucket"
echo "bucket gs://$BUCKET + objectUser binding OK"

step "2/6 upload assets (IAP, via operator home)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sed -e "s|REPLACE_WITH_BUCKET|$BUCKET|" "$SRC/backup.env.example" >"$work/backup.env"
cp "$KEY_FILE" "$work/backup-gcs-key.json"
cp "$SRC/rust-api-backup" "$SRC/rust-api-restore-drill" "$SRC/rust-api-backup-alert" \
  "$SRC/rust-api-backup-lib.sh" "$SRC/units/"*.service "$SRC/units/"*.timer "$work/"
"${SCP[@]}" "$work"/* "$INSTANCE:first-backup-upload/" >/dev/null

step "3/6 install on the VM"
vm 'set -e
  sudo install -d -m 0750 -o rustapi -g rustapi /var/lib/rust-api/backups
  for f in rust-api-backup rust-api-restore-drill rust-api-backup-alert rust-api-backup-lib.sh; do
    sudo install -m 0755 -o root -g root ~/first-backup-upload/$f /usr/local/sbin/$f
  done
  for f in rust-api-backup.service rust-api-backup.timer rust-api-restore-drill.service rust-api-restore-drill.timer "rust-api-backup-alert@.service"; do
    sudo install -m 0644 -o root -g root ~/first-backup-upload/$f /etc/systemd/system/$f
  done
  # Secrets: env (bucket, retention) readable by rustapi; the SA key strictly so.
  sudo install -m 0640 -o root -g rustapi ~/first-backup-upload/backup.env /etc/rust-api/backup.env
  sudo install -m 0640 -o root -g rustapi ~/first-backup-upload/backup-gcs-key.json /etc/rust-api/backup-gcs-key.json
  rm -f ~/first-backup-upload/*
  rmdir ~/first-backup-upload
  sudo systemd-tmpfiles --create 2>/dev/null || true
  sudo systemctl daemon-reload
  sudo systemctl enable --now rust-api-backup.timer rust-api-restore-drill.timer
  systemctl list-timers "rust-api-*" --no-pager | head -5'

step "4/6 run one backup cycle through systemd"
vm 'set -e
  sudo systemctl restart rust-api-backup.service
  for _ in $(seq 1 90); do
    state="$(systemctl show rust-api-backup.service -p ActiveState --value)"
    [ "$state" = inactive ] && break
    [ "$state" = failed ] && break
    sleep 1
  done
  result="$(systemctl show rust-api-backup.service -p Result --value)"
  [ "$result" = success ] || { sudo journalctl -u rust-api-backup.service -n 20 --no-pager -o cat; exit 1; }
  sudo journalctl -u rust-api-backup.service -n 6 --no-pager -o cat
  sudo test -f /var/lib/rust-api/backups/app-latest.db
  echo "local snapshot + latest copy present:"
  sudo stat -c "%U:%G %a %n" /var/lib/rust-api/backups/app-latest.db /var/lib/rust-api/backups/last-backup-success'

step "5/6 run one restore drill through systemd"
vm 'set -e
  sudo systemctl restart rust-api-restore-drill.service
  for _ in $(seq 1 90); do
    state="$(systemctl show rust-api-restore-drill.service -p ActiveState --value)"
    [ "$state" = inactive ] && break
    [ "$state" = failed ] && break
    sleep 1
  done
  result="$(systemctl show rust-api-restore-drill.service -p Result --value)"
  sudo journalctl -u rust-api-restore-drill.service -n 8 --no-pager -o cat
  [ "$result" = success ] || exit 1'

step "6/6 verify off-site state"
gcloud storage cat "gs://$BUCKET/heartbeat.txt"
echo
gcloud storage ls "gs://$BUCKET/snapshots/" "gs://$BUCKET/drills/" 2>/dev/null
echo "install complete: timers enabled, backup and drill verified"
