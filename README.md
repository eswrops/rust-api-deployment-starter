# Rust API starter: minimal-cost VPS with reproducible GitHub CI deployments

**Baseline:** Rust 1.99.1, Axum 0.8, Ubuntu 24.04 AMD64, one public VPS, native binary, systemd, Caddy, GitHub Actions. This is a deployment starter, not a finished authenticated product. The provided readiness endpoint is a stub until you add database and upstream health checks.

## 1. Local development

Install rustup using the official instructions (https://rustup.rs). From this directory:

```bash
cargo generate-lockfile
cargo fmt --all
cargo clippy --all-targets -- -D warnings
cargo test
cargo run
curl -fsS http://127.0.0.1:8080/health/live
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

Commit and push to `main`. The workflow checks formatting, Clippy and tests, builds the AMD64 release on Ubuntu 24.04, saves a short-lived artifact, uploads it to a restricted `/home/deploy/incoming` directory, and calls a root-owned activation script that checks the digest, updates the symlink and restarts the service. It tries the readiness endpoint and restores the previous symlink if the new process fails health checks.

The workflow uses version tags for third-party actions for readability. In a hardened environment, replace tags with **reviewed immutable full commit SHAs**, periodically updating them. Limit who can edit deployment workflows, and prefer environment approvals.

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

## 7. SQLite application integration (next stage)

The sample deliberately does **not** pretend to include a finished database. When adding SQLx SQLite:

1. Create `sqlite:///var/lib/rust-api/app.db` on **local persistent disk**, not NFS or a temporary container directory.
2. Establish the writer first, set `PRAGMA journal_mode=WAL`, `synchronous=FULL` for important data, `foreign_keys=ON`, and a measured `busy_timeout`.
3. Use **one writer connection** and a separate, small read pool (initially 2–4 connections).
4. Keep transactions short. Bound the concurrent work queue with semaphores/channels; do not create unbounded `tokio::spawn` tasks per incoming job.
5. Put explicit, version-controlled forward SQL migrations under `migrations/`. Test them against a restored staging copy.
6. Before a schema-changing deployment: verify backup, run a dedicated migration action, then activate the binary. Prefer expand/contract migrations. Binary rollback does not automatically roll back the schema.
7. Replace the stub `/health/ready` with an actual lightweight DB health query and return 503 when dependencies cannot serve traffic.
8. Add Litestream v0.5.x replication using `config/litestream.yml.example` as a starting point. Configure private object storage credentials, alerts, and periodic **restore tests**. A local volume or VPS snapshot alone is not a complete off-site backup.

See: https://www.sqlite.org/wal.html , https://litestream.io/reference/config/

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
