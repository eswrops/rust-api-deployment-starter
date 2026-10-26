#!/usr/bin/env bash
# Provision one OCI Always Free A1 instance, retrying only temporary host-capacity
# failures. Run from an authenticated OCI Cloud Shell session.
#
# Required inputs:
#   COMPARTMENT_ID=ocid1.compartment... (the compute-instance compartment)
# Optional: NETWORK_COMPARTMENT_ID defaults to the tenancy root, where the
# selected subnet, route table, gateway, and security lists are stored.
#   SSH_PUBLIC_KEY_FILE=$HOME/oracle-a1.pub
#   SSH_SOURCE_CIDR=203.0.113.10/32    # the Mac's current public IPv4 address
#
# The script deliberately replaces ingress rules on every security list attached
# to the selected subnet. This is necessary to guarantee SSH-only access to the
# new VM, but can affect other resources in that subnet.

set -Eeuo pipefail

OCI_BIN="${OCI_BIN:-oci}"
JQ_BIN="${JQ_BIN:-jq}"

COMPARTMENT_ID="${COMPARTMENT_ID:-}"
TENANCY_ID="${TENANCY_ID:-}"
NETWORK_COMPARTMENT_ID="${NETWORK_COMPARTMENT_ID:-}"
SUBNET_NAME="${SUBNET_NAME:-postgresmax-public-subnet}"
DISPLAY_NAME="${DISPLAY_NAME:-rust-api-test}"
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-$HOME/oracle-a1.pub}"
SSH_SOURCE_CIDR="${SSH_SOURCE_CIDR:-}"

OCPUS="${OCPUS:-1}"
MEMORY_GB="${MEMORY_GB:-2}"
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-50}"
ALWAYS_FREE_OCPU_HOURS="${ALWAYS_FREE_OCPU_HOURS:-1500}"
ALWAYS_FREE_MEMORY_GB_HOURS="${ALWAYS_FREE_MEMORY_GB_HOURS:-9000}"
ALWAYS_FREE_BLOCK_VOLUME_GB="${ALWAYS_FREE_BLOCK_VOLUME_GB:-200}"
MONTHLY_HOURS="${MONTHLY_HOURS:-744}"

MIN_SLEEP_SECONDS="${MIN_SLEEP_SECONDS:-120}"
MAX_SLEEP_SECONDS="${MAX_SLEEP_SECONDS:-180}"
RETRY_WINDOW_SECONDS="${RETRY_WINDOW_SECONDS:-86400}"
RUNNING_WAIT_SECONDS="${RUNNING_WAIT_SECONDS:-1200}"
RATE_LIMIT_INITIAL_SECONDS="${RATE_LIMIT_INITIAL_SECONDS:-300}"
RATE_LIMIT_MAX_SECONDS="${RATE_LIMIT_MAX_SECONDS:-1800}"
LOG_FILE="${LOG_FILE:-$HOME/oci-a1-retry.log}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/oci-a1-security-list-backups}"

readonly SHAPE="VM.Standard.A1.Flex"
readonly REQUESTED_OCPU_HOURS="$((OCPUS * MONTHLY_HOURS))"
readonly REQUESTED_MEMORY_GB_HOURS="$((MEMORY_GB * MONTHLY_HOURS))"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  exit 1
}

is_valid_ipv4_32() {
  local cidr="$1" ip octet
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] || return 1
  ip="${cidr%/32}"
  local IFS=.
  read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] && ((10#$octet <= 255)) || return 1
  done
}

is_at_most() {
  "$JQ_BIN" -n --argjson value "$1" --argjson limit "$2" '$value <= $limit' | grep -qx true
}

# OCI CLI 3.95 emits an empty response (rather than {"data":[]}) for some
# successfully empty paginated list calls. Normalize only collection responses;
# malformed non-empty output remains an error.
collection_or_empty() {
  local response="$1"
  if [[ -z "$response" ]]; then
    printf '%s\n' '{"data":[]}'
  else
    "$JQ_BIN" -e '.data | type == "array"' >/dev/null <<< "$response" || return 1
    printf '%s\n' "$response"
  fi
}

read_config_value() {
  local key="$1"
  local config_file="${OCI_CONFIG_FILE:-$HOME/.oci/config}"
  local profile="${OCI_CLI_PROFILE:-DEFAULT}"
  [[ -r "$config_file" ]] || return 1
  awk -F= -v key="$key" -v profile="$profile" '
    $0 == "[" profile "]" { in_profile=1; next }
    /^\[/ { in_profile=0 }
    in_profile && $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      value=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$config_file"
}

read_tenancy_from_config() {
  read_config_value tenancy
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_config() {
  require_command "$OCI_BIN"
  require_command "$JQ_BIN"
  [[ -n "$COMPARTMENT_ID" ]] || die "Set COMPARTMENT_ID to the target compartment OCID."
  [[ -f "$SSH_PUBLIC_KEY_FILE" ]] || die "SSH public key file not found: $SSH_PUBLIC_KEY_FILE"
  is_valid_ipv4_32 "$SSH_SOURCE_CIDR" || die "Set SSH_SOURCE_CIDR to the Mac's public IPv4 in /32 form, for example 203.0.113.10/32."
  [[ "$OCPUS" =~ ^[1-9][0-9]*$ ]] || die "OCPUS must be a positive integer."
  [[ "$MEMORY_GB" =~ ^[1-9][0-9]*$ ]] || die "MEMORY_GB must be a positive integer."
  [[ "$BOOT_VOLUME_GB" =~ ^[1-9][0-9]*$ ]] || die "BOOT_VOLUME_GB must be a positive integer."
  (( MIN_SLEEP_SECONDS >= 0 && MAX_SLEEP_SECONDS >= MIN_SLEEP_SECONDS )) || die "Invalid retry sleep range."
  (( RETRY_WINDOW_SECONDS > 0 )) || die "RETRY_WINDOW_SECONDS must be positive."
  (( RATE_LIMIT_INITIAL_SECONDS > 0 && RATE_LIMIT_MAX_SECONDS >= RATE_LIMIT_INITIAL_SECONDS )) || die "Invalid rate-limit backoff range."

  if [[ -z "$TENANCY_ID" ]]; then
    TENANCY_ID="$(read_tenancy_from_config || true)"
  fi
  [[ -n "$TENANCY_ID" ]] || die "Set TENANCY_ID, or use a Cloud Shell OCI config with a DEFAULT tenancy value."
  NETWORK_COMPARTMENT_ID="${NETWORK_COMPARTMENT_ID:-$TENANCY_ID}"
}

authenticate_and_verify_region() {
  local configured_region home_region
  configured_region="$(read_config_value region || true)"
  [[ -n "$configured_region" && "$configured_region" != "None" ]] || die "OCI CLI has no configured region."
  "$OCI_BIN" iam availability-domain list --compartment-id "$COMPARTMENT_ID" --all --output json >/dev/null \
    || die "OCI authentication or compartment access failed. Sign in to Cloud Shell and verify COMPARTMENT_ID."
  home_region="$("$OCI_BIN" iam region-subscription list --tenancy-id "$TENANCY_ID" --all \
    --query 'data[?"is-home-region" == `true`]."region-name" | [0]' --raw-output 2>/dev/null)" \
    || die "Could not determine the tenancy home region."
  [[ -n "$home_region" && "$home_region" != "None" ]] || die "No tenancy home region was returned."
  [[ "$configured_region" == "$home_region" ]] \
    || die "Configured region '$configured_region' is not home region '$home_region'; launching here can incur block-volume charges."
  log "Authenticated in tenancy home region: $configured_region"
}

declare -a COMPARTMENT_IDS=()
declare -a AVAILABILITY_DOMAINS=()
declare -a SECURITY_LIST_IDS=()

discover_scope() {
  local compartments_json ads_json
  compartments_json="$("$OCI_BIN" iam compartment list --compartment-id "$TENANCY_ID" \
    --compartment-id-in-subtree true --all --lifecycle-state ACTIVE --output json)" \
    || die "Could not list accessible compartments for tenancy-wide free-tier validation."
  compartments_json="$(collection_or_empty "$compartments_json")" || die "Compartment listing returned malformed data."
  mapfile -t COMPARTMENT_IDS < <({ printf '%s\n' "$TENANCY_ID"; "$JQ_BIN" -r '.data[].id' <<< "$compartments_json"; } | awk '!seen[$0]++')
  ((${#COMPARTMENT_IDS[@]} > 0)) || die "No accessible compartments were returned."
  ads_json="$("$OCI_BIN" iam availability-domain list --compartment-id "$TENANCY_ID" --all --output json)" \
    || die "Could not list availability domains."
  mapfile -t AVAILABILITY_DOMAINS < <("$JQ_BIN" -r '.data[].name' <<< "$ads_json")
  ((${#AVAILABILITY_DOMAINS[@]} > 0)) || die "No availability domains were returned."
  log "Found ${#AVAILABILITY_DOMAINS[@]} availability domain(s): ${AVAILABILITY_DOMAINS[*]}"
}

check_free_tier_headroom() {
  local compartment ad instances_json boot_json block_json totals current_ocpus current_memory current_volume
  current_ocpus=0
  current_memory=0
  current_volume=0
  for compartment in "${COMPARTMENT_IDS[@]}"; do
    instances_json="$("$OCI_BIN" compute instance list --compartment-id "$compartment" --all --output json)" \
      || die "Could not list instances in a tenancy compartment; cannot safely verify A1 free-tier headroom."
    instances_json="$(collection_or_empty "$instances_json")" || die "Instance listing returned malformed data."
    totals="$(DISPLAY_NAME="$DISPLAY_NAME" "$JQ_BIN" '
      .data as $instances
      | [$instances[] | select(.shape == "VM.Standard.A1.Flex" and .["lifecycle-state"] != "TERMINATED") | .["shape-config"]] as $a1
      | {
          ocpus: ($a1 | map(.ocpus // 0) | add // 0),
          memory: ($a1 | map(.["memory-in-gbs"] // 0) | add // 0),
          duplicate: ([$instances[] | select(.["display-name"] == env.DISPLAY_NAME and .["lifecycle-state"] != "TERMINATED")] | length)
        }
    ' <<< "$instances_json")"
    [[ "$("$JQ_BIN" -r '.duplicate' <<< "$totals")" == "0" ]] || die "A non-terminated instance named '$DISPLAY_NAME' already exists; refusing to create a duplicate."
    current_ocpus="$("$JQ_BIN" -n --argjson a "$current_ocpus" --argjson b "$("$JQ_BIN" -r '.ocpus' <<< "$totals")" '$a + $b')"
    current_memory="$("$JQ_BIN" -n --argjson a "$current_memory" --argjson b "$("$JQ_BIN" -r '.memory' <<< "$totals")" '$a + $b')"
    for ad in "${AVAILABILITY_DOMAINS[@]}"; do
      boot_json="$("$OCI_BIN" bv boot-volume list --compartment-id "$compartment" --availability-domain "$ad" --all --output json)" || die "Could not list boot volumes; cannot safely verify free-tier block-volume headroom."
      block_json="$("$OCI_BIN" bv volume list --compartment-id "$compartment" --availability-domain "$ad" --all --output json)" || die "Could not list block volumes; cannot safely verify free-tier block-volume headroom."
      boot_json="$(collection_or_empty "$boot_json")" || die "Boot-volume listing returned malformed data."
      block_json="$(collection_or_empty "$block_json")" || die "Block-volume listing returned malformed data."
      current_volume="$("$JQ_BIN" -n --argjson a "$current_volume" --argjson b "$("$JQ_BIN" '[.data[] | .["size-in-gbs"] // 0] | add // 0' <<< "$boot_json")" --argjson c "$("$JQ_BIN" '[.data[] | .["size-in-gbs"] // 0] | add // 0' <<< "$block_json")" '$a + $b + $c')"
    done
  done
  local projected_ocpus projected_memory projected_volume
  projected_ocpus="$("$JQ_BIN" -n --argjson a "$current_ocpus" --argjson b "$OCPUS" '$a + $b')"
  projected_memory="$("$JQ_BIN" -n --argjson a "$current_memory" --argjson b "$MEMORY_GB" '$a + $b')"
  projected_volume="$("$JQ_BIN" -n --argjson a "$current_volume" --argjson b "$BOOT_VOLUME_GB" '$a + $b')"
  is_at_most "$projected_ocpus" 2 || die "Projected A1 allocation is ${projected_ocpus} OCPUs, above the 2-OCPU Always Free allowance."
  is_at_most "$projected_memory" 12 || die "Projected A1 allocation is ${projected_memory} GB, above the 12-GB Always Free allowance."
  is_at_most "$projected_volume" "$ALWAYS_FREE_BLOCK_VOLUME_GB" || die "Projected block-volume allocation is ${projected_volume} GB, above the ${ALWAYS_FREE_BLOCK_VOLUME_GB}-GB Always Free allowance."
  (( REQUESTED_OCPU_HOURS <= ALWAYS_FREE_OCPU_HOURS )) || die "Requested monthly OCPU usage (${REQUESTED_OCPU_HOURS} hours) exceeds the Always Free allowance."
  (( REQUESTED_MEMORY_GB_HOURS <= ALWAYS_FREE_MEMORY_GB_HOURS )) || die "Requested monthly memory usage (${REQUESTED_MEMORY_GB_HOURS} GB-hours) exceeds the Always Free allowance."
  log "Always Free projection: ${projected_ocpus}/2 OCPUs, ${projected_memory}/12 GB RAM, ${projected_volume}/${ALWAYS_FREE_BLOCK_VOLUME_GB} GB volumes."
  log "This VM adds ${REQUESTED_OCPU_HOURS} OCPU-hours and ${REQUESTED_MEMORY_GB_HOURS} GB-hours per 31-day month. Projected incremental instance cost: US\$0 while these tenancy-wide allowances remain available."
}

report_month_to_date_cost() {
  local month_start usage_end usage_json
  month_start="$(date -u '+%Y-%m-01T00:00:00Z')"
  usage_end="$(date -u '+%Y-%m-%dT00:00:00Z')"
  # Usage API requires UTC boundaries whose hour, minute, second, and fraction
  # are zero. On the first of a month, query the completed prior month instead.
  if [[ "$usage_end" == "$month_start" ]]; then
    if usage_end="$(date -u -d "$month_start -1 month" '+%Y-%m-01T00:00:00Z' 2>/dev/null)"; then
      :
    else
      usage_end="$(date -u -v-1m -j -f '%Y-%m-%dT%H:%M:%SZ' "$month_start" '+%Y-%m-01T00:00:00Z')" || die "Could not calculate the prior calendar month for Cost Analysis."
    fi
    usage_json="$("$OCI_BIN" usage-api usage-summary request-summarized-usages --tenant-id "$TENANCY_ID" --time-usage-started "$usage_end" --time-usage-ended "$month_start" --granularity MONTHLY --is-aggregate-by-time true --query-type COST --group-by '["service"]' --output json)" || die "Could not query OCI cost data; refusing to launch without cost evidence."
  else
    usage_json="$("$OCI_BIN" usage-api usage-summary request-summarized-usages --tenant-id "$TENANCY_ID" --time-usage-started "$month_start" --time-usage-ended "$usage_end" --granularity MONTHLY --is-aggregate-by-time true --query-type COST --group-by '["service"]' --output json)" || die "Could not query month-to-date OCI cost data; refusing to launch without cost evidence."
  fi
  log "Month-to-date Cost Analysis response (historical data, not a binding quote):"
  "$JQ_BIN" -c '.data.items // .data' <<< "$usage_json" | tee -a "$LOG_FILE"
}

discover_and_verify_network() {
  local subnets_json subnet_json route_json gateways_json route_table_id vcn_id found_route gateway_id
  subnets_json="$("$OCI_BIN" network subnet list --compartment-id "$NETWORK_COMPARTMENT_ID" --all --output json)" || die "Could not list subnets in NETWORK_COMPARTMENT_ID."
  subnets_json="$(collection_or_empty "$subnets_json")" || die "Subnet listing returned malformed data."
  mapfile -t subnet_matches < <("$JQ_BIN" -r --arg name "$SUBNET_NAME" '.data[] | select(.["display-name"] == $name) | .id' <<< "$subnets_json")
  [[ ${#subnet_matches[@]} -eq 1 ]] || die "Expected exactly one subnet named '$SUBNET_NAME'; found ${#subnet_matches[@]}. Use a unique subnet name."
  SUBNET_ID="${subnet_matches[0]}"
  subnet_json="$("$OCI_BIN" network subnet get --subnet-id "$SUBNET_ID" --output json)" || die "Could not read subnet '$SUBNET_NAME'."
  [[ "$("$JQ_BIN" -r '.data["prohibit-public-ip-on-vnic"]' <<< "$subnet_json")" == "false" ]] || die "Subnet '$SUBNET_NAME' prohibits public IPs."
  route_table_id="$("$JQ_BIN" -r '.data["route-table-id"] // empty' <<< "$subnet_json")"
  vcn_id="$("$JQ_BIN" -r '.data["vcn-id"] // empty' <<< "$subnet_json")"
  [[ -n "$route_table_id" && -n "$vcn_id" ]] || die "Subnet is missing its route-table or VCN reference."
  route_json="$("$OCI_BIN" network route-table get --rt-id "$route_table_id" --output json)" || die "Could not read the subnet route table."
  gateways_json="$("$OCI_BIN" network internet-gateway list --compartment-id "$NETWORK_COMPARTMENT_ID" --vcn-id "$vcn_id" --all --output json)" || die "Could not list internet gateways for the subnet VCN."
  gateways_json="$(collection_or_empty "$gateways_json")" || die "Internet-gateway listing returned malformed data."
  found_route=false
  while IFS= read -r gateway_id; do
    if "$JQ_BIN" -e --arg gateway "$gateway_id" '.data["route-rules"][]? | select(.destination == "0.0.0.0/0" and .["network-entity-id"] == $gateway)' <<< "$route_json" >/dev/null; then found_route=true; break; fi
  done < <("$JQ_BIN" -r '.data[] | select(.["lifecycle-state"] == "AVAILABLE") | .id' <<< "$gateways_json")
  [[ "$found_route" == true ]] || die "Subnet has no active 0.0.0.0/0 route through an internet gateway."
  mapfile -t SECURITY_LIST_IDS < <("$JQ_BIN" -r '.data["security-list-ids"][]?' <<< "$subnet_json")
  ((${#SECURITY_LIST_IDS[@]} > 0)) || die "Subnet has no attached security lists to enforce SSH-only ingress."
  log "Verified public subnet '$SUBNET_NAME' and its internet-gateway route."
}

replace_and_verify_ingress_rules() {
  local security_list_id current_json rule_json verified_json timestamp
  mkdir -p "$BACKUP_DIR"
  rule_json="$("$JQ_BIN" -n --arg source "$SSH_SOURCE_CIDR" '[{protocol: "6", source: $source, sourceType: "CIDR_BLOCK", isStateless: false, tcpOptions: {destinationPortRange: {min: 22, max: 22}}, description: "SSH from authorized Mac for rust-api-test"}]')"
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  for security_list_id in "${SECURITY_LIST_IDS[@]}"; do
    current_json="$("$OCI_BIN" network security-list get --security-list-id "$security_list_id" --output json)" || die "Could not read security list $security_list_id."
    printf '%s\n' "$current_json" > "$BACKUP_DIR/${security_list_id##*.}-$timestamp-before.json"
    log "Backed up and replacing ingress rules on security list $security_list_id."
    "$OCI_BIN" network security-list update --security-list-id "$security_list_id" --ingress-security-rules "$rule_json" --force --output json >/dev/null || die "Could not replace ingress rules on security list $security_list_id."
    verified_json="$("$OCI_BIN" network security-list get --security-list-id "$security_list_id" --output json)" || die "Could not verify security list $security_list_id after update."
    "$JQ_BIN" -e --arg source "$SSH_SOURCE_CIDR" '.data["ingress-security-rules"] as $rules | ($rules | length) == 1 and ($rules[0].protocol == "6") and ($rules[0].source == $source) and ($rules[0]["is-stateless"] == false) and ($rules[0]["tcp-options"]["destination-port-range"].min == 22) and ($rules[0]["tcp-options"]["destination-port-range"].max == 22)' <<< "$verified_json" >/dev/null || die "Security list $security_list_id did not verify as SSH-only from $SSH_SOURCE_CIDR."
  done
  log "All subnet security lists now allow only TCP/22 from $SSH_SOURCE_CIDR for inbound traffic."
}

discover_image() {
  local images_json
  images_json="$("$OCI_BIN" compute image list --compartment-id "$TENANCY_ID" --operating-system 'Canonical Ubuntu' --operating-system-version 24.04 --shape "$SHAPE" --all --sort-by TIMECREATED --sort-order DESC --output json)" || die "Could not list Canonical Ubuntu 24.04 images for $SHAPE."
  images_json="$(collection_or_empty "$images_json")" || die "Image listing returned malformed data."
  IMAGE_ID="$("$JQ_BIN" -r '[.data[] | select((.["display-name"] | startswith("Canonical-Ubuntu-24.04-")) and (.["display-name"] | contains("Minimal") | not))][0].id // empty' <<< "$images_json")"
  [[ -n "$IMAGE_ID" ]] || die "No non-Minimal Ubuntu 24.04 A1-compatible image was found."
  log "Selected Ubuntu 24.04 ARM-compatible image: $IMAGE_ID"
}

launch_once() {
  local ad="$1" output status instance_id
  log "Attempting launch in $ad..."
  if output="$("$OCI_BIN" --no-retry --read-timeout 30 compute instance launch --availability-domain "$ad" --compartment-id "$COMPARTMENT_ID" --display-name "$DISPLAY_NAME" --shape "$SHAPE" --shape-config "{\"ocpus\":${OCPUS},\"memoryInGBs\":${MEMORY_GB}}" --subnet-id "$SUBNET_ID" --image-id "$IMAGE_ID" --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" --assign-public-ip true --ssh-authorized-keys-file "$SSH_PUBLIC_KEY_FILE" --freeform-tags '{"managed-by":"oci-a1-capacity-retry","purpose":"rust-api-test"}' --output json 2>&1)"; then
    printf '%s\n' "$output" | tee -a "$LOG_FILE"
    instance_id="$("$JQ_BIN" -r '.data.id // empty' <<< "$output")"
    [[ -n "$instance_id" ]] || die "Launch returned success without an instance OCID."
    wait_for_running "$instance_id"
    report_instance_connection "$instance_id"
    return 0
  else
    status=$?
    printf '%s\n' "$output" | tee -a "$LOG_FILE"
    if grep -Eiq 'out of host capacity|out of capacity|OutOfHostCapacity' <<< "$output"; then log "Capacity unavailable in $ad; continuing."; return 10; fi
    if grep -Eiq 'TooManyRequests|too many requests|status": 429' <<< "$output"; then log "OCI rate limited the launch request; backing off before another attempt."; return 11; fi
    die "OCI launch failed for a non-capacity reason (exit $status). Fix the error before retrying."
  fi
}

wait_for_running() {
  local instance_id="$1" deadline now state_json state
  deadline=$(( $(date +%s) + RUNNING_WAIT_SECONDS ))
  while (( $(date +%s) < deadline )); do
    state_json="$("$OCI_BIN" compute instance get --instance-id "$instance_id" --output json)" \
      || die "Launch was accepted for $instance_id, but its lifecycle state could not be read."
    state="$("$JQ_BIN" -r '.data["lifecycle-state"] // empty' <<< "$state_json")"
    case "$state" in
      RUNNING) return 0 ;;
      TERMINATED|TERMINATING) die "Instance $instance_id entered $state after launch." ;;
      *) log "Instance $instance_id is ${state:-in an unknown state}; waiting for RUNNING." ;;
    esac
    sleep 15
  done
  die "Instance $instance_id did not reach RUNNING within ${RUNNING_WAIT_SECONDS}s."
}

report_instance_connection() {
  local instance_id="$1" attachments_json vnic_id vnic_json public_ip
  attachments_json="$("$OCI_BIN" compute vnic-attachment list --compartment-id "$COMPARTMENT_ID" --instance-id "$instance_id" --all --output json)" || die "Instance launched ($instance_id), but VNIC attachments could not be listed."
  attachments_json="$(collection_or_empty "$attachments_json")" || die "VNIC attachment listing returned malformed data."
  vnic_id="$("$JQ_BIN" -r '.data[0]["vnic-id"] // empty' <<< "$attachments_json")"
  [[ -n "$vnic_id" ]] || die "Instance launched ($instance_id), but no primary VNIC was found."
  vnic_json="$("$OCI_BIN" network vnic get --vnic-id "$vnic_id" --output json)" || die "Instance launched ($instance_id), but its VNIC could not be read."
  public_ip="$("$JQ_BIN" -r '.data["public-ip"] // empty' <<< "$vnic_json")"
  log "Launch succeeded. Instance OCID: $instance_id"
  [[ -n "$public_ip" ]] && { log "Public IP: $public_ip"; log "Connect with: ssh ubuntu@$public_ip"; } || log "Instance is RUNNING but does not yet report a public IP; inspect the VNIC in OCI Console."
}

retry_launch() {
  local start_epoch deadline_epoch now_epoch delay result ad rate_limit_delay rate_limited
  start_epoch="$(date +%s)"; deadline_epoch=$((start_epoch + RETRY_WINDOW_SECONDS))
  rate_limit_delay="$RATE_LIMIT_INITIAL_SECONDS"
  log "Retrying capacity failures for up to ${RETRY_WINDOW_SECONDS}s; capacity sleep range ${MIN_SLEEP_SECONDS}-${MAX_SLEEP_SECONDS}s."
  while (( $(date +%s) < deadline_epoch )); do
    rate_limited=false
    for ad in "${AVAILABILITY_DOMAINS[@]}"; do
      (( $(date +%s) < deadline_epoch )) || break
      if launch_once "$ad"; then exit 0; else
        result=$?
        if [[ "$result" -eq 11 ]]; then rate_limited=true; break; fi
        [[ "$result" -eq 10 ]] || exit "$result"
      fi
    done
    now_epoch="$(date +%s)"; (( now_epoch < deadline_epoch )) || break
    if [[ "$rate_limited" == true ]]; then
      delay="$rate_limit_delay"
      rate_limit_delay=$((rate_limit_delay * 2))
      (( rate_limit_delay <= RATE_LIMIT_MAX_SECONDS )) || rate_limit_delay="$RATE_LIMIT_MAX_SECONDS"
      log "Rate-limited; sleeping ${delay}s before retrying."
    else
      rate_limit_delay="$RATE_LIMIT_INITIAL_SECONDS"
      delay=$((MIN_SLEEP_SECONDS + RANDOM % (MAX_SLEEP_SECONDS - MIN_SLEEP_SECONDS + 1)))
      log "No A1 capacity found in this pass. Sleeping ${delay}s before retrying."
    fi
    (( now_epoch + delay <= deadline_epoch )) || delay=$((deadline_epoch - now_epoch))
    sleep "$delay"
  done
  log "No A1 capacity became available within ${RETRY_WINDOW_SECONDS}s. No instance was created."
  exit 2
}

main() {
  require_config
  authenticate_and_verify_region
  discover_scope
  check_free_tier_headroom
  report_month_to_date_cost
  discover_and_verify_network
  replace_and_verify_ingress_rules
  discover_image
  retry_launch
}

main "$@"
