#!/usr/bin/env bash
# Is EXPECTED_SHA still the tip of the remote main branch?
#
# Used by the deploy job twice: before authenticating (skip the deployment of
# a superseded run) and immediately before activation (fail a run that was
# overtaken mid-flight). Kept as a script so the decision logic has
# regression tests; the workflow only adds messaging around it.
#
# Inputs (environment):
#   EXPECTED_SHA  the commit this run built (required)
#   REMOTE        git remote to query [origin]
#   REMOTE_REF    fully qualified ref to compare [refs/heads/main]
#
# Output: the observed tip SHA on stdout (empty when it could not be read).
# Exit codes:
#   0  current    — EXPECTED_SHA is the tip; safe to proceed
#   1  superseded — the ref moved; deploying EXPECTED_SHA would regress main
#   2  unverifiable — the remote could not be queried or the ref is missing;
#      callers must fail closed (never activate an unverified artifact)
set -Eeuo pipefail

expected="${EXPECTED_SHA:?EXPECTED_SHA must be set}"
remote="${REMOTE:-origin}"
ref="${REMOTE_REF:-refs/heads/main}"

if ! tip="$(git ls-remote "$remote" "$ref" 2>/dev/null | awk '{print $1}')"; then
  echo "deploy-still-current: could not query $remote ($ref)" >&2
  exit 2
fi
if [ -z "$tip" ]; then
  echo "deploy-still-current: $remote has no $ref" >&2
  exit 2
fi

printf '%s\n' "$tip"
[ "$tip" = "$expected" ]
