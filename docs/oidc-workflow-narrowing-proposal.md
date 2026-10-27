# OIDC workflow-identity narrowing — cutover proposal

Status: **PROPOSAL ONLY — no IAM change was made or is made by the PR that
ships this document.** Applying it requires operator approval and an
approved maintenance window with rollback at hand.

Reviewed 2026-10-27 (read-only) for the deployment-isolation mission's
question: *can the repository-wide service-account impersonation bindings be
narrowed through independently verified workflow identity restrictions?*

## Current verified state

- Provider condition (read via
  `gcloud iam workload-identity-pools providers describe` on 2026-10-27):
  `assertion.repository_id=='1434567946' && assertion.ref=='refs/heads/main'`
  — applied by `ops/gce-harden-github-oidc.sh --apply` and independently
  verified: deploy run 40420614888 and monitor run 40423374073 both
  succeeded from `main` after the change.
- SA-level bindings (deployer `github-rust-api-deployer@…`, monitor
  `rust-api-backup-monitor@…`): `workloadIdentityUser` +
  `serviceAccountTokenCreator` on
  `principalSet://…/attribute.repository/eswrops/rust-api-deployment-starter`.
- Net effect today: only `main`-branch runs of this repository can mint
  either SA, regardless of which workflow file asks. Feature branches and
  pull-request runs cannot exchange tokens at all.

## Residual exposure

Any job on `main` that requests `id-token: write` can mint **either**
service account: a future workflow (or an edit to an existing one) merged to
`main` gains deployer capability without any IAM review. The SA bindings
cannot express the narrowing themselves — SA-policy conditions cannot
reference OIDC claims, and CEL-computed attribute principalSets do not match
on the `iamcredentials` minting path (both verified 2026-10-27, PRs #3–#6) —
so the provider condition is the only place a workflow-level restriction can
live.

## Proposed narrowing: `job_workflow_ref` allowlist

GitHub's OIDC tokens carry `job_workflow_ref`
(`<owner>/<repo>/.github/workflows/<file>@<ref>`), which identifies the
workflow file that ran the job. Adding it to the mapping and allowlisting
the three workflows that legitimately use Google credentials collapses
"any workflow on main" to "these three files on main":

1. Read the current mapping and merge (update-oidc REPLACES the mapping):
   add `attribute.job_workflow_ref=assertion.job_workflow_ref` to the
   existing `google.subject` / `attribute.repository` / `attribute.ref` /
   `attribute.repository_id` entries.
2. New condition:
   ```
   assertion.repository_id=='1434567946'
     && assertion.ref=='refs/heads/main'
     && assertion.job_workflow_ref in [
          'eswrops/rust-api-deployment-starter/.github/workflows/ci-deploy.yml@refs/heads/main',
          'eswrops/rust-api-deployment-starter/.github/workflows/backup-freshness.yml@refs/heads/main',
          'eswrops/rust-api-deployment-starter/.github/workflows/gcp-auth-smoke.yml@refs/heads/main'
        ]
   ```
   (validate CEL syntax with a dry run; the file list is the entire set of
   workflows whose jobs hold `id-token: write` after the current PR).
3. Propagation: SA-policy/provider changes take up to ~5 minutes to reach
   the `iamcredentials` path; wait before concluding failure.
4. Verification (independently, before relying on it):
   - dispatch `gcp-auth-smoke.yml` on `main` → must succeed;
   - dispatch `backup-freshness.yml` on `main` → must succeed;
   - dispatch a deploy (`ci-deploy.yml`, gate off) on `main` → auth step
     must succeed;
   - any OTHER workflow requesting `id-token: write` on `main`, or any of
     the three from a non-main ref → must FAIL (that failure is the proof).
5. Rollback: re-run `update-oidc` with the current condition
   (`repository_id && ref`), which is itself a strict improvement over the
   original name-only condition.

## Known limitations of the allowlist

- `job_workflow_ref` names a *file* in the repo: editing an allowlisted
  workflow file is still a merge to `main` — the allowlist narrows the
  surface from "any workflow" to "reviewed files", it does not remove the
  need for main-branch review discipline.
- Reusable-workflow callers would carry the caller's `job_workflow_ref`;
  this repository uses none, and the condition would fail closed for them.
- The `production` environment on the deploy job (branch/tag protection,
  optional required reviewers) is a complementary GitHub-side gate and
  orthogonal to this change; tightening it is cheap and independent.

## Cutover checklist (when approved)

- [ ] Merge-mapping + condition change scripted as an `--apply`-gated
      addition to `ops/gce-harden-github-oidc.sh` (dry run prints rollback).
- [ ] Run the four verification dispatches above.
- [ ] One real deployment exercised end-to-end before removing the old
      condition from the runbook.
