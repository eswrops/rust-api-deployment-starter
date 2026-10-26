#!/usr/bin/env bash
# Offline OCI CLI double for oci-a1-capacity-retry.sh tests.
set -Eeuo pipefail

mode="${MOCK_MODE:-success}"
state_file="${MOCK_STATE_FILE:?MOCK_STATE_FILE is required}"

# Remove the global launch-only options before command matching.
while [[ "${1:-}" == --no-retry || "${1:-}" == --read-timeout ]]; do
  if [[ "$1" == --read-timeout ]]; then shift 2; else shift; fi
done

case "$1 $2 $3" in
  "iam availability-domain list")
    [[ "$mode" != auth ]] || { printf '%s\n' 'NotAuthenticated'; exit 1; }
    printf '%s\n' '{"data":[{"name":"AD-1"}]}'
    ;;
  "iam region-subscription list")
    if [[ " $* " == *' --raw-output '* ]]; then printf '%s\n' 'ap-hyderabad-1'; else printf '%s\n' '{"data":[{"is-home-region":true,"region-name":"ap-hyderabad-1"}]}'; fi
    ;;
  "iam compartment list") printf '%s\n' '{"data":[]}' ;;
  "compute instance list")
    if [[ "$mode" == headroom ]]; then
      printf '%s\n' '{"data":[{"display-name":"another-a1","lifecycle-state":"RUNNING","shape":"VM.Standard.A1.Flex","shape-config":{"ocpus":2,"memory-in-gbs":12}}]}'
    else
      printf '%s\n' '{"data":[]}'
    fi
    ;;
  "bv boot-volume list"|"bv volume list") printf '%s\n' '{"data":[]}' ;;
  "usage-api usage-summary request-summarized-usages") printf '%s\n' '{"data":{"items":[]}}' ;;
  "network subnet list") printf '%s\n' '{"data":[{"display-name":"postgresmax-public-subnet","id":"subnet-1"}]}' ;;
  "network subnet get") printf '%s\n' '{"data":{"prohibit-public-ip-on-vnic":false,"route-table-id":"rt-1","vcn-id":"vcn-1","security-list-ids":["sl-1"]}}' ;;
  "network route-table get")
    if [[ "$mode" == bad_route ]]; then printf '%s\n' '{"data":{"route-rules":[]}}'; else printf '%s\n' '{"data":{"route-rules":[{"destination":"0.0.0.0/0","network-entity-id":"igw-1"}]}}'; fi
    ;;
  "network internet-gateway list") printf '%s\n' '{"data":[{"id":"igw-1","lifecycle-state":"AVAILABLE"}]}' ;;
  "network security-list get")
    if [[ "$mode" == bad_ingress || ! -f "$state_file" ]]; then
      printf '%s\n' '{"data":{"ingress-security-rules":[{"protocol":"6","source":"0.0.0.0/0","is-stateless":false,"tcp-options":{"destination-port-range":{"min":22,"max":22}}}]}}'
    else
      printf '%s\n' '{"data":{"ingress-security-rules":[{"protocol":"6","source":"198.51.100.10/32","is-stateless":false,"tcp-options":{"destination-port-range":{"min":22,"max":22}}}]}}'
    fi
    ;;
  "network security-list update") touch "$state_file" ;;
  "compute image list") printf '%s\n' '{"data":[{"id":"image-1","display-name":"Canonical-Ubuntu-24.04-2026.09.18-0"}]}' ;;
  "compute instance launch")
    if [[ "$mode" == capacity ]]; then printf '%s\n' 'OutOfHostCapacity'; exit 1; fi
    if [[ "$mode" == rate_limit ]]; then printf '%s\n' 'TooManyRequests'; exit 1; fi
    printf '%s\n' '{"data":{"id":"instance-1"}}'
    ;;
  "compute instance get") printf '%s\n' '{"data":{"lifecycle-state":"RUNNING"}}' ;;
  "compute vnic-attachment list") printf '%s\n' '{"data":[{"vnic-id":"vnic-1"}]}' ;;
  "network vnic get") printf '%s\n' '{"data":{"public-ip":"198.51.100.42"}}' ;;
  *) printf 'Unexpected mocked OCI command: %q\n' "$*" >&2; exit 64 ;;
esac
