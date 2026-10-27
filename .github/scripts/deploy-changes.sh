#!/usr/bin/env bash
# Classify changed files for the ci-deploy workflow's `changes` job.
#
# Inputs (environment):
#   EVENT       github.event_name (push | pull_request | workflow_dispatch)
#   BEFORE_SHA  github.event.before for push events (empty on other events)
#   BASE_REF    github.base_ref for pull_request events
#
# Outputs (stdout, one key=value line each, written straight into
# $GITHUB_OUTPUT by the workflow):
#   deploy     the diff can change the deployed production artifact
#   benchmark  the benchmark suite must run (benchmark/feed-api changed, or deploy)
#   security   dependency checks must run (deny.toml changed, or above)
#
# Detection rules:
#   * push: diff the COMPLETE pushed range BEFORE_SHA..HEAD. HEAD^ alone
#     misses files changed in earlier commits of a multi-commit push, which
#     could leave production on an older build than main.
#   * New branch (BEFORE_SHA all-zero), force push (BEFORE_SHA not an
#     ancestor of HEAD), or an unfetchable BEFORE_SHA: deploy=true
#     conservatively. A spurious release build is cheap; a missed one is a
#     stale production.
#   * pull_request: three-dot diff against the base branch (deploy=false is
#     informational only — release/deploy jobs never run on pull requests).
#   * workflow_dispatch: run everything; the release/deploy jobs apply their
#     own explicit conditions (the deploy_production input), so a benchmark
#     dispatch can never deploy.
#   * ops/ is operator tooling and is not part of the deployed artifact:
#     never deploy-triggering.
set -Eeuo pipefail

event="${EVENT:?EVENT must be set}"
before="${BEFORE_SHA:-}"
base_ref="${BASE_REF:-}"

# classify DEPLOY BENCHMARK SECURITY -> prints the output lines
classify() {
  printf 'deploy=%s\nbenchmark=%s\nsecurity=%s\n' "$1" "$2" "$3"
}

# classify_files <changed-file-list> — event-agnostic classification of a
# diff; a file list matching no rule means nothing to build or check.
classify_files() {
  local files="$1"
  local deploy_files bench_files deny_files
  deploy_files="$(grep -E '^(src/|migrations/|config/|Cargo\.toml$|Cargo\.lock$|rust-toolchain\.toml$|Dockerfile$|\.github/workflows/ci-deploy\.yml$)' <<<"$files" || true)"
  bench_files="$(grep -E '^benchmark/feed-api/' <<<"$files" || true)"
  deny_files="$(grep -E '^deny\.toml$' <<<"$files" || true)"
  if [ -n "$deploy_files" ]; then
    classify true true true
  elif [ -n "$bench_files" ]; then
    classify false true true
  elif [ -n "$deny_files" ]; then
    classify false false true
  else
    classify false false false
  fi
}

case "$event" in
  pull_request)
    if [ -z "$base_ref" ]; then
      echo "BASE_REF required for pull_request events" >&2
      exit 1
    fi
    files="$(git diff --name-only "origin/${base_ref}...HEAD")"
    echo "changed files (pull_request origin/${base_ref}...HEAD):" >&2
    echo "$files" >&2
    classify_files "$files"
    ;;
  push)
    if [ -z "$before" ] || [[ "$before" =~ ^0+$ ]]; then
      echo "first push on the branch: deploy conservatively" >&2
      classify true true true
      exit 0
    fi
    if ! git cat-file -e "${before}^{commit}" 2>/dev/null \
      || ! git merge-base --is-ancestor "$before" HEAD 2>/dev/null; then
      echo "BEFORE_SHA ${before} is not an ancestor of HEAD (force push or rewritten history): deploy conservatively" >&2
      classify true true true
      exit 0
    fi
    files="$(git diff --name-only "${before}" HEAD)"
    echo "changed files (push ${before}..HEAD):" >&2
    echo "$files" >&2
    classify_files "$files"
    ;;
  workflow_dispatch)
    echo "manual dispatch: run everything (release/deploy jobs apply their own gates)" >&2
    classify true true true
    ;;
  *)
    echo "unknown event '${event}': run everything" >&2
    classify true true true
    ;;
esac
