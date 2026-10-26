#!/usr/bin/env bash
# Prepares the EXTERNAL backup-freshness monitor (docs/backup-recovery.md,
# "External freshness monitoring"): a dedicated, read-only service account
# that only the backup-freshness.yml workflow on refs/heads/main may
# impersonate, with viewer rights on the backup bucket only.
#
# Impersonation restriction — how and why:
#   * Service-account-policy conditions CANNOT reference OIDC claims (the
#     `assertion` container is only declared in the workload-identity
#     provider's attribute condition), so --condition on the binding is not
#     an option.
#   * A principalSet URL matches exactly ONE mapped attribute, so compound
#     restrictions (repo AND ref AND workflow) cannot be spelled out in the
#     member URL either.
#   The provider mapping therefore COMPUTES a scope attribute from the raw
#   token claims and the binding matches identities whose scope is
#   'granted'. Tokens from a PR, a branch, or any other workflow evaluate
#   to 'denied' and cannot match the principal.
#
# OPERATOR-APPROVED INFRASTRUCTURE CHANGE, not part of CI:
#   ops/gce-configure-backup-monitor.sh          # dry run: shows the plan
#   ops/gce-configure-backup-monitor.sh --apply  # creates IAM + sets repo variables
#
# After --apply, verify delivery with an authorized test:
#   gh workflow run backup-freshness.yml --repo eswrops/rust-api-deployment-starter
#   gh run watch  # expect green with "freshness: all checks passed"
set -Eeuo pipefail

project_id=${GCP_PROJECT_ID:-rust-product-foundry-4bd846}
project_number=${GCP_PROJECT_NUMBER:-650296500144}
pool=github-actions-pool
provider=github-actions-provider
repository=${GITHUB_REPOSITORY_NAME:-eswrops/rust-api-deployment-starter}
bucket=${BACKUP_BUCKET:-rust-api-prod-backups-650296500144}
monitor_sa_name=rust-api-backup-monitor
monitor_sa="${monitor_sa_name}@${project_id}.iam.gserviceaccount.com"
monitor_workflow="repo/${repository}/.github/workflows/backup-freshness.yml"

# The compound restriction lives in the mapping (CEL over raw claims); the
# binding below then only needs the single derived attribute.
monitor_scope_mapping="attribute.monitor_scope=assertion.workflow == \"${monitor_workflow}\" && assertion.ref == \"refs/heads/main\" ? \"granted\" : \"denied\""
principal_set="principalSet://iam.googleapis.com/projects/${project_number}/locations/global/workloadIdentityPools/${pool}/attribute.monitor_scope/granted"

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
echo "bucket (viewer):   gs://${bucket}  (bucket-scope roles/storage.objectViewer only)"
echo "scope mapping:     ${monitor_scope_mapping}"
echo "WIF binding:       workloadIdentityUser for ${principal_set}"
echo "repo variables:    BACKUP_BUCKET=${bucket}"
echo "                   GCP_BACKUP_MONITOR_SERVICE_ACCOUNT=${monitor_sa}"
echo "                   BACKUP_FRESHNESS_MONITOR_ENABLED=true"

if [ "$apply" -ne 1 ]; then
  echo
  echo "dry run only: re-run with --apply to create the identity and enable the monitor."
  exit 0
fi

# 1. Add the scope attribute to the provider's mapping. update-oidc
#    REPLACES the whole mapping, so the existing mappings are merged with
#    the new one. The provider condition is left untouched (it is
#    hardened separately by ops/gce-harden-github-oidc.sh, which merges
#    its own additions into whatever mapping exists at that time).
current_mapping="$(gcloud iam workload-identity-pools providers describe "$provider" \
  --workload-identity-pool="$pool" --location=global --project="$project_id" \
  --format='value(attributeMapping)')"
current_condition="$(gcloud iam workload-identity-pools providers describe "$provider" \
  --workload-identity-pool="$pool" --location=global --project="$project_id" \
  --format='value(attributeCondition)')"
provider_mapping="$(python3 - "$current_mapping" "$monitor_scope_mapping" <<'PY'
import sys
current, extra = sys.argv[1], sys.argv[2]
extra_key = extra.split("=", 1)[0]
pairs = [p for p in current.split(";") if p]
if not any(p.split("=", 1)[0] == extra_key for p in pairs):
    pairs.append(extra)
print(",".join(pairs))
PY
)"
condition_args=()
[ -n "$current_condition" ] && condition_args+=(--attribute-condition="$current_condition")
retry gcloud iam workload-identity-pools providers update-oidc "$provider" \
  --workload-identity-pool="$pool" --location=global --project="$project_id" \
  --attribute-mapping="$provider_mapping" "${condition_args[@]}"

# 2. The read-only monitor identity.
if ! gcloud iam service-accounts describe "$monitor_sa" --project="$project_id" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$monitor_sa_name" \
    --project="$project_id" \
    --display-name='Backup freshness monitor (read-only, external check)'
fi
wait_for_service_account "$monitor_sa"

# Read-only, bucket-scoped: object reads/listing plus bucket metadata.
# objectViewer alone is not enough: gcloud storage resolves objects through
# a bucket metadata lookup that requires storage.buckets.get, which
# objectViewer deliberately does not include — hence the separate
# bucketViewer grant. Both are read-only and bound at this bucket only.
retry gcloud storage buckets add-iam-policy-binding "gs://${bucket}" \
  --member="serviceAccount:${monitor_sa}" \
  --role=roles/storage.objectViewer
retry gcloud storage buckets add-iam-policy-binding "gs://${bucket}" \
  --member="serviceAccount:${monitor_sa}" \
  --role=roles/storage.bucketViewer

# Impersonation restricted to identities whose computed scope is 'granted':
# only backup-freshness.yml running on refs/heads/main.
retry gcloud iam service-accounts add-iam-policy-binding "$monitor_sa" \
  --project="$project_id" \
  --member="$principal_set" \
  --role=roles/iam.workloadIdentityUser

# 3. Flip the workflow gate and provide the identifiers it needs.
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
echo "  gcloud storage buckets remove-iam-policy-binding gs://${bucket} --member=serviceAccount:${monitor_sa} --role=roles/storage.bucketViewer"
echo "  gcloud iam service-accounts remove-iam-policy-binding ${monitor_sa} --member='${principal_set}' --role=roles/iam.workloadIdentityUser"
echo "  # and remove attribute.monitor_scope from the provider mapping"
