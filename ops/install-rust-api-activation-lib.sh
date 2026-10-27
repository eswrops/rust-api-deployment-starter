#!/usr/bin/env bash
# Sourced by ops/install-rust-api-activation.sh. Pure decision logic, kept
# here so ops/test/test-install-rust-api-activation.sh (and the dedicated
# preflight unit tests) can exercise it without SSH, sudo or a VM.

# backfill_preflight_check DRYRUN_RC OUTPUT_FILE
#
# Decides whether the digest-backfill dry run permits `--apply`. The four
# requirements, all of which must hold:
#   1. the backfill tool exited 0 (ssh propagates the remote exit code; the
#      output is captured in full — never piped through tail, which would
#      mask the tool's status with tail's own);
#   2. the LAST output line is a well-formed summary;
#   3. the summary reports ZERO refused releases (any refusal — missing
#      binary, digest mismatch, bad name — stops the rollout);
#   4. no `backfill: FAIL:` diagnostic appears anywhere in the output
#      (unexpected tool-side failure text, even alongside exit 0).
# Prints the reason to stdout and returns 0 (apply permitted) or 1 (deny).
backfill_preflight_check() {
  local rc="$1" outfile="$2" summary
  if [ ! -s "$outfile" ]; then
    echo "backfill dry run produced no output"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "backfill dry run exited with status $rc"
    return 1
  fi
  summary="$(tail -n 1 "$outfile")"
  case "$summary" in
    *"release(s) scanned, "*"digest(s) recorded, "*"already correct, 0 refused") ;;
    *)
      echo "malformed or non-clean summary line: $summary"
      return 1
      ;;
  esac
  if grep -q '^backfill: FAIL:' "$outfile"; then
    echo "backfill dry run reported diagnostic failures"
    return 1
  fi
  return 0
}
