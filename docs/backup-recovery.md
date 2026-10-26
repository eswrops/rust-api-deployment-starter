# SQLite backup and recovery

The production database lives at `/var/lib/rust-api/app.db` (systemd
`StateDirectory=rust-api`, WAL mode, `synchronous=FULL`) on the persistent
boot disk of `rust-api-prod`. This document describes the **implemented and
tested** backup system; the execution record is at the bottom.

## Implemented architecture

Two layers, both automated with systemd timers, running as the `rustapi`
service account:

| Layer | What | Where | Retention |
|---|---|---|---|
| Local quick recovery | Online `sqlite3` backup-API snapshot (`app-YYYYmmddTHHMMSSZ.db` + `app-latest.db`) | `/var/lib/rust-api/backups` (0750 rustapi) | 7 daily (`LOCAL_KEEP_DAYS`) |
| Off-site | Same snapshot uploaded to a **private** GCS bucket, plus heartbeat / drill / alert objects | `gs://rust-api-prod-backups-650296500144` (us-west1, STANDARD) | 30 daily live (`OFFSITE_KEEP_DAYS`); superseded versions purged after 7 days |

Additional safety properties of the bucket (all verified):

- **Public access prevention enforced** and uniform bucket-level access: it
  cannot be made public.
- **Object versioning**: an overwrite or delete turns the previous version
  into a noncurrent version, kept for a 7-day recovery window before the
  retention pass purges it.
- **Soft delete (7 days)**: even a hardened delete of any object remains
  recoverable for a week.
- Live snapshot expiry *archives first and purges later*, so an expired
  snapshot still passes through the 7-day windows.

RPO is 24 h (daily timer at 04:15 UTC, `Persistent=true` so a missed run
fires at boot). The documented upgrade path to near-continuous RPO is
Litestream WAL shipping into the same bucket — see "Future work".

## Least-privilege off-site identity

The VM was provisioned **without** an attached service account, so backups
authenticate with a dedicated identity rather than a broad one:

- Service account `rust-api-backup@rust-product-foundry-4bd846.iam.gserviceaccount.com`.
- Exactly one role, `roles/storage.objectUser`, bound **at the bucket level
  only** — the identity can upload, overwrite and run retention deletes on
  this bucket and nothing else in the project. It cannot read other buckets,
  change IAM, or touch Compute Engine.
- Its JSON key is installed at `/etc/rust-api/backup-gcs-key.json`
  (`root:rustapi 0640`); the service environment file is
  `/etc/rust-api/backup.env` (`root:rustapi 0640`), and its `DATABASE_URL`
  is byte-identical to the production service's.
- Talk to GCS through the JSON API with a service-account JWT exchanged via
  curl + openssl — **no Google SDK, no extra packages on the e2-micro**.
- Rotation: `gcloud iam service-accounts keys create …`, run
  `ops/install-backups.sh --key-file <new-key>`, then delete the old key id
  via `gcloud iam service-accounts keys delete <id> --iam-account …`.
- Hardening alternative (no key on disk at all): stop the VM once, attach a
  VM service account with the same bucket-scoped role, and drop the key.
  This trades a short maintenance window for eliminating the static key;
  not done during this iteration to avoid any production interruption.

## Daily schedule and the units

| Unit | Schedule | Purpose |
|---|---|---|
| `rust-api-backup.service` + `.timer` | daily 04:15 UTC (±5 min) | snapshot → integrity-check → local copies/retention → GCS upload → heartbeat → off-site retention |
| `rust-api-restore-drill.service` + `.timer` | Sundays 05:15 UTC | download newest **live** snapshot from the bucket, `integrity_check` + migration/table counts via python3 stdlib, boot the deployed binary against it with an explicit `APP_BIND=127.0.0.1:18081`, require `/health/ready` 200, upload a drill report |
| `rust-api-backup-alert@.service` | OnFailure of both units above | local `ALERT` marker + `ALERT.log`, loud journal line, best-effort off-site `alerts/<stamp>-<unit>.txt` |

Scripts live at `/usr/local/sbin/rust-api-backup{,-lib.sh,-alert,}` and are
installed from `ops/backup/` by `ops/install-backups.sh` (idempotent;
re-running refreshes scripts and re-verifies a full backup + drill cycle).

## How a failed backup becomes visible

1. `systemctl --failed` lists the failed unit; `journalctl -u <unit>` has the
   reason; the run's exit code is non-zero.
2. `/var/lib/rust-api/backups/ALERT` (sticky marker with the failure report;
   cleared automatically by the next successful backup; `ALERT.log` keeps
   history). This path is exercised and works.
3. An off-site `alerts/…` object appears in the bucket (tested: a real unit
   failure produced `alerts/20261026T203257Z-rust-api-backup.service.txt`).
4. **Dead-man's switch**: if the VM dies or the whole pipeline breaks, the
   daily `heartbeat.txt` object stops refreshing — any check of
   `gs://…/heartbeat.txt` older than ~48 h is an alarm even when the VM
   cannot report anything.

There is deliberately no email/pager integration (no monitoring stack on the
VM by constraint); the four channels above are the alert surface. Wire
channel 4 into an external checker if you need push-style paging.

## Restore procedures

### Local quick recovery (VM alive)

```bash
sudo systemctl stop rust-api            # brief, only if consistency matters
sudo -u rustapi sqlite3 /var/lib/rust-api/app.db ".restore '/var/lib/rust-api/backups/app-latest.db'"
sudo systemctl start rust-api
curl -fsS http://127.0.0.1:8080/health/ready
```

(SQLite online snapshots are self-consistent; stopping the service is
optional but eliminates concurrent writes during the swap.)

### Full restore drill (automated, weekly)

`systemctl start rust-api-restore-drill.service` — or wait for the Sunday
timer. PASS requires: newest live bucket snapshot downloads, passes
`PRAGMA integrity_check`, contains the expected tables and migration rows,
and serves `/health/ready` 200 from the deployed binary. Reports land in
`gs://…/drills/` and `/var/lib/rust-api/backups/last-drill-success`.

### Whole-VM loss (the path that matters)

Nothing needed from the lost VM: the operator workstation (project owner)
restores directly from the bucket:

```bash
gcloud storage ls gs://rust-api-prod-backups-650296500144/snapshots/
gcloud storage cp gs://rust-api-prod-backups-650296500144/snapshots/<object> .
python3 -c "import sqlite3; c=sqlite3.connect('<object>'); print(c.execute('PRAGMA integrity_check').fetchone()[0])"
# recreate the VM (ops/gce-provision.sh + gce-bootstrap.sh), then:
#   sudo install -d -o rustapi -g rustapi -m 0750 /var/lib/rust-api
#   sudo -u rustapi sqlite3 /var/lib/rust-api/app.db ".restore '<downloaded snapshot>'"
#   re-run ops/install-backups.sh with a fresh key, then the normal CI deploy
```

This path was exercised during setup: a snapshot was downloaded to the
workstation and verified byte-identical (sha256 match against the heartbeat)
with `integrity_check=ok`.

## Retention and cost

- Local: 7 daily snapshots of the ~45 KB database in `/var/lib/rust-api`
  (inside the 30 GB disk's 26 GB free space).
- Bucket: 30 live daily snapshots + 7-day version/soft-delete window + small
  heartbeat/drill/alert objects. At the current size this is a few MB total
  against the 5 GB-month free tier for regional US storage (us-west1); the
  daily heartbeat writes are ~2 requests/day, far below free-tier request
  limits. Revisit sizing if the database grows materially.

## Future work

- **Litestream for near-continuous RPO**: ship WAL segments to the same
  bucket (replica URL `gs://rust-api-prod-backups-650296500144/litestream`).
  If adopted, pin the exact Litestream release asset **and verify its
  checksum at download time** (the official installation guide lists current
  release assets; do not hard-code a versioned filename in this document —
  verify it when installing), run it as the `rustapi` account under its own
  systemd service, and extend the drill to `litestream restore`.
- Fold backup freshness into `/health/ready` (or a `/health/backups`
  endpoint) so staleness is visible through the existing public health
  surface — deliberately not done now to keep the readiness contract
  deployment-critical only.

## Execution record (2026-10-26/27)

| Step | Result |
|---|---|
| Bucket created | `gs://rust-api-prod-backups-650296500144`, us-west1, STANDARD, PAP enforced, UBLA on, versioning on, soft delete 7 d |
| Identity | `rust-api-backup@…` SA, `roles/storage.objectUser` bound at bucket scope (verified in the bucket IAM policy); key installed `root:rustapi 0640` |
| Laptop test key | used for local verification, **revoked**; VM key created separately |
| Local end-to-end | snapshot→upload→heartbeat ✓; workstation restore sha256-identical ✓; 0-day-cutoff retention expiry ✓ (5 live objects archived then soft-delete verified) ✓; restore drill PASS ✓; alert marker + off-site alert object ✓ |
| VM install (`ops/install-backups.sh`) | timers enabled (04:15 UTC daily / Sun 05:15 UTC), backup service `Result=success`, drill **PASS** (integrity ok, `/health/ready` 200 from restored copy, report uploaded) |
| Failure drill on VM | broke `DATABASE_URL` → unit failed → `systemctl --failed` visible, `ALERT` marker written, off-site alert object created; env restored, next run `Result=success` |
| Known operational note | the installer's env/key files must keep `root:rustapi 0640`; a test-time `sudo mv` of the env file lost the group and was the only hiccup (fixed by restoring ownership) |
