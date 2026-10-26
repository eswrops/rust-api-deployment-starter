#!/usr/bin/env bash
# Creates the deliberately small, IPv6-only Compute Engine deployment.
set -Eeuo pipefail

project_id=${GCP_PROJECT_ID:-rust-product-foundry-4bd846}
region=${GCE_REGION:-us-west1}
zone=${GCE_ZONE:-us-west1-b}
network=rust-api-vpc
subnet=rust-api-us-west1
instance=rust-api-prod
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

exists() {
  "$@" >/dev/null 2>&1
}

gcloud services enable \
  compute.googleapis.com \
  iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com \
  billingbudgets.googleapis.com \
  --project="$project_id"

if ! exists gcloud compute networks describe "$network" --project="$project_id"; then
  gcloud compute networks create "$network" --subnet-mode=custom --project="$project_id"
fi

if ! exists gcloud compute networks subnets describe "$subnet" --region="$region" --project="$project_id"; then
  gcloud compute networks subnets create "$subnet" \
    --network="$network" \
    --region="$region" \
    --range=10.42.0.0/24 \
    --stack-type=IPV4_IPV6 \
    --ipv6-access-type=EXTERNAL \
    --project="$project_id"
fi

ensure_firewall() {
  local name=$1 rules=$2 sources=$3 tags=$4
  if exists gcloud compute firewall-rules describe "$name" --project="$project_id"; then
    gcloud compute firewall-rules update "$name" \
      --allow="$rules" --source-ranges="$sources" --target-tags="$tags" --project="$project_id"
  else
    gcloud compute firewall-rules create "$name" \
      --network="$network" --direction=INGRESS --action=ALLOW --priority=1000 \
      --rules="$rules" --source-ranges="$sources" --target-tags="$tags" --project="$project_id"
  fi
}

ensure_firewall rust-api-allow-iap-ssh tcp:22 35.235.240.0/20 iap-ssh
ensure_firewall rust-api-allow-web-ipv6 tcp:80,tcp:443 ::/0 rust-api-web

if ! exists gcloud compute instances describe "$instance" --zone="$zone" --project="$project_id"; then
  gcloud compute instances create "$instance" \
    --project="$project_id" \
    --zone="$zone" \
    --machine-type=e2-micro \
    --subnet="$subnet" \
    --stack-type=IPV4_IPV6 \
    --no-address \
    --image-family=ubuntu-2404-lts-amd64 \
    --image-project=ubuntu-os-cloud \
    --boot-disk-type=pd-standard \
    --boot-disk-size=30GB \
    --tags=iap-ssh,rust-api-web \
    --labels=app=rust-api,managed-by=gcloud \
    --metadata=block-project-ssh-keys=TRUE \
    --no-service-account --no-scopes \
    --deletion-protection \
    --shielded-vtpm --shielded-integrity-monitoring
fi

ipv6=$(gcloud compute instances describe "$instance" --project="$project_id" --zone="$zone" \
  --format='value(networkInterfaces[0].ipv6AccessConfigs[0].externalIpv6)')
[[ -n $ipv6 ]] || { echo 'VM did not receive an external IPv6 address' >&2; exit 1; }
printf 'Publish this DNS-only AAAA record before starting Caddy:\napi-bench.thetechs.top. IN AAAA %s\n' "${ipv6%%/*}"

remote_dir=/tmp/rust-api-bootstrap
gcloud compute ssh "$instance" --project="$project_id" --zone="$zone" --tunnel-through-iap \
  --command="rm -rf '$remote_dir' && mkdir -p '$remote_dir'"
gcloud compute scp --project="$project_id" --zone="$zone" --tunnel-through-iap \
  "$root/ops/gce-bootstrap.sh" \
  "$root/ops/rust-api-activate" \
  "$root/config/app.env.example" \
  "$root/config/rust-api.service" \
  "$root/config/Caddyfile" \
  "$instance:$remote_dir/"
gcloud compute ssh "$instance" --project="$project_id" --zone="$zone" --tunnel-through-iap \
  --command="sudo bash '$remote_dir/gce-bootstrap.sh' '$remote_dir'"

printf '\nBootstrap complete. After the AAAA record resolves, run:\n%s/ops/gce-enable-caddy.sh\n' "$root"
