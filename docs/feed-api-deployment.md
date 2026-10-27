# Feed API deployment (api-bench.thetechs.top)

The SPEC.md feed API (`benchmark/feed-api`) runs on the production VM as a
**second service** beside the production `rust-api`, and the Caddy site
routes the spec endpoints to it. Deployed 2026-10-27, authorized by the
operator.

| Piece | Where |
|---|---|
| Binary | `/opt/feed-api/releases/<git-sha>/feed-api`, symlink `current` (built by the `feed-api-build` workflow on ubuntu-24.04; sqlx bundles SQLite, so there are no extra runtime libraries) |
| Service | `feed-api.service` (systemd, `User=rustapi`, `StateDirectory=feed-api`, `127.0.0.1:8081`, hardened like `rust-api.service` plus `MemoryHigh=256M`) |
| Database | `/var/lib/feed-api/feed.db` — a copy of the upstream `seed/feed.db` (50k users / 500k posts / 2.016M likes, `integrity_check ok`), relayed through `gs://rust-api-prod-backups-…/imports/` and deleted from the bucket afterwards |
| Environment | `/etc/feed-api/env` (`root:rustapi 0640`): `HOST=127.0.0.1`, `PORT=8081`, `SQLITE_PATH`, `JWT_SECRET=twelve-dollar-challenge` (the challenge's public, spec-mandated secret — not a production secret), `RUST_LOG` |
| Routing | `config/Caddyfile`: `handle /health`, `/feed*`, `/posts*` → 8081; default → 8080. `/health/live` and `/health/ready` keep hitting rust-api |
| Installer | `ops/install-feed-api.sh` (operator, IAP): binary via CI artifact, seed via bucket relay, unit, Caddy validate+reload, end-to-end checks. Idempotent; re-run to upgrade the binary |

## Why a second service

The production deploy pipeline (release build → artifact →
`rust-api-activate` with its `/health/ready` readiness gate) is built around
the root crate. Replacing that service would break the activation contract
and couple the benchmark to production releases; routing the spec paths to a
separate service keeps the two isolated (mission constraint) while the
public site serves the spec API.

## Operational notes

- `rust-api` deploys are unaffected: `PRODUCTION_DEPLOY_ENABLED` still gates
  them, and activation readiness still uses `/health/ready` on 8080.
- `feed-api` is NOT deployed by CI: upgrades are a deliberate operator step
  (`feed-api-build` workflow → `ops/install-feed-api.sh --run-id …`).
- The Caddyfile on the VM is managed by the installer (CI never edits VM
  config). A backup of the previous file is written next to it on each
  install.
- The feed database is the seeded challenge dataset, not production data;
  writes via `POST /posts` / `POST /posts/:id/like` (Bearer JWT) are
  expected and land only in `/var/lib/feed-api/feed.db`.
- Verification: `bash <upstream-checkout>/test/test.sh https://api-bench.thetechs.top`
  runs the full 42-check spec suite against the live site.
