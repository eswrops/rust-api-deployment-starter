#!/usr/bin/env bash
# Run locally only after api-bench.thetechs.top has a DNS-only AAAA record.
set -Eeuo pipefail

project_id=${GCP_PROJECT_ID:-rust-product-foundry-4bd846}
instance=${GCE_INSTANCE:-rust-api-prod}
zone=${GCE_ZONE:-us-west1-b}

gcloud compute ssh "$instance" \
  --project="$project_id" \
  --zone="$zone" \
  --tunnel-through-iap \
  --command='sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl start caddy && sudo systemctl status caddy --no-pager'
