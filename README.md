# Rust API starter: minimal-cost VPS with reproducible GitHub CI deployments

**Baseline:** Rust 1.99.1, Axum 0.8, SQLite (SQLx), Ubuntu 24.04 AMD64, one public VPS, native binary, systemd, Caddy, GitHub Actions. The production service integrates SQLite (`src/db.rs`: one writer connection + a two-connection reader pool, WAL, `synchronous=FULL`) with versioned SQL migrations in `migrations/` and a real database-backed `/health/ready`. The $12-server-challenge feed API lives as an independent crate in [`benchmark/feed-api/`](benchmark/feed-api/README.md); it is not deployed to production.

## Google Cloud Always Free (`gcloud`)

This repository includes a deliberately small Google Compute Engine route for
`rust-product-foundry-4bd846`: one `e2-micro` in `us-west1-b`, a 30 GB standard
persistent disk, IAP-only SSH, and an external IPv6 address. It intentionally
has **no external IPv4 address**, so `api-bench.thetechs.top` is reachable only
by IPv6-capable clients. This avoids the hourly IPv4 fee, but does not make
usage unconditionally free: stay within the Google Cloud Free Tier VM and
egress limits.

Run the idempotent provisioner from this repository with an authenticated
project owner:

```bash
./ops/gce-provision.sh
```

It prints the IPv6 value for a DNS-only Cloudflare AAAA record. Publish that
record for `api-bench.thetechs.top`, wait for it to resolve, then start Caddy:

```bash
./ops/gce-enable-caddy.sh
```

GitHub Actions deploys through Google Workload Identity Federation and IAP, so
it has no deployment SSH private key or host-key secret. Configure it once with:

```bash
./ops/gce-configure-github-oidc.sh
```

The script creates the `production` environment and the required non-secret
repository variables through `gh`. A deployment generates an SSH key that
expires after ten minutes, uses it only through IAP as the restricted `deploy`
user, and then calls the existing atomic activation script.

## 1. Local development

Install rustup using the official instructions (https://rustup.rs). From this directory:

```bash
cargo generate-lockfile
cargo fmt --all
cargo clippy --all-targets -- -D warnings
cargo test
cargo run -- migrate                # create + migrate the dev database (DATABASE_URL, default sqlite:///var/lib/rust-api/app.db)
DATABASE_URL=sqlite://dev.db cargo run
curl -fsS http://127.0.0.1:8080/health/ready
```

**Commit `Cargo.lock`** before CI (`--locked` deliberately fails without it). Do not commit `.env`, databases, keys, or build artifacts. The Rust toolchain is pinned in `rust-toolchain.toml`. `APP_BIND` defaults to `127.0.0.1:8080`.

## 2. Select the VPS

Choose Ubuntu **24.04 LTS AMD64**, 1 vCPU and 2 GB RAM with local SSD, ideally in the region closest to your users. The GitHub Actions build runner in this kit is `ubuntu-24.04`; using the same OS generation avoids accidentally building against a newer glibc than the runtime has. If your VPS is ARM64 or uses an older distro, change BOTH the CI build target and runtime accordingly or produce a tested musl build.

The build and CI run on GitHub, *not* on the VPS.

## 3. Secure the VPS

As an initial administrator with sudo (keep this session open while changing SSH/firewall):

```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y caddy curl ca-certificates ufw
sudo adduser --disabled-password --gecos '' deploy
sudo useradd --system --home /nonexistent --shell /usr/sbin/nologin rustapi
sudo install -d -m 0700 -o deploy -g deploy /home/deploy/incoming
sudo install -d -m 0755 -o root -g root /opt/rust-api/releases
sudo install -d -m 0755 -o root -g root /etc/rust-api
sudo install -m 0600 -o root -g root config/app.env.example /etc/rust-api/app.env
sudo install -m 0644 -o root -g root config/rust-api.service /etc/systemd/system/rust-api.service
sudo install -m 0755 -o root -g root ops/rust-api-activate /usr/local/sbin/rust-api-activate
printf '%s\n' 'deploy ALL=(root) NOPASSWD: /usr/local/sbin/rust-api-activate' | sudo tee /etc/sudoers.d/rust-api-deploy >/dev/null
sudo chmod 0440 /etc/sudoers.d/rust-api-deploy
sudo visudo -cf /etc/sudoers.d/rust-api-deploy
sudo systemctl daemon-reload
sudo systemctl enable rust-api   # enable boot-time startup; do not start until first release
```

The files above must first be copied to the VPS over your trusted administrator connection. Configure *only* the deploy user's SSH authorized key (do not reuse the administrator's SSH key):

```bash
sudo install -d -m 0700 -o deploy -g deploy /home/deploy/.ssh
# Copy your **deployment key's public half** into /home/deploy/.ssh/authorized_keys
sudo chown deploy:deploy /home/deploy/.ssh/authorized_keys
sudo chmod 0600 /home/deploy/.ssh/authorized_keys
```

After confirming key-based SSH works, disable root SSH login and password authentication using an `sshd_config.d` drop-in, run `sudo sshd -t`, reload SSH, and test a second session before closing the first. Apply the provider cloud firewall and local UFW rules:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp   # needed for GitHub-hosted deploy runner; tighten later with Tailscale
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

**If you use Cloudflare Tunnel instead of Caddy**, you can close 80/443, but GitHub Actions still needs a private path for deployment (e.g., Tailscale). Do not block ingress until a verified administrative access path exists.

## 4. Configure Caddy and DNS

Set your domain's DNS A/AAAA to the VPS. Edit `config/Caddyfile`, replacing `api.example.com`. Then:

```bash
sudo install -m 0644 config/Caddyfile /etc/caddy/Caddyfile
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

The application listens on localhost; only Caddy is internet-facing. Caddy requests/renews HTTPS certificates, so port 80/443 reachability and working DNS are required.

## 5. Configure GitHub Actions (the default deployment path)

Push this repository to GitHub, with `Cargo.lock` committed. Create a GitHub Environment named `production`, restrict it to `main`, and where supported require manual approval. Define these **Environment secrets**:

- `DEPLOY_HOST`: the VPS DNS name or IP address.
- `DEPLOY_SSH_KEY`: the private half of a dedicated Ed25519 **deployment** SSH key.
- `DEPLOY_KNOWN_HOSTS`: the **verified** SSH host key line(s) for your server.

Generate the deployment key locally with `ssh-keygen -t ed25519 -f ~/.ssh/rust-api-deploy -C 'rust-api CI deploy'`. Install its `.pub` content in the `deploy` user's `authorized_keys`; put its private half ONLY in the GitHub secret. Verify the host key fingerprint using the VPS console or an established trusted SSH session before adding it to `DEPLOY_KNOWN_HOSTS`. Never blindly trust a `ssh-keyscan` result without verifying its fingerprint.

Commit and push to `main`. The workflow runs five independent checks — formatting, Clippy, tests (including explicit migration validation), the benchmark contract suite (builds the upstream seed database and runs the 42-check challenge suite against `benchmark/feed-api/`), and cargo-deny for dependency advisories and licenses — then builds the AMD64 release on Ubuntu 24.04, saves a short-lived artifact, uploads it to a restricted `/home/deploy/incoming` directory, and calls a root-owned activation script that checks the digest, updates the symlink and restarts the service. It tries the readiness endpoint and restores the previous symlink if the new process fails health checks.

Release builds and deployments are triggered only by pushes that touch production-relevant paths (`src/`, `migrations/`, `config/`, `ops/`, manifests, the workflow itself); benchmark-only or documentation-only pushes skip the release build. Manual `workflow_dispatch` always builds and deploys. Third-party actions are pinned to reviewed full commit SHAs (the resolved tag is noted in a comment beside each pin); re-review the pins when you update them. Limit who can edit deployment workflows, and prefer environment approvals.

## 7b. Feed API benchmark ($12 Server Challenge)

`benchmark/feed-api/` is a standalone, independently buildable crate that implements the challenge's five-endpoint feed API (Axum + SQLx + SQLite, its own `SQLITE_PATH`/`JWT_SECRET` configuration, its own regression suite and CI job). It shares no code or configuration with the production service — the benchmark database and benchmark JWT secret never touch the live API. See [`benchmark/feed-api/README.md`](benchmark/feed-api/README.md) for the design, performance measurements and run instructions.

## 6. Inspect and troubleshoot

```bash
sudo systemctl status rust-api --no-pager
sudo journalctl -u rust-api -n 100 --no-pager
sudo systemctl status caddy --no-pager
curl -fsS http://127.0.0.1:8080/health/ready
curl -fsS https://api.example.com/health/ready
sudo readlink -f /opt/rust-api/current
sudo du -sh /opt/rust-api/releases
```

No binary is installed until the first successful deploy, so `rust-api.service` cannot start yet on initial boot. The activation script starts it on first deploy.

## 7. SQLite integration (implemented)

The production service uses SQLite as its only database:

- **Location:** `/var/lib/rust-api/app.db` (systemd `StateDirectory=rust-api`; persistent local disk, not NFS). Override with `DATABASE_URL` (`sqlite:///absolute/path`, configured in `/etc/rust-api/app.env`).
- **Pools:** exactly one write connection (all mutations serialize through it, eliminating writer/writer `SQLITE_BUSY`) plus a two-connection reader pool (`DbConfig::read_connections`). Connections are warm and created lazily, so the process boots even when the database file is broken and `/health/live` keeps answering.
- **Pragmas:** `journal_mode=WAL`, `foreign_keys=ON`, `busy_timeout=5s`, `synchronous=FULL` (a committed write survives power loss before the caller is told it succeeded).
- **Migrations:** versioned, forward-only SQL in `migrations/`, embedded into the binary at compile time. They are applied **only** by the explicit `rust-api migrate` command (run as `rustapi` on the VM) — never at server startup or per request.
- **Health:** `/health/ready` executes `SELECT 1` against the reader pool → `200 {"status":"ok",…}` or `503 {"status":"degraded","error":…}`. `/health/live` never touches the database.
- **Backup/recovery:** see [docs/backup-recovery.md](docs/backup-recovery.md) (Litestream continuous replication + nightly `.backup` snapshots, with a restore-drill procedure).

### Deploying schema changes

Keep migrations expand/contract so a binary rollback never faces an incompatible schema. The sequence for a schema-touching release:

1. Ship the new migration in `migrations/` (never edit an applied one).
2. After the artifact is on the VM (and before traffic depends on the new schema), run:
   `sudo -u rustapi env DATABASE_URL=sqlite:///var/lib/rust-api/app.db /opt/rust-api/current/rust-api migrate`
3. Activate/restart the service.

**One-time bootstrap required for the first deploy of the SQLite-enabled binary:** `/health/ready` now fails (503) while the database file does not exist, and the activation script rolls the release back to the previous binary when readiness fails — by design, so the service never serves from a broken database. The production deploy job is additionally gated on the repository variable `PRODUCTION_DEPLOY_ENABLED` (disabled by default; see [docs/first-sqlite-deployment.md](docs/first-sqlite-deployment.md)). The bootstrap procedure is:

1. Push the release commit; CI runs verify/benchmark/security/build and uploads the artifact (deploy stays gated off).
2. Download the artifact and run the idempotent `ops/first-sqlite-deploy.sh --git-sha <sha> --artifact-dir <dir>`: it stages the exact CI artifact, creates `/var/lib/rust-api` with correct ownership on persistent disk, runs the embedded migrations as `rustapi` with the production `DATABASE_URL`, proves migration idempotency, and rehearses readiness with the staged binary — all without touching the running service.
3. Enable the gate (`gh variable set PRODUCTION_DEPLOY_ENABLED --body true`) and dispatch the workflow; the deploy job activates the release through the existing OIDC/IAP path with its readiness-gated, auto-rollback activation.

This is the only production database configuration change in this iteration; it is documented here per the project constraint that production changes must be explicit.

## 8. Optional OCI deployment

`Dockerfile` is a separate portable image route for Cloud Run, Fly.io, and other container hosts. It uses a cargo-chef dependency layer and a slim Debian runtime. Test it using:

```bash
docker build -t rust-api:local .
docker run --rm -p 8080:8080 -e APP_BIND=0.0.0.0:8080 rust-api:local
```

Do not treat this example container's writable filesystem as persistent SQLite storage. On a VPS, mount a persistent local host directory; on scale-to-zero platforms, use a remote durable database instead.

## 9. Production gates that remain application-specific

This kit demonstrates the deploy lifecycle, not full product security. Add OIDC/session authentication, authorization (especially tenancy isolation), validation, CSRF protection for browser cookie flows, appropriate CORS, rate limits, request/idempotency handling, real readiness checks, structured metrics, business-level test coverage, and restore-tested backups before calling the product production-ready.

The samples are uncompiled in the ChatGPT environment (no Rust toolchain available here). CI is designed to catch compile/test errors. Review and test this deployment using a disposable VPS before pointing production DNS at it.
