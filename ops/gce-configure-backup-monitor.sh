#!/usr/bin/env bash
# Prepares the EXTERNAL backup-freshness monitor (docs/backup-recovery.md,
# "External freshness monitoring"): a dedicated, read-only service account
# that only the backup-freshness.yml workflow on refs/heads/main may
# impersonate, with viewer rights on the backup bucket only.
#
# OPERATOR-APPROVED INFRASTRUCTURE CHANGE, not part of CI:
#   ops/gce-configure-backup-monitor.sh          # dry run: shows the plan
#   ops/gce-configure-backup-monitor.sh --apply  # creates IAM + sets repo variables
#
# After --apply, verify delivery with an authorized test:
#   gh workflow run backup-freshness.yml --repo eswrops/rust-api-deployment-starter
#   gh run watch  # expect green with "freshness: all checks passed"
# and a stale test: temporarily set BACKUP_MAX_AGE_HOURS=0 via a dispatch…
# (the check script reads the defaults from the repo copy; verifying a
# failure end-to-end is documented in docs/backup-recovery.md).
set -Eeuo pipefail

project_id=${GCP_PROJECT_ID:-rust-product-foundry-4bd846}
project_number=${GCP_PROJECT_NUMBER:-650296500144}
pool=github-actions-pool
repository=${GITHUB_REPOSITORY_NAME:-eswrops/rust-api-deployment-starter}
repository_id=${GITHUB_REPOSITORY_ID:-1434567946}
bucket=${BACKUP_BUCKET:-rust-api-prod-backups-650296500144}
monitor_sa_name=rust-api-backup-monitor
monitor_sa="${monitor_sa_name}@${project_id}.iam.gserviceaccount.com"
monitor_workflow="repo/${repository}/.github/workflows/backup-freshness.yml"

binding_condition="assertion.repository_id=='${repository_id}' && assertion.ref=='refs/heads/main' && assertion.workflow=='${monitor_workflow}'"
principal_set="principalSet://iam.googleapis.com/projects/${project_number}/locations/global/workloadIdentityPools/${pool}/*"

apply=0
[ "${1:-}" = "--apply" ] && apply=1

echo "monitor SA:        ${monitor_sa}"
echo "bucket (viewer):   gs://${bucket}  (bucket-scope roles/storage.objectViewer only)"
echo "WIF binding:       workloadIdentityUser for pool/* with condition:"
echo "                     ${binding_condition}"
echo "repo variables:    BACKUP_BUCKET=${bucket}"
echo "                   GCP_BACKUP_MONITOR_SERVICE_ACCOUNT=${monitor_sa}"
echo "                   BACKUP_FRESHNESS_MONITOR_ENABLED=true"

if [ "$apply" -ne 1 ]; then
  echo
  echo "dry run only: re-run with --apply to create the identity and enable the monitor."
  exit 0
fi

if ! gcloud iam service-accounts describe "$monitor_sa" --project="$project_id" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$monitor_sa_name" \
    --project="$project_id" \
    --display-name='Backup freshness monitor (read-only, external check)'
fi

# Read-only, bucket-scoped: can list/read this bucket and nothing else.
gcloud storage buckets add-iam-policy-binding "gs://${bucket}" \
  --member="serviceAccount:${monitor_sa}" \
  --role=roles/storage.objectViewer

# Impersonation restricted to exactly the monitor workflow on main; the
# provider condition (repository_id + ref) is applied separately by
# ops/gce-harden-github-oidc.sh — this binding does not depend on it.
gcloud iam service-accounts add-iam-policy-binding "$monitor_sa" \
  --project="$project_id" \
  --member="$principal_set" \
  --role=roles/iam.workloadIdentityUser \
  --condition='expression='"${binding_condition}"

gh variable set BACKUP_BUCKET --repo="$repository" --body="$bucket"
gh variable set GCP_BACKUP_MONITOR_SERVICE_ACCOUNT --repo="$repository" --body="$monitor_sa"
gh variable set BACKUP_FRESHNESS_MONITOR_ENABLED --repo="$repository" --body true

echo
echo "monitor configured. Verification:"
echo "  1. gh workflow run backup-freshness.yml --repo ${repository}   # expect green, 'all checks passed'"
echo "  2. subscribe to failure notifications for the workflow (or add a chat webhook later)"
echo
echo "Rollback: gh variable delete BACKUP_FRESHNESS_MONITOR_ENABLED --repo=${repository}"
echo "  gcloud storage buckets remove-iam-policy-binding gs://${bucket} --member=serviceAccount:${monitor_sa} --role=roles/storage.objectViewer"
