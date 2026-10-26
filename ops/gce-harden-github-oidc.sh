#!/usr/bin/env bash
# Updates the EXISTING GitHub Actions workload-identity provider so that
# token exchange is restricted to refs/heads/main of the production
# repository, matched by the immutable numeric repository ID instead of the
# repository name.
#
# WHY: the current provider condition only pins assertion.repository to the
# repo NAME, so any ref of that repository (feature branches, PR merge
# refs) can mint a credential for the deployer service account. Matching on
# repository_id removes a rename-based substitution risk; pinning ref
# stops branches and pull requests from impersonating the deployer.
#
# This is an operator-approved infrastructure change, NOT part of CI:
#
#   # review the planned change (no writes):
#   ops/gce-harden-github-oidc.sh
#   # apply it:
#   ops/gce-harden-github-oidc.sh --apply
#
# After applying, verify with the read-only auth smoke test:
#   gh workflow run gcp-auth-smoke.yml --repo eswrops/rust-api-deployment-starter
# and only then rely on the new condition for a real deployment.
#
# Rollback restores the previous name-based condition (see the command the
# script prints on --apply).
set -Eeuo pipefail

project_id=${GCP_PROJECT_ID:-rust-product-foundry-4bd846}
pool=github-actions-pool
provider=github-actions-provider
repository=${GITHUB_REPOSITORY_NAME:-eswrops/rust-api-deployment-starter}
# Immutable repository id (gh api repos/<owner>/<repo> --jq .id).
repository_id=${GITHUB_REPOSITORY_ID:-1434567946}
branch=${ALLOWED_REF:-refs/heads/main}

# Keep the existing mappings and add repository_id so IAM conditions can
# use it. update-oidc REPLACES the full mapping, so merge into whatever the
# provider currently maps (other scripts may have added attributes, e.g.
# attribute.monitor_scope from ops/gce-configure-backup-monitor.sh).
attribute_mapping="$(python3 - "$(
  gcloud iam workload-identity-pools providers describe "$provider" \
    --workload-identity-pool="$pool" --location=global --project="$project_id" \
    --format='value(attributeMapping)'
)" <<'PY'
import sys
pairs = [p for p in sys.argv[1].split(";") if p]
if not any(p.split("=", 1)[0] == "attribute.repository_id" for p in pairs):
    pairs.append("attribute.repository_id=assertion.repository_id")
print(",".join(pairs))
PY
)"
new_condition="assertion.repository_id=='${repository_id}' && assertion.ref=='${branch}'"
old_condition="assertion.repository=='${repository}'"

apply=0
[ "${1:-}" = "--apply" ] && apply=1

current_condition="$(gcloud iam workload-identity-pools providers describe "$provider" \
  --workload-identity-pool="$pool" --location=global --project="$project_id" \
  --format='value(attributeCondition)')"
current_mapping="$(gcloud iam workload-identity-pools providers describe "$provider" \
  --workload-identity-pool="$pool" --location=global --project="$project_id" \
  --format='value(attributeMapping)' )"

echo "provider:            projects/${project_id}/locations/global/workloadIdentityPools/${pool}/providers/${provider}"
echo "current condition:   ${current_condition:-<none>}"
echo "current mapping:     ${current_mapping}"
echo
echo "planned condition:   ${new_condition}"
echo "planned mapping:     ${attribute_mapping}"

[ "$current_condition" = "$new_condition" ] && { echo "already applied"; exit 0; }

if [ "$apply" -ne 1 ]; then
  echo
  echo "dry run only: re-run with --apply to update the provider."
  exit 0
fi

gcloud iam workload-identity-pools providers update-oidc "$provider" \
  --workload-identity-pool="$pool" \
  --location=global \
  --project="$project_id" \
  --attribute-mapping="$attribute_mapping" \
  --attribute-condition="$new_condition"

echo
echo "provider updated. Next steps:"
echo "  1. gh workflow run gcp-auth-smoke.yml --repo ${repository}   # expect success on main, failure elsewhere"
echo "  2. verify a feature branch cannot authenticate (push a branch and run the smoke workflow against it)"
echo
echo "Rollback (restores the name-based condition):"
echo "  gcloud iam workload-identity-pools providers update-oidc ${provider} \\"
echo "    --workload-identity-pool=${pool} --location=global --project=${project_id} \\"
echo "    --attribute-condition=\"${old_condition}\""
