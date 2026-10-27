# PR plan: isolate the public feed-api process (next security PR)

Status: **PLAN ONLY — PR #9 does not change the running feed API.** This is
the prepared scope for the follow-up PR so it can be reviewed independently
of the deployment-safety work.

## Problem

`feed-api.service` (the public challenge API on 127.0.0.1:8081, proxied as
the site default) currently runs as the same Unix identity as the private
production API: `User=rustapi` / `Group=rustapi`. The public process
therefore can read everything `rustapi` can, including:

- `/var/lib/rust-api/app.db` — the production SQLite database;
- `/etc/rust-api/app.env`, `/etc/rust-api/backup.env` — credentials;
- `/etc/rust-api/backup-gcs-key.json` — the off-site backup key;
- `/var/lib/rust-api/backups/` — every production snapshot;
- `/opt/rust-api/current/rust-api` and its deployment metadata.

The challenge's JWT secret is public SPEC material, so anyone can construct
authorized-looking requests; the process must be treated as fully
untrusted. A feed-api compromise must not reach production data.

## Scope of the PR

1. **Dedicated identity.** `feedapi` system user + `feedapi` group
   (`useradd --system --no-create-home --shell /usr/sbin/nologin feedapi`),
   created by `ops/install-feed-api.sh` (idempotent). `config/feed-api.service`
   becomes `User=feedapi`, `Group=feedapi`, keeping
   `StateDirectory=feed-api` + `StateDirectoryMode=0750` (systemd provisions
   `/var/lib/feed-api` owned by feedapi:feedapi automatically).
2. **Filesystem permissions.** Only these readable/writable by `feedapi`:
   `/opt/feed-api/current` (traverse + execute), `/opt/feed-api/releases/`
   (traverse), `/var/lib/feed-api/` (rwx, incl. WAL/SHM creation),
   `/etc/feed-api/env` (read; `root:feedapi` 0640). The production API's
   files stay `rustapi`-owned with group/world bits off, so no ACL changes
   to rust-api paths are needed — isolation by default, not by denial.
   `feedapi` is never added to the `rustapi` group.
3. **No sudo.** The `feedapi` account gets no sudoers entry (verify
   `sudo -l -U feedapi` shows nothing); installers/activation remain
   root/operator + `deploy`-via-sudo only.
4. **systemd review.** The unit already sets `NoNewPrivileges`,
   `PrivateTmp`, `ProtectSystem=strict`, `ProtectHome`,
   `ProtectKernelTunables/KernelModules/ControlGroups`, `LockPersonality`,
   `RestrictSUIDSGID`, `SystemCallArchitectures=native`,
   `ReadWritePaths=/var/lib/feed-api`. Retain all; evaluate adding
   `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`, `ProtectProc=invisible`,
   `UMask=0077`, `TasksMax=` — each tested (SQLite writes, restart, logging,
   DNS, localhost HTTP) before kept, nothing added blindly.
5. **Resource limits for the e2-micro** (1 GiB RAM total). Current combined
   ceilings (rust-api 768M + feed-api 512M + caddy unbounded) exceed
   physical memory. Choose from measured RSS: keep `MemoryHigh=256M`, set
   `MemoryMax` so rust-api + feed-api + caddy + backup jobs + OS fit with
   headroom (target combined ceilings < ~900M); confirm the OOM kill order
   protects rust-api and backup timers.
6. **Independent deployment/rollback.** feed-api keeps its own release
   layout and installer; a feed-only deploy must never restart rust-api
   (asserted in the verification runbook). Bringing feed activation to the
   same atomic/lock/health-verified standard as `ops/rust-api-activate` is
   a separate later PR (provenance-correct installer first — M4.1/M4.2 of
   the master plan) and is NOT in this PR.
7. **Regression gate.** The full upstream 42-check suite against a
   disposable feed database (never the live one), plus the negative
   permission tests below, plus both services healthy after rollout.

## Negative permission tests (must FAIL to pass)

```
sudo runuser -u feedapi -- test -r /etc/rust-api/backup-gcs-key.json      # fail
sudo runuser -u feedapi -- test -r /etc/rust-api/app.env                  # fail
sudo runuser -u feedapi -- test -r /etc/rust-api/backup.env               # fail
sudo runuser -u feedapi -- test -w /var/lib/rust-api/app.db               # fail
sudo runuser -u feedapi -- test -r /var/lib/rust-api/backups/<latest>.db  # fail
sudo runuser -u feedapi -- test -x /opt/rust-api/current/rust-api         # execute may pass
sudo runuser -u feedapi -- test -r /var/lib/feed-api/feed.db              # must SUCCEED
sudo -l -U feedapi                                                        # no commands
```

## Ownership handover (controlled maintenance)

The live `/var/lib/feed-api/feed.db` (+ `-wal`, `-shm`) and
`seed-pristine.db` are currently `rustapi`-owned. Rename of identity
requires a **controlled stop → chown → start → verify** procedure (never a
live chown while SQLite is writing): stop feed-api, chown db/wal/shm/seed to
`feedapi:feedapi` 0640/0600, fix parent traversal (0750), start, verify
writes + WAL creation, verify 42 checks. Operator-approved window; the PR
ships the procedure and the unit/installer changes, the VM handover is a
separately approved rollout.

## Explicit non-goals

- No change to Caddy routing, the benchmark crate, or rust-api's identity.
- No keyless/attached-VM backup identity work here: the metadata-server
  shared-host risk (any local user can mint attached-SA tokens by default)
  is evaluated separately (M5.5) — this PR must not regress it further, and
  `feedapi` gains nothing new by existing (it still can reach the metadata
  server; that gap is closed by egress/workload isolation work, not by the
  rename).
- No live database reset; the pristine-seed reset flow stays operator-only.

## Verification checklist (disposable Linux environment first)

- [ ] feed-api runs as feedapi; rust-api still runs as rustapi.
- [ ] All negative tests above fail; positive feed-api paths succeed.
- [ ] Production backups still complete (timer fires, snapshot uploads).
- [ ] All five challenge endpoints work; JSON 404 behavior unchanged.
- [ ] Upstream 42/42 checks pass against a disposable database.
- [ ] Memory ceilings documented against measured RSS; no OOM during the
      42-check run and the idle-capacity probe at conservative settings.
