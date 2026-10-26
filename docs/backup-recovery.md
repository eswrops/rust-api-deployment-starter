# SQLite backup and recovery

The production database lives at `/var/lib/rust-api/app.db` (systemd
`StateDirectory=rust-api`, WAL mode, `synchronous=FULL`). SQLite in WAL mode
is a single self-contained file plus transient `-wal`/`-shm` companions, which
shapes both backup options below.

## Two backup layers

### 1. Point-in-time replication with Litestream (continuous)

`config/litestream.yml.example` holds the replica shape. On the VM:

```bash
# install (or vendor the single static binary through the deployment flow)
curl -fsSL https://github.com/benbjohnson/litestream/releases/latest/download/litestream-v0.5.x-linux-amd64.tar.gz | tar -C /usr/local/bin -xz

sudo install -m 0640 -o litestream -g litestream config/litestream.yml.example /etc/litestream.yml
# fill in the s3://… replica URL and credentials, then:
sudo systemctl enable --now litestream
```

- Litestream tails the WAL and ships it to object storage; recovery point is
  seconds behind, cost is one small bucket + negligible API traffic at this
  database size.
- Credentials go in `/etc/litestream.yml` (root-owned, 0600) or the
  environment of its systemd unit — never in this repository.
- **Verify storage compatibility and cost before enabling**: do a restore
  drill into a scratch directory (below) and confirm the replica bucket's
  storage class/pricing with your provider. A replica you have never restored
  is not a backup.

### 2. Logical snapshots with `sqlite3 .backup` (cron, cheap belt-and-braces)

```bash
# /etc/cron.d/rust-api-backup — runs as the rustapi user, online and safe
# while the API is running (sqlite3 .backup takes a consistent snapshot).
30 4 * * * rustapi sqlite3 /var/lib/rust-api/app.db \
  ".backup '/var/lib/rust-api/backups/app-$(date +\%Y\%m\%d).db'"
```

`sudo -u rustapi sqlite3 /var/lib/rust-api/app.db "PRAGMA integrity_check;"` —
run after the first snapshot and after every restore drill.

Never copy `app.db` with `cp` while the server is running: the WAL may hold
uncheckpointed commits and the copy can be torn. Use `.backup` (or Litestream).

## Restore drill (run quarterly and after any config change)

```bash
# 1. Restore from Litestream into a scratch directory
litestream restore -o /tmp/restore-drill/app.db s3://REPLACE_WITH_BUCKET/rust-api

# 2. Verify integrity and schema
sqlite3 /tmp/restore-drill/app.db "PRAGMA integrity_check;"
sqlite3 /tmp/restore-drill/app.db "SELECT count(*) FROM _sqlx_migrations;"
sqlite3 /tmp/restore-drill/app.db "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"

# 3. Boot the actual binary against the restored copy and probe it
DATABASE_URL=sqlite:///tmp/restore-drill/app.db /opt/rust-api/current/rust-api &   # APP_BIND picks a free port
curl -fsS http://127.0.0.1:<port>/health/ready && kill %1

# 4. Record the drill date + result in the operations log
```

A drill passes when `integrity_check` returns `ok`, the migration table lists
every expected migration, and `/health/ready` answers 200 against the restored
file.

## Failure modes and recovery

| Situation | Action |
|---|---|
| Accidental bad write / logical corruption | Stop writes, `litestream restore -timestamp …` to just before the incident, swap the file, restart |
| Disk loss on the VM | Recreate `/var/lib/rust-api`, `litestream restore`, restart `rust-api` |
| Database file deleted (no replica yet) | Restore from the nightly `.backup` snapshot; accept the gap since 04:30 |
| Broken schema after a failed deploy | Migrations are forward-only; see README "Deploying schema changes" — never hand-edit `_sqlx_migrations` |

## What is deliberately out of scope here

- Multiple writers across machines (SQLite is single-node by design).
- Encrypting replicas — apply at the object-storage bucket level.
