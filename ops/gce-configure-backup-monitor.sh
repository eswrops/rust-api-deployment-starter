#!/usr/bin/env bash
# Prepares the EXTERNAL backup-freshness monitor (docs/backup-recovery.md,
# "External freshness monitoring"): a dedicated, read-only service account
# impersonable only from this repository, with viewer rights on the backup
# bucket only.
#
# Impersonation restriction — how and why (final architecture):
#   * Both SA bindings use principalSet://…/attribute.repository/<repo>.
#     The ref restriction comes from the PROVIDER condition (applied by
#     ops/gce-harden-github-oidc.sh: repository_id + refs/heads/main), so
#     only main-branch runs of this repository can exchange tokens at all.
#   * roles/iam.workloadIdentityUser authorizes token exchange; roles/
#     iam.serviceAccountTokenCreator is ALSO required because the check
#     script mints its own SA token via `gcloud auth print-access-token`
#     (the iamcredentials path). A CEL-computed attribute principal
#     (attribute.monitor_scope) was tried first and does NOT work: the
#     federated caller never matches a principalSet computed over the
#     `workflow` claim during iamcredentials minting (verified 2026-10-27,
#     see PRs #3-#5).
#
# OPERATOR-APPROVED INFRASTRUCTURE CHANGE, not part of CI:
#   ops/gce-configure-backup-monitor.sh          # dry run: shows the plan
#   ops/gce-configure-backup-monitor.sh --apply  # creates IAM + sets repo variables
#
# After --apply, note that SA-policy binding changes take up to ~5 minutes
# to reach the iamcredentials path; verify no earlier than that:
#   gh workflow run backup-freshness.yml --repo eswrops/rust-api-deployment-starter
#   gh run watch  # expect green with "freshness: all checks passed"
set -Eeuo pipefail

project_id=${GCP_PROJECT_ID:-rust-product-foundry-4bd846}
project_number=${GCP_PROJECT_NUMBER:-650296500144}
pool=github-actions-pool
repository=${GITHUB_REPOSITORY_NAME:-eswrops/rust-api-deployment-starter}
bucket=${BACKUP_BUCKET:-rust-api-prod-backups-650296500144}
monitor_sa_name=rust-api-backup-monitor
monitor_sa="${monitor_sa_name}@${project_id}.iam.gserviceaccount.com"

principal_set="principalSet://iam.googleapis.com/projects/${project_number}/locations/global/workloadIdentityPools/${pool}/attribute.repository/${repository}"

apply=0
[ "${1:-}" = "--apply" ] && apply=1

# A freshly created service account is not immediately visible to other GCP
# backends: bucket IAM can 400 with "Service account ... does not exist"
# seconds after `create` succeeds. Wait until IAM describe sees it, and
# retry the (idempotent) policy operations on transient failures.
wait_for_service_account() {
  local sa="$1" i
  for i in $(seq 1 12); do
    if gcloud iam service-accounts describe "$sa" --project="$project_id" >/dev/null 2>&1; then
      return 0
    fi
    echo "waiting for ${sa} to become visible (${i}/12)..." >&2
    sleep 5
  done
  echo "service account ${sa} did not become visible in time" >&2
  return 1
}

retry() {
  local i=0
  until "$@"; do
    i=$((i + 1))
    if [ "$i" -ge 6 ]; then
      echo "giving up after ${i} attempts: $*" >&2
      return 1
    fi
    echo "retry ${i}/6: $*" >&2
    sleep 10
  done
}

echo "monitor SA:        ${monitor_sa}"
echo "bucket (viewer):   gs://${bucket}  (bucket-scope objectViewer + bucketViewer only)"
echo "SA bindings:       workloadIdentityUser + serviceAccountTokenCreator for"
echo "                     ${principal_set}"
echo "                   (main-restriction enforced by the provider condition)"
echo "repo variables:    BACKUP_BUCKET=${bucket}"
echo "                   GCP_BACKUP_MONITOR_SERVICE_ACCOUNT=${monitor_sa}"
echo "                   BACKUP_FRESHNESS_MONITOR_ENABLED=true"

if [ "$apply" -ne 1 ]; then
  echo
  echo "dry run only: re-run with --apply to create the identity and enable the monitor."
  exit 0
fi

# 1. The read-only monitor identity.
if ! gcloud iam service-accounts describe "$monitor_sa" --project="$project_id" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$monitor_sa_name" \
    --project="$project_id" \
    --display-name='Backup freshness monitor (read-only, external check)'
fi
wait_for_service_account "$monitor_sa"

# 2. Read-only, bucket-scoped. objectViewer covers object reads/listing;
#    bucketViewer covers the bucket metadata lookup (storage.buckets.get)
#    that gcloud storage and some tooling perform first. Neither grants
#    writes, IAM changes, or access to any other bucket.
retry gcloud storage buckets add-iam-policy-binding "gs://${bucket}" \
  --member="serviceAccount:${monitor_sa}" \
  --role=roles/storage.objectViewer
retry gcloud storage buckets add-iam-policy-binding "gs://${bucket}" \
  --member="serviceAccount:${monitor_sa}" \
  --role=roles/storage.bucketViewer

# 3. Impersonation from this repository only (ref pinned by the provider
#    condition). TokenCreator mirrors workloadIdentityUser because the
#    check script mints its own token via the iamcredentials path.
for role in roles/iam.workloadIdentityUser roles/iam.serviceAccountTokenCreator; do
  retry gcloud iam service-accounts add-iam-policy-binding "$monitor_sa" \
    --project="$project_id" \
    --member="$principal_set" \
    --role="$role"
done

# 4. Flip the workflow gate and provide the identifiers it needs.
gh variable set BACKUP_BUCKET --repo="$repository" --body="$bucket"
gh variable set GCP_BACKUP_MONITOR_SERVICE_ACCOUNT --repo="$repository" --body="$monitor_sa"
gh variable set BACKUP_FRESHNESS_MONITOR_ENABLED --repo="$repository" --body true

echo
echo "monitor configured. Verification (wait ~5 min for SA-policy propagation):"
echo "  gh workflow run backup-freshness.yml --repo ${repository}   # expect green, 'all checks passed'"
echo
echo "Rollback: gh variable delete BACKUP_FRESHNESS_MONITOR_ENABLED --repo=${repository}"
echo "  gcloud storage buckets remove-iam-policy-binding gs://${bucket} --member=serviceAccount:${monitor_sa} --role=roles/storage.objectViewer"
echo "  gcloud storage buckets remove-iam-policy-binding gs://${bucket} --member=serviceAccount:${monitor_sa} --role=roles/storage.bucketViewer"
echo "  gcloud iam service-accounts remove-iam-policy-binding ${monitor_sa} --member='${principal_set}' --role=roles/iam.workloadIdentityUser"
echo "  gcloud iam service-accounts remove-iam-policy-binding ${monitor_sa} --member='${principal_set}' --role=roles/iam.serviceAccountTokenCreator"
# One-time cleanup of the retired experiment (already applied separately):
#   gcloud iam workload-identity-pools providers update-oidc ${provider} ...  # re-set the mapping without attribute.monitor_scope
