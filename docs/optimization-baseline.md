# Optimization baseline (2026-10-27)

Recorded before any optimization changes, at `main` = `d2bf475` ("Harden feed
API: JWT NumericDate, SQLite commit-fault injection, connection pressure, CI").
Deployment gate `PRODUCTION_DEPLOY_ENABLED` verified **`false`** at audit time
(`gh variable get`), so no run can reach production; all numbers below were
taken read-only.

## 1. Configuration snapshot

### Workflow (`.github/workflows/ci-deploy.yml`)

- Single workflow: `changes` → `verify` / `benchmark` / `security` → `build`
  → `deploy`. Triggers: push to `main`, all pull requests,
  `workflow_dispatch` with an `idle_connections` input (default 3000; the
  same dispatch can also build and deploy).
- Workflow-scope permissions: `contents: read`, **`id-token: write`** — every
  job, including pull-request runs of verify/benchmark/security, receives an
  OIDC-capable token context.
- Third-party actions pinned to full SHAs (checkout v4, rust-cache v2,
  upload/download-artifact v4, google-github-actions auth/setup-gcloud v2,
  cargo-deny-action v2).
- Change detection: `git diff --name-only HEAD^ HEAD` for push events (misses
  files changed in earlier commits of a multi-commit push), `…base...HEAD`
  for PRs; first push commit on a branch deploys. Operator tooling
  (`ops/first-sqlite-deploy.sh`, `ops/install-backups.sh`, `ops/backup/`) is
  excluded from the deploy path filter.
- Deploy job: `environment: production`, concurrency group
  `rust-api-production` (not cancel-in-progress), gated on
  `vars.PRODUCTION_DEPLOY_ENABLED == 'true'`. Auth via WIF (`auth` + `setup-gcloud`), artifact
  sha256 re-checked, ephemeral ed25519 key pushed into instance metadata
  (10-minute expiry), IAP tunnel to 127.0.0.1:2222, then
  `sudo /usr/local/sbin/rust-api-activate <sha> <digest>` over SSH.
- SSH options: `StrictHostKeyChecking=accept-new` with a run-local
  `UserKnownHostsFile` — trust-on-first-use, no pinned host key.
- Known sharp edge in the deploy job: the instance-metadata key update does
  `gcloud … describe | jq | grep -v '^deploy:' >"$ssh_keys" || true`. If the
  `describe` step fails, the error is swallowed and a truncated/empty key
  list is written back with `add-metadata`, which would **replace the
  instance's ssh-keys metadata (wiping operator keys)**. Also every
  `setMetadata` is instance-wide.

### Toolchain / crates

- `rust-toolchain.toml`: channel 1.99.1, minimal profile, rustfmt+clippy.
- Root crate `rust-api`: axum 0.8, sqlx 0.8 (`runtime-tokio, sqlite, migrate,
  macros`, default-features off), tokio multi-thread 1 worker. Release
  profile: opt-level 3, thin LTO, codegen-units 4, strip debuginfo.
- `src/db.rs`: WAL, `synchronous=FULL`, foreign_keys on, busy_timeout 5 s,
  reader pool of 2 (warm min=max), single-connection writer pool, lazy
  connect so `/health/live` never depends on the database. Readiness =
  `SELECT 1`. Migrations only via the explicit `rust-api migrate` command.
- `src/main.rs`: `/health/live`, `/health/ready` (503 with `error` string on
  failure), 15 s timeout layer, 1 MiB body limit, graceful SIGTERM/SIGINT.

### Service / proxy

- `config/rust-api.service` (already hardened): `User=rustapi`,
  `StateDirectory=rust-api` (0750), `MemoryMax=768M`, `LimitNOFILE=65535`,
  `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`, `ProtectHome`,
  kernel tunables/modules/control-groups protection, `LockPersonality`,
  `RestrictSUIDSGID`, `SystemCallArchitectures=native`,
  `ReadWritePaths=/var/lib/rust-api`, `Restart=on-failure` (RestartSec 2),
  `TimeoutStopSec=35`. Not present: `UMask`, `MemoryHigh`, `TasksMax`,
  `RestrictAddressFamilies`, restart-rate limiting.
- `config/Caddyfile`: single site `api-bench.thetechs.top`, zstd/gzip encode,
  `reverse_proxy 127.0.0.1:8080`. No request limits, no upstream timeouts, no
  access-log config.

### Activation (`ops/rust-api-activate`, root, sudoers-scoped)

SHA + digest validation (regex + sha256 re-sum), upload ownership check,
release install to `/opt/rust-api/releases/<sha>`, atomic symlink swap
(`ln -sfn` + `mv -Tf`), `systemctl restart`, 20×1 s readiness polling, auto
rollback to previous release on restart/readiness failure. Not present:
activation lock, verification that the *running* process serves the new
release, rollback readiness verification, bounded startup vs. restart
distinction, incomplete-release cleanup, release retention (releases
accumulate indefinitely).

### GitHub OIDC / IAM (read-only inspection 2026-10-27)

- WIF pool `github-actions-pool`, provider `github-actions-provider`
  (ACTIVE). Mapping: `google.subject=assertion.sub`,
  `attribute.repository=assertion.repository`, `attribute.ref=assertion.ref`.
  **Condition: `assertion.repository=='eswrops/rust-api-deployment-starter'`
  only — no ref/branch restriction**, and it matches by repository *name*,
  not the immutable repository ID.
- Deployer SA `github-rust-api-deployer@…`: keyless (only the
  SYSTEM_MANAGED key; no user-managed JSON keys).
  - SA-level: `roles/iam.workloadIdentityUser` bound to
    `principalSet://…/attribute.repository/eswrops/rust-api-deployment-starter`
    (any ref of the repo can impersonate it).
  - Project-level: custom `rustApiDeploymentProjectAccess`
    (`compute.projects.get`, `compute.globalOperations.get`,
    `compute.zoneOperations.get`), custom `rustApiIapInstanceReader`
    (`compute.instances.get/list`), `roles/iap.tunnelResourceAccessor`.
  - Instance-level: custom `rustApiInstanceDeployer`
    (`compute.instances.get/list/setMetadata`).
- Effective privileges used by a deploy: WIF token exchange →
  `compute.instances.get` + `setMetadata` (ephemeral SSH key push) →
  `iap.tunnelResourceAccessor` (tunnel) → SSH → sudoers-gated
  `rust-api-activate`. The `setMetadata` grant is the widest surface (it can
  rewrite instance metadata, including ssh-keys, for this instance only).

### Backup / recovery (implemented state, `docs/backup-recovery.md`)

- `rust-api-backup.timer` daily 04:15 UTC (+ jitter, `Persistent=true`),
  `rust-api-restore-drill.timer` Sundays 05:15 UTC,
  `rust-api-backup-alert@.service` on failure (local `ALERT` marker +
  off-site `alerts/` object). Heartbeat object `heartbeat.txt` refreshed
  after each successful backup+upload; dead-man switch = stale heartbeat.
- GCS access from the VM: SA `rust-api-backup@…` with bucket-scoped
  `roles/storage.objectUser`, JSON key at `/etc/rust-api/backup-gcs-key.json`
  (root:rustapi 0640), raw JSON-API calls via curl+openssl JWT.
- Bucket `gs://rust-api-prod-backups-650296500144`: private, PAP enforced,
  UBLA, versioning, 7-day soft delete. Off-site retention: live snapshots
  >30 days expired, superseded noncurrent versions purged after 7 days.
- **Correctness gaps found (drive PR 1):**
  1. `gcs_list` requests `maxResults=1000` and never follows
     `nextPageToken` — at >1000 objects the listing silently truncates and
     retention/drill "newest snapshot" logic operate on a subset.
  2. Retention errors are suppressed: `gcs_list … || true` (a failed list
     yields an empty stream → retention reports success with 0 processed)
     and `gcs_delete … || true` followed by an unconditional "purged" echo —
     a failed delete is reported as deleted.
  3. No minimum-snapshot preservation: once every live snapshot is older
     than the cutoff, the retention loop will expire all of them.
  4. No external freshness monitoring: heartbeat staleness is only visible
     if a human or VM-side process looks; nothing external alarms when the
     VM (and its own alerting) is gone.

## 2. CI measurements

GitHub Actions, run `40406453917` (push to main `d2bf475`, 2026-10-26
21:41 UTC, all caches warm — it was the ~8th run of the day):

| Job | Duration | Notes |
|---|---|---|
| changes | 4 s | checkout with fetch-depth 0 (~3 s) |
| verify | 33 s | rustup 9 s, cache restore 12 s, fmt+clippy 2 s, tests 4 s |
| security | 52 s | cargo-deny ×2 |
| benchmark | 95 s | seed build 21 s, upstream 42 checks 24 s, fault injection 24 s, pressure 1 s, idle 2 s |
| build | 33 s | release build 13 s (cache hit), package+upload 3 s |
| deploy | skipped | gate `PRODUCTION_DEPLOY_ENABLED=false` |

Cold-ish reference (run `40380998124`, 2026-10-26 18:48 UTC, partially warm
— same-day): benchmark 192 s, build 86 s, verify 83 s, security 50 s.
End-to-end wall clock: ~2 m 11 s warm, ~5–6 m cold (earlier runs with cold
toolchain install, e.g. `40352935114`).

Cache behavior: `Swatinem/rust-cache` v2, default key (no per-crate split);
production and benchmark crates share the job-local default configuration —
benchmark uses `workspaces: benchmark/feed-api`, verify/build use the root
crate. Cache hits on all jobs in the latest run (hit rate 100% for the day's
repeat pushes).

Artifact: `rust-api-linux-amd64` = 2,598,843 bytes (binary + sha256),
retention 7 days.

Time-to-readiness (deploy): not measurable this cycle (deploy skipped by
gate); last recorded successful deploy path is `4561e04` (2026-10-26,
"Record final deployed SHA and repeatability deploy").

Failure history (2026-10-26): 6 failed / 2 cancelled runs out of 15 — all in
the deploy-transport bring-up loop (IAP tunnel, SSH metadata), none in
verify/benchmark/security.

## 3. VM measurements (read-only over IAP, 2026-10-27 22:07 UTC)

VM `rust-api-prod`: RUNNING, e2-micro (2 vCPU shared-core, 1 GB), Ubuntu
24.04, 30 GB boot disk (2.8 GB used, 26 GB free), uptime 6.5 h, no attached
service account.

| Probe | Value |
|---|---|
| rust-api systemd | active/running, PID 12583, 0 restarts since 2026-10-26 20:38 UTC |
| rust-api MemoryCurrent / MemoryPeak | 1.0 MiB / 1.5 MiB (cgroup; anon working set) |
| rust-api RSS (ps) | 7.2 MiB |
| Caddy MemoryCurrent / RSS | 34 MiB / 25.9 MiB |
| Top other residents | multipathd 27 MiB, snapd 27 MiB |
| CPU | 0.36% non-idle since boot; load average 0.00 |
| SQLite | app.db 45,056 B; app.db-wal 0 B; app.db-shm 32,768 B |
| Backup timers | next fire Tue 04:19 UTC (daily), Sun 05:19 UTC (drill) |
| Last successful backup | 2026-10-26T20:34:56Z (`last-backup-success`) |
| Last successful drill | 2026-10-26T20:32:21Z, PASS |
| ALERT marker / failed units | none / none |

Off-site bucket (checked from workstation): 10 objects, 221 KiB total
(5 setup-day snapshots, 2 drill reports, 2 alert objects from the tested
failure path, 1 heartbeat — content verified to match the newest snapshot
sha256). Heartbeat age at check time ~5.5 h, consistent with the daily
schedule.

Load tests were not run against the VM (constraint).

## 4. Findings → PR map

| # | Finding | Severity | PR |
|---|---|---|---|
| 1 | Workflow-scope `id-token: write`: PR runs hold OIDC capability | P0 | 1 |
| 2 | WIF condition: no ref restriction, name-based match | P0 | 1 (prepared, needs operator approval to apply) |
| 3 | SSH `accept-new` TOFU, no pinned host key | P0 | 1 |
| 4 | `gcs_list` no pagination | P0 | 1 |
| 5 | Retention swallows list/delete failures, reports failed deletes as deleted | P0 | 1 |
| 6 | Retention can expire the last live snapshot | P0 | 1 |
| 7 | No external backup-freshness monitoring | P1 | 1 (prepared, gated) |
| 8 | Deploy job can wipe instance ssh-keys on failed `describe` (`\|\| true`) | P1 | 3 |
| 9 | `HEAD^` change detection misses multi-commit pushes | P1 | 2 |
| 10 | Capacity benchmark dispatch shares the deploy workflow/credentials | P1 | 2 |
| 11 | Duplicate `cargo test --locked --test migrations` | P2 | 2 |
| 12 | No stale-release protection in deploy ordering; activation lacks locking/running-release verification | P1 | 3 |
| 13 | Releases retained indefinitely on VM | P2 | 3 |
| 14 | No Linux-artifact smoke test before upload | P1 | 3 |
| 15 | systemd: no `UMask`/`MemoryHigh`/`TasksMax`/restart limits | P2 | 4 |
| 16 | Readiness = `SELECT 1` only; error string in public 503 body | P2 | 4 |
| 17 | Caddy: no request limits/timeouts/access-log config; origin open on 80/443 | P2 | 4 (proposal; firewall needs approval) |
| 18 | Static JSON key for backups (keyless migration = VM stop/start) | P2 | separate approved maintenance |

## 5. Constraints re-verified at audit time

- `PRODUCTION_DEPLOY_ENABLED=false` (repo variable, `gh variable get`).
- Unrelated in-progress work present in the working tree (`oci/*.sh` A1/E2.1
  fallback rewrite, `ops/gce-*.sh` edits) — preserved untouched; this PR
  work is branched and committed without including those files.
- No production-affecting IAM/firewall/DNS/VM-lifecycle change was executed
  during this audit; all `gcloud`/`gh` access was read-only.
