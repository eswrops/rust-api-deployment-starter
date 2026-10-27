# OIDC workflow-identity narrowing — cutover proposal

Status: **PROPOSAL ONLY — no IAM change was made or is made by the PR that
ships this document.** Applying it requires operator approval and an
approved maintenance window with rollback at hand.

Reviewed 2026-10-27 (read-only) for the deployment-isolation mission's
question: *can the repository-wide service-account impersonation bindings be
narrowed through independently verified workflow identity restrictions?*

## Claim verification (this repository, empirically)

GitHub documents `workflow_ref` as "The ref path to the workflow" for all
workflow jobs, and `job_workflow_ref` as "For jobs using a reusable
workflow, the ref path to the reusable workflow"
(docs.github.com/actions/reference/openid-connect-reference). Because the
reusable-workflow wording does not promise anything for ordinary jobs, the
claim set was verified against a live token minted by THIS repository
before being relied on:

- Evidence: `gcp-auth-smoke.yml` `claims` job, run
  [40456605970](https://github.com/eswrops/rust-api-deployment-starter/actions/runs/40456605970)
  (workflow_dispatch on `refs/heads/ci/deployment-isolation-release-safety`,
  an ordinary non-reusable job, token payload decoded in the log — signature
  never printed). The workflow that performs this check is merged with this
  proposal so the evidence is reproducible on `main`.
- Result: an ordinary workflow job in this repository carries BOTH
  - `workflow_ref: <repo>/.github/workflows/gcp-auth-smoke.yml@refs/heads/<branch>`
  - `job_workflow_ref: <same value>`
  plus `workflow_sha`/`job_workflow_sha`. `repository_id` matches the value
  already pinned in the provider condition.
- Claim choice: the condition below uses **`workflow_ref`**, because it is
  documented for every workflow job and, if a reusable-workflow caller is
  ever introduced, it keeps naming the *entry-point* workflow file in this
  repository (`job_workflow_ref` would then name the called workflow — in a
  foreign repo for third-party reusable workflows, which must fail closed).
  This repository currently has no reusable-workflow definitions or callers
  (verified by grep); for today's ordinary jobs both claims are populated
  and equal, so the condition is correct under either.

## Current verified state

- Provider condition (read via
  `gcloud iam workload-identity-pools providers describe` on 2026-10-27):
  `assertion.repository_id=='1434567946' && assertion.ref=='refs/heads/main'`
  — applied by `ops/gce-harden-github-oidc.sh --apply` and independently
  verified: deploy run 40420614888 and monitor run 40423374073 both
  succeeded from `main` after the change. The fail-closed side is also
  proven: the same dispatch series that captured the claims above was
  rejected by the attribute condition on a non-main ref ("The given
  credential is rejected by the attribute condition", run 40456605970,
  `smoke` job).
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

## Proposed narrowing: `workflow_ref` allowlist

`workflow_ref` identifies the workflow file that ran the job
(`<owner>/<repo>/.github/workflows/<file>@<ref>`, verified above).
Allowlisting it collapses "any workflow on main" to "these three files on
main" — the entire set of workflows whose jobs hold `id-token: write` after
the current PR:

1. Read the current mapping and merge (update-oidc REPLACES the mapping):
   add `attribute.workflow_ref=assertion.workflow_ref` to the existing
   `google.subject` / `attribute.repository` / `attribute.ref` /
   `attribute.repository_id` entries.
2. New condition (CEL; validate with a dry run before applying):
   ```
   assertion.repository_id=='1434567946'
     && assertion.ref=='refs/heads/main'
     && assertion.workflow_ref in [
          'eswrops/rust-api-deployment-starter/.github/workflows/ci-deploy.yml@refs/heads/main',
          'eswrops/rust-api-deployment-starter/.github/workflows/backup-freshness.yml@refs/heads/main',
          'eswrops/rust-api-deployment-starter/.github/workflows/gcp-auth-smoke.yml@refs/heads/main'
        ]
   ```
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

- `workflow_ref` names a *file* in the repo: editing an allowlisted
  workflow file is still a merge to `main` — the allowlist narrows the
  surface from "any workflow" to "reviewed files", it does not remove the
  need for main-branch review discipline.
- A future reusable-workflow caller would carry the caller's own
  `workflow_ref`; the allowlist fails closed for it unless the caller file
  is deliberately added after review.
- The `production` environment on the deploy job (branch/tag protection,
  optional required reviewers) is a complementary GitHub-side gate and
  orthogonal to this change; tightening it is cheap and independent.

## Cutover checklist (when approved)

- [ ] Merge-mapping + condition change scripted as an `--apply`-gated
      addition to `ops/gce-harden-github-oidc.sh` (dry run prints rollback).
- [ ] Re-run the `claims` job on `main` and confirm the `workflow_ref`
      values in the condition match the live token (drift guard).
- [ ] Run the four verification dispatches above.
- [ ] One real deployment exercised end-to-end before removing the old
      condition from the runbook.
