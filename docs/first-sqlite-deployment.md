# First SQLite production deployment — runbook and record

This document is the executed procedure for taking the production VM
(`rust-api-prod`, zone `us-west1-b`, project `rust-product-foundry-4bd846`)
from the health-check-only binary to the SQLite-enabled release without
interrupting service. The deployment gate keeps this controlled: CI builds and
verifies the release artifact on every qualifying push to `main`, but the
`deploy` job runs only while the repository variable
`PRODUCTION_DEPLOY_ENABLED` is exactly `true`.

## Why a gated first deployment

The SQLite-enabled binary changes `/health/ready` semantics: it returns 503
until `/var/lib/rust-api/app.db` exists and is migrated. The activation script
(`rust-api-activate`) rolls a release back automatically when readiness fails,
so an unprepared deploy would fail safe — but it would also thrash the service
with restart/rollback cycles. The first-deployment script instead prepares the
database **before** any activation, with the running service untouched.

## The gate

- `deploy` job condition: `vars.PRODUCTION_DEPLOY_ENABLED == 'true'`.
- Absent or any other value → deploy skipped; verify, benchmark, security and
  the AMD64 release build still run and upload the artifact.
- Enable: `gh variable set PRODUCTION_DEPLOY_ENABLED --repo eswrops/rust-api-deployment-starter --body true`
- Disable (kill switch): `gh variable delete PRODUCTION_DEPLOY_ENABLED --repo eswrops/rust-api-deployment-starter`

## Procedure (also implemented as `ops/first-sqlite-deploy.sh`)

Run from an operator workstation with gcloud authenticated (IAP-only access;
no public IPv4, no persistent SSH material — the operator's existing metadata
SSH identity plus sudo on the VM):

```bash
# 1. Land the code; wait for the CI run with the gate off.
git push origin main
gh run watch <run-id>     # verify + benchmark + security + build must pass; deploy is skipped

# 2. Download the exact artifact produced by that run.
gh run download <run-id> --repo eswrops/rust-api-deployment-starter \
  -n rust-api-linux-amd64 -D artifacts/<run-id>
sha256sum --check artifacts/<run-id>/rust-api.sha256

# 3. Stage, prepare the database, migrate, verify — service untouched.
GIT_SHA=<commit-sha> ops/first-sqlite-deploy.sh \
  --git-sha <commit-sha> --artifact-dir artifacts/<run-id>

# 4. Enable the gate and let CI deploy through the existing OIDC/IAP path.
gh variable set PRODUCTION_DEPLOY_ENABLED --repo eswrops/rust-api-deployment-starter --body true
gh workflow run ci-deploy.yml --repo eswrops/rust-api-deployment-starter --ref main

# 5. Verify service, systemd and the public endpoint.
```

What step 3 does on the VM (all steps idempotent; every check must pass before
the script reports success):

1. Digest-verify the artifact locally and again on the VM; stage it at
   `/home/deploy/incoming/rust-api-<sha>` owned by `deploy` (the location and
   ownership `rust-api-activate` requires).
2. Record the running release as the rollback anchor.
3. Install the binary to `/opt/rust-api/releases/<sha>/rust-api`
   (root-owned 0755) **without** touching the `current` symlink.
4. Create `/var/lib/rust-api` (`rustapi:rustapi`, 0750) on the persistent ext4
   boot disk (verified not tmpfs) and set
   `DATABASE_URL=sqlite:///var/lib/rust-api/app.db` in `/etc/rust-api/app.env`
   so the migration and the service use the identical value.
5. Run the embedded SQLx migrations as the `rustapi` service account
   (`sudo -u rustapi env DATABASE_URL=… <staged binary> migrate`), twice — the
   second run must report `0 pending` (idempotency proof).
6. Probe `/health/ready` of the staged binary as `rustapi` against the real
   database on a scratch port (18080) — a true readiness rehearsal that never
   restarts the systemd service.
7. Verify the rollback path: `rust-api-activate` present, the
   `rust-api-deploy` sudoers rule intact, and the current release resolvable.

## Rollback and recovery

- **Binary rollback** (service-level): the previous release directory remains
  under `/opt/rust-api/releases/`. Re-activate it with
  `sudo /usr/local/sbin/rust-api-activate <previous-sha> <previous-digest>` or
  rely on the automatic rollback that `rust-api-activate` performs when a new
  release fails its readiness probe.
- **Schema note:** binary rollback never reverts schema. Migration `0001_init`
  is purely additive (`CREATE TABLE`/`CREATE INDEX` only) and the previous
  production binary contains no SQLite code at all, so the old binary is fully
  compatible with the migrated database — rollback needs no schema undo. Any
  future destructive (contract-phase) migration must keep this property or
  ship a documented down-path; `docs/backup-recovery.md` covers
  point-in-time restore via Litestream if a schema ever has to be reverted.
- **Database recovery:** see `docs/backup-recovery.md` (Litestream replication
  + nightly `sqlite3 .backup` snapshots, with restore drills).
- **Deploy kill switch:** delete or unset `PRODUCTION_DEPLOY_ENABLED`; CI
  keeps building and verifying but deploys nothing.

## Execution record

Deployment executed 2026-10-27:

| Step | Result |
|---|---|
| Push of release commit | <filled after execution> |
| CI run (gate off): verify / benchmark / security / build | <filled after execution> |
| Artifact digest (CI `rust-api.sha256`) | <filled after execution> |
| `first-sqlite-deploy.sh`: staging, directory, permissions | <filled after execution> |
| `rust-api migrate` (first / idempotency run) | <filled after execution> |
| Staged `/health/ready` probe as rustapi | <filled after execution> |
| Rollback-path verification | <filled after execution> |
| Gate enabled; CI deploy run (build + deploy) | <filled after execution> |
| Post-deploy: `/health/live`, `/health/ready`, systemd, public HTTPS | <filled after execution> |
| Deployed commit SHA | <filled after execution> |
