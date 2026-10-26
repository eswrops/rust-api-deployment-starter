#!/usr/bin/env bash
# Creates keyless GitHub Actions access for the one production VM, then records
# the resulting non-secret identifiers as repository variables through gh.
set -Eeuo pipefail

project_id=${GCP_PROJECT_ID:-rust-product-foundry-4bd846}
project_number=${GCP_PROJECT_NUMBER:-650296500144}
zone=${GCE_ZONE:-us-west1-b}
instance=${GCE_INSTANCE:-rust-api-prod}
repository=${GITHUB_REPOSITORY_NAME:-eswrops/rust-api-deployment-starter}
pool=github-actions-pool
provider=github-actions-provider
service_account_name=github-rust-api-deployer
service_account="${service_account_name}@${project_id}.iam.gserviceaccount.com"
instance_role_id=rustApiInstanceDeployer
instance_role_name="projects/${project_id}/roles/${instance_role_id}"
project_role_id=rustApiDeploymentProjectAccess
project_role_name="projects/${project_id}/roles/${project_role_id}"
provider_resource="projects/${project_number}/locations/global/workloadIdentityPools/${pool}/providers/${provider}"
instance_permissions='compute.instances.get,compute.instances.list,compute.instances.setMetadata'
project_permissions='compute.projects.get,compute.globalOperations.get,compute.zoneOperations.get'

exists() {
  "$@" >/dev/null 2>&1
}

if ! exists gcloud iam service-accounts describe "$service_account" --project="$project_id"; then
  gcloud iam service-accounts create "$service_account_name" \
    --project="$project_id" \
    --display-name='GitHub Rust API deployer'
fi

if exists gcloud iam roles describe "$instance_role_id" --project="$project_id"; then
  gcloud iam roles update "$instance_role_id" --project="$project_id" \
    --title='Rust API instance deployer' --stage=GA --permissions="$instance_permissions"
else
  gcloud iam roles create "$instance_role_id" --project="$project_id" \
    --title='Rust API instance deployer' --stage=GA --permissions="$instance_permissions"
fi

if exists gcloud iam roles describe "$project_role_id" --project="$project_id"; then
  gcloud iam roles update "$project_role_id" --project="$project_id" \
    --title='Rust API deploy project access' --stage=GA --permissions="$project_permissions"
else
  gcloud iam roles create "$project_role_id" --project="$project_id" \
    --title='Rust API deploy project access' --stage=GA --permissions="$project_permissions"
fi

if ! exists gcloud iam workload-identity-pools describe "$pool" --location=global --project="$project_id"; then
  gcloud iam workload-identity-pools create "$pool" --location=global --project="$project_id" \
    --display-name='GitHub Actions'
fi

if ! exists gcloud iam workload-identity-pools providers describe "$provider" \
  --workload-identity-pool="$pool" --location=global --project="$project_id"; then
  gcloud iam workload-identity-pools providers create-oidc "$provider" \
    --project="$project_id" \
    --location=global \
    --workload-identity-pool="$pool" \
    --display-name='GitHub Actions repository' \
    --issuer-uri='https://token.actions.githubusercontent.com' \
    --attribute-mapping='google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref' \
    --attribute-condition="assertion.repository=='${repository}'"
fi

principal_set="principalSet://iam.googleapis.com/projects/${project_number}/locations/global/workloadIdentityPools/${pool}/attribute.repository/${repository}"
gcloud iam service-accounts add-iam-policy-binding "$service_account" --project="$project_id" \
  --member="$principal_set" --role=roles/iam.workloadIdentityUser
gcloud projects add-iam-policy-binding "$project_id" \
  --member="serviceAccount:${service_account}" --role=roles/iap.tunnelResourceAccessor
gcloud projects add-iam-policy-binding "$project_id" \
  --member="serviceAccount:${service_account}" --role="$project_role_name"
gcloud compute instances add-iam-policy-binding "$instance" --zone="$zone" --project="$project_id" \
  --member="serviceAccount:${service_account}" --role="$instance_role_name"

gh api --method PUT "repos/${repository}/environments/production" >/dev/null
gh variable set GCP_PROJECT_ID --repo="$repository" --body="$project_id"
gh variable set GCP_WIF_PROVIDER --repo="$repository" --body="projects/${project_number}/locations/global/workloadIdentityPools/${pool}/providers/${provider}"
gh variable set GCP_DEPLOY_SERVICE_ACCOUNT --repo="$repository" --body="$service_account"
gh variable set GCE_INSTANCE --repo="$repository" --body="$instance"
gh variable set GCE_ZONE --repo="$repository" --body="$zone"
for secret in DEPLOY_HOST DEPLOY_SSH_KEY DEPLOY_KNOWN_HOSTS; do
  gh secret remove "$secret" --repo="$repository" 2>/dev/null || true
done

printf 'GitHub OIDC is ready for %s using %s.\n' "$repository" "$service_account"
