#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$script_dir/oci-a1-capacity-retry.sh"
mock="$script_dir/test/mock-oci.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

run_case() {
  local name="$1" mode="$2" expected_status="$3" expected_text="$4" result status retry_window min_sleep max_sleep
  local case_dir="$tmp_dir/$name"
  retry_window=5
  min_sleep=0
  max_sleep=0
  if [[ "$mode" == capacity ]]; then
    retry_window=2
    min_sleep=1
    max_sleep=1
  fi
  if [[ "$mode" == rate_limit ]]; then
    retry_window=2
    min_sleep=1
    max_sleep=1
  fi
  mkdir -p "$case_dir/backups"
  printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@example' > "$case_dir/key.pub"
  printf '%s\n' '[DEFAULT]' 'region=ap-hyderabad-1' 'tenancy=tenancy-1' > "$case_dir/config"
  set +e
  result="$(MOCK_MODE="$mode" MOCK_STATE_FILE="$case_dir/state" \
    COMPARTMENT_ID=compartment-1 TENANCY_ID=tenancy-1 \
    SSH_PUBLIC_KEY_FILE="$case_dir/key.pub" SSH_SOURCE_CIDR=198.51.100.10/32 \
    OCI_BIN="$mock" OCI_CONFIG_FILE="$case_dir/config" LOG_FILE="$case_dir/run.log" BACKUP_DIR="$case_dir/backups" \
    RETRY_WINDOW_SECONDS="$retry_window" MIN_SLEEP_SECONDS="$min_sleep" MAX_SLEEP_SECONDS="$max_sleep" RATE_LIMIT_INITIAL_SECONDS=1 RATE_LIMIT_MAX_SECONDS=1 \
    "$script" 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq "$expected_status" ]] || { printf '%s\n' "FAIL $name: expected status $expected_status, got $status" "$result"; exit 1; }
  grep -Fq "$expected_text" <<< "$result" || { printf '%s\n' "FAIL $name: missing '$expected_text'" "$result"; exit 1; }
  printf 'PASS %s\n' "$name"
}

run_case success success 0 'Launch succeeded. Instance OCID: instance-1'
run_case capacity capacity 2 'No A1 capacity became available'
run_case rate_limit rate_limit 2 'Rate-limited; sleeping'
run_case authentication auth 1 'OCI authentication or compartment access failed'
run_case headroom headroom 1 'Projected A1 allocation is 3 OCPUs'
run_case missing_route bad_route 1 'Subnet has no active 0.0.0.0/0 route'
run_case bad_ingress bad_ingress 1 'did not verify as SSH-only'
