#!/usr/bin/env bash
# Test suite for .github/scripts/deploy-changes.sh, run against throwaway
# git repositories (no GitHub access, no checkout interference).
#
# The headline cases the suite exists for:
#   * multi-commit push where the production-relevant change is in the
#     FIRST commit (the old HEAD^ detection missed it and would have left
#     production stale);
#   * documentation-only pushes (single- and multi-commit) which must not
#     build or deploy anything.
# Also covers first pushes, force pushes, unfetchable BEFORE_SHA, PR
# three-dot diffs, workflow_dispatch, the ops/ exclusion, and output
# hygiene (stderr stays off $GITHUB_OUTPUT).
set -Eeuo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS $1"; }
repo="$temp/repo"

new_repo() {
  rm -rf "$repo" "$temp/origin.git"
  git init -q -b main "$repo"
  git -C "$repo" config user.email ci-test@example.invalid
  git -C "$repo" config user.name "CI test"
}

commit_file() { # commit_file <path> [content]
  mkdir -p "$repo/$(dirname "$1")"
  printf '%s\n' "${2:-content of $1}" >"$repo/$1"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "change $1"
}

head_sha() { git -C "$repo" rev-parse HEAD; }

# run_filter <event> [before] [base_ref] -> sets $out (stdout only)
run_filter() {
  out="$(cd "$repo" && EVENT="$1" BEFORE_SHA="${2:-}" BASE_REF="${3:-}" \
    bash "$script_dir/deploy-changes.sh" 2>/dev/null)"
}

# expect_out <label> <deploy> <benchmark> <security>
expect_out() {
  local expected="deploy=$2
benchmark=$3
security=$4"
  [ "$out" = "$expected" ] || die "$1: expected
$expected
got:
$out"
}

# --- push events -------------------------------------------------------------

# 1. Multi-commit push, production change in the FIRST commit: the complete
#    range must catch it (HEAD^ detection would report docs-only).
new_repo
commit_file src/main.rs
first_push_src="$(head_sha)"
commit_file README.md
commit_file docs/notes.md
run_filter push "$first_push_src^"
expect_out "multi-commit push, src in first commit" true true true
pass "multi-commit push with src in first commit deploys"

# 2. Multi-commit push, documentation-only throughout: no build, no deploy.
new_repo
commit_file README.md
base_docs="$(head_sha)"
commit_file docs/a.md
commit_file docs/b.md
run_filter push "$base_docs"
expect_out "multi-commit docs-only push" false false false
pass "multi-commit docs-only push does not deploy"

# 3. Multi-commit push, src in first commit and docs-only later commits.
new_repo
commit_file README.md
base_mixed="$(head_sha)"
commit_file src/lib.rs
commit_file docs/late.md
run_filter push "$base_mixed"
expect_out "mixed multi-commit push" true true true
pass "mixed multi-commit push deploys"

# 4. Single documentation-only commit.
new_repo
commit_file README.md
base_one="$(head_sha)"
commit_file CHANGELOG.md
run_filter push "$base_one"
expect_out "docs-only push" false false false
pass "docs-only push does not deploy"

# 5. Single src commit.
new_repo
commit_file README.md
base_src="$(head_sha)"
commit_file src/main.rs
run_filter push "$base_src"
expect_out "src push" true true true
pass "src push deploys"

# 6. Benchmark-only change: benchmark suite runs, no release build.
new_repo
commit_file README.md
base_bench="$(head_sha)"
commit_file benchmark/feed-api/src/main.rs
run_filter push "$base_bench"
expect_out "benchmark-only push" false true true
pass "benchmark-only push runs benchmark but does not deploy"

# 7. deny.toml change: security check runs, no build.
new_repo
commit_file README.md
base_deny="$(head_sha)"
commit_file deny.toml
run_filter push "$base_deny"
expect_out "deny.toml push" false false true
pass "deny.toml push runs security only"

# 8. Operator tooling (ops/) is never deploy-triggering.
new_repo
commit_file README.md
base_ops="$(head_sha)"
commit_file ops/backup/rust-api-backup
run_filter push "$base_ops"
expect_out "ops/backup push" false false false
commit_file ops/rust-api-activate
run_filter push "$base_ops"
expect_out "ops/rust-api-activate push" false false false
pass "ops/ changes do not deploy"

# 9. The deploy workflow itself is deploy-triggering.
new_repo
commit_file README.md
base_wf="$(head_sha)"
commit_file .github/workflows/ci-deploy.yml
run_filter push "$base_wf"
expect_out "workflow push" true true true
pass "workflow change deploys"

# 10. First push on a branch (all-zero BEFORE_SHA): deploy conservatively.
new_repo
commit_file src/main.rs
zero="0000000000000000000000000000000000000000"
run_filter push "$zero"
expect_out "first push" true true true
pass "first push deploys"

# 11. Force push: BEFORE_SHA not an ancestor of HEAD.
new_repo
commit_file README.md
divergence="$(head_sha)"
commit_file src/main.rs
old_head="$(head_sha)"
git -C "$repo" reset -q --hard "$divergence"
commit_file docs/rewritten.md
run_filter push "$old_head"
expect_out "force push" true true true
pass "force push deploys conservatively"

# 12. Unfetchable BEFORE_SHA (dangling commit): conservative.
new_repo
commit_file README.md
commit_file docs/x.md
run_filter push "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
expect_out "dangling BEFORE_SHA" true true true
pass "unfetchable BEFORE_SHA deploys conservatively"

# 13. Net-empty push range (revert of a revert) deploys nothing.
new_repo
commit_file README.md
net_base="$(head_sha)"
commit_file src/main.rs
src_sha="$(head_sha)"
git -C "$repo" revert --no-edit "$src_sha" >/dev/null
run_filter push "$net_base"
expect_out "net-empty push" false false false
pass "net-empty push range does not deploy"

# --- pull_request events -----------------------------------------------------

# 14. PR with a docs-only change.
new_repo
commit_file README.md
git -C "$repo" clone -q --bare "$repo" "$temp/origin.git"
git -C "$repo" remote add origin "$temp/origin.git"
git -C "$repo" fetch -q origin
git -C "$repo" checkout -qb feature
commit_file docs/pr-docs.md
run_filter pull_request "" main
expect_out "docs-only PR" false false false
pass "docs-only PR classified without deploy"

# 15. PR touching src.
new_repo
commit_file README.md
git -C "$repo" clone -q --bare "$repo" "$temp/origin.git"
git -C "$repo" remote add origin "$temp/origin.git"
git -C "$repo" fetch -q origin
git -C "$repo" checkout -qb feature
commit_file src/main.rs
run_filter pull_request "" main
expect_out "src PR" true true true
pass "src PR classified as deploy"

# 16. PR where base itself advanced after branching (three-dot diff must
#     ignore base-only changes).
new_repo
commit_file README.md
git -C "$repo" clone -q --bare "$repo" "$temp/origin.git"
git -C "$repo" remote add origin "$temp/origin.git"
git -C "$repo" fetch -q origin
git -C "$repo" checkout -qb feature
commit_file src/feature.rs
git -C "$repo" checkout -q main
commit_file docs/base-advanced.md
git -C "$repo" push -q origin main
git -C "$repo" checkout -q feature
run_filter pull_request "" main
expect_out "PR with advanced base" true true true
pass "PR three-dot diff ignores base-only changes"

# --- dispatch and fallbacks --------------------------------------------------

# 17. workflow_dispatch runs everything (release jobs add their own gates).
new_repo
run_filter workflow_dispatch
expect_out "workflow_dispatch" true true true
pass "workflow_dispatch runs everything"

# 18. Unknown event: conservative.
new_repo
run_filter release_publish
expect_out "unknown event" true true true
pass "unknown event is conservative"

# --- output hygiene ----------------------------------------------------------

# 19. stderr diagnostics (file lists) never reach stdout, so the workflow's
#     $GITHUB_OUTPUT only receives the three key=value lines.
new_repo
commit_file README.md
base_hygiene="$(head_sha)"
commit_file src/main.rs
raw_stdout="$(cd "$repo" && EVENT=push BEFORE_SHA="$base_hygiene" \
  bash "$script_dir/deploy-changes.sh" 2>/dev/null)"
[ "$(grep -c '=' <<<"$raw_stdout")" -eq 3 ] || die "stdout is not exactly 3 key=value lines:
$raw_stdout"
pass "diagnostics stay on stderr"

echo "all deploy-changes tests passed"
