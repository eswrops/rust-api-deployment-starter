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

Deployment executed 2026-10-27 (UTC timestamps from the systems involved):

| Step | Result |
|---|---|
| Release commit pushed | `0f7c3956372e43888d9634b703def81993388fa5` (run `40380998124`, 2026-10-26T18:48Z) |
| CI run with gate off | **success** — changes / verify / benchmark (upstream 42 checks) / security / build green; `deploy` **skipped** by gate |
| Artifact digest (CI `rust-api.sha256`) | `f3321bb1e67a5c03ac9da5a2ce36bc0fddaf555dbef2f0cb9efebdb104f32ee1` (6,294,704 bytes), verified locally and on the VM after staging |
| `first-sqlite-deploy.sh` staging/permissions | staged as `deploy:deploy 644 /home/deploy/incoming/rust-api-0f7c3956…`; installed to `/opt/rust-api/releases/0f7c3956…/rust-api` `root:root 755`; `current` symlink untouched throughout |
| Database directory | `/var/lib/rust-api` on `ext4` (persistent boot disk, not tmpfs), `rustapi:rustapi 750`; `DATABASE_URL=sqlite:///var/lib/rust-api/app.db` set in `/etc/rust-api/app.env` (`root:root 600`) |
| `rust-api migrate` as rustapi | first run `applied 1 pending migration(s)`; rerun `applied 0 pending migration(s)` (idempotency proven); `app.db` `rustapi:rustapi 644` |
| Staged `/health/ready` rehearsal | `200 {"status":"ok","version":"0f7c3956…"}` as the `rustapi` user on scratch port 18080; systemd service not touched |
| Rollback-path verification | `rust-api-activate` present (`root:root 755`), sudoers rule `deploy ALL=(root) NOPASSWD: /usr/local/sbin/rust-api-activate` intact, previous release `d23868aa…` (digest `6a92d944…`) preserved |
| Gate enabled; CI deploy | `PRODUCTION_DEPLOY_ENABLED=true`; dispatch run `40382625356` — all six jobs **success** including `deploy` (2026-10-26T19:01Z); activation log: `deployed 0f7c3956372e43888d9634b703def81993388fa5` |
| Post-deploy: systemd | `rust-api` active/running (PID restarted 19:01:44 UTC), clean journal start with `database=sqlite:///var/lib/rust-api/app.db` |
| Post-deploy: local health | `/health/live` and `/health/ready` → `200 {"status":"ok","version":"0f7c3956…"}` |
| Post-deploy: public HTTPS | `https://api-bench.thetechs.top/health/live` and `/health/ready` → `200` with the new version, verified from the VM and from an external network |
| Repeatability deploy | Runbook commit `4b9d4431…` (workflow/doc changes only) went through the full pipeline (run `40383772065`, all six jobs success) and activated cleanly — the deploy path is repeatable, and all three release directories are retained for rollback |
| Final deployed commit SHA | `4b9d4431298cfe9b642bd31dff9bf82b60e706f4` (production code identical to `0f7c3956372e43888d9634b703def81993388fa5`; only the runbook and CI path filter changed) |

Notes from the run:

- The CI-built artifact from the verification run and the artifact built by the
  deploy run are **byte-identical** (same digest `f3321bb1…`): the pinned
  toolchain and lockfile make the release build reproducible, so the binary
  that rehearsed the migration is the binary that is running.
- The operator sudoers rule on the VM is `ALL=(root)`, so the script invokes
  migrations through `sudo runuser -u rustapi --` rather than
  `sudo -u rustapi` (which would need an interactive password).
- `/home/deploy/incoming` is 0700 `deploy`-owned, so the script uploads to the
  operator home and `sudo install`s the artifact into place with the exact
  ownership `rust-api-activate` requires.
