# Production deployment ordering — guarantees, tests, and the residual race

Status: verified against the test suites shipped in PR #9. This document
states exactly what the deployment pipeline guarantees, where each guarantee
is tested, and the one ordering race that remains.

## The ordering gate chain

A production activation on the VM must pass all of the following, in order:

1. **Workflow-level release gate** (`ci-deploy.yml`): release build and
   deploy jobs are reachable only from a push to `main` whose diff touches
   production inputs, or from an explicit dispatch with
   `deploy_production=true`; the repository variable
   `PRODUCTION_DEPLOY_ENABLED` must be exactly `true`.
2. **Deploy-job concurrency group** `rust-api-production`
   (`cancel-in-progress: false`): two deployments queue; they never run
   concurrently. Push runs themselves are per-SHA and never cancelled.
3. **Pre-authentication tip check** (`deploy` job, `tip` step, tested by
   `.github/scripts/test-deploy-still-current.sh`): a run whose SHA is no
   longer the tip of `main` skips before downloading the artifact or
   authenticating to Google Cloud. An unverifiable tip fails the job (fail
   closed).
4. **Final pre-activation tip check** (inside the upload/activate step,
   same script): re-verified seconds before activation, after the SSH
   connection is established. A run overtaken mid-flight fails loudly
   instead of regressing production.
5. **VM-side activation lock** (`ops/rust-api-activate`): a concurrent
   activation is REFUSED (`flock`), not queued — a losing deployment must
   fail loudly, not stack silently.
6. **VM-side identity + health verification**: the digest of the uploaded
   artifact is verified on the VM, and the restarted process must report
   the new build SHA on `/health/live` (stale-binary detection) plus
   `/health/ready` before the activation is declared successful; otherwise
   the previous release is restored and its readiness verified.

## Regression coverage

| Ordering scenario | Test |
|---|---|
| A current deployment (run SHA is the tip) | `.github/scripts/test-deploy-still-current.sh` case 1 |
| Older run superseded before artifact upload | same suite, case 2 (decision) — the workflow wiring then skips download/auth/upload/activate (`if: steps.tip.outputs.is_tip == 'true'`) |
| Main advancing during deployment preparation | same suite, case 3 (the final re-check catches it) |
| Two activation attempts at the same time | `ops/test/test-rust-api-activate.sh` case 8 (second run refused, exit 4) |
| Failed atomic replacement | same suite, case 11 (previous release stays active, nothing restarted, exit 1) |
| Failed new-release readiness | same suite, case 5 (automatic rollback, rollback itself verified) |
| Failed rollback readiness | same suite, case 6 (loud "manual intervention required", non-zero exit) |
| Manual rollback to an older retained release | same suite, case 9; `ops/test/test-backfill-release-digests.sh` case 7 proves an old-generation release becomes rollback-capable after digest backfill |

Change detection (what qualifies for a release at all) is covered separately
by `.github/scripts/test-deploy-changes.sh` (19 scenarios).

## Residual race (documented, not yet closed)

**The final tip check runs on the runner, but activation runs on the VM.**
Between the last `git ls-remote` (step 4) and the completion of
`sudo rust-api-activate` on the VM, a new push can land on `main`. In that
window this run still activates its (now older) SHA. The VM-side script
serializes activations but does not — and cannot, with its current
sudoers signature `<sha> <digest>` — validate anything about GitHub state.

Properties of that window:

- It is seconds wide (scp of the binary + activation), and only opens after
  two independent tip checks have passed.
- It self-heals: the newer commit's own push run will build and deploy on
  top of it. Production lands on the newer SHA as soon as that run
  succeeds.
- It can regress production only if the newer run fails to build or deploy,
  leaving production on the older SHA until a successful deploy follows.
  That failure would be loudly visible in Actions.

**Therefore: the deployment process is NOT claimed to be race-free.** The
final activation decision is serialized (concurrency group + activation
lock) and validated against main's tip twice, but the tip validation and
the activation are not one atomic step.

Closing it would require the runner to pass the expected tip (or run ID)
to `rust-api-activate` and the VM script to re-verify it against GitHub —
a sudoers signature change, a new VM-side network dependency (or a signed
claim), and a coordinated rollout of both sides. That is deliberately out
of scope for PR #9; the two-check + serialization design above bounds the
risk to the narrow window described here.
