# Deployment IAM audit (2026-10-27)

Read-only inspection of the identities involved in the GitHub Actions →
GCE deployment path, at `main` = `d2bf475`. Nothing was modified during the
audit. Findings drive PR 1; the remaining recommendations are listed at the
end.

## Identities and bindings

### 1. GitHub-side identity: workflow → OIDC token

- `ci-deploy.yml` granted `id-token: write` at **workflow scope** — every
  job of every run (including pull requests) could request a Google
  credential context.
- **Finding (fixed in PR 1):** workflow default reduced to
  `contents: read`; `id-token: write` is now granted only to the `deploy`
  job (job scope). Pull-request runs of verify/benchmark/security can no
  longer obtain an OIDC-token context for this repo's WIF pool.

### 2. Workload Identity Federation: who may exchange a token

- Pool `github-actions-pool`, provider `github-actions-provider` (ACTIVE).
- Mapping: `google.subject=assertion.sub`, `attribute.repository`,
  `attribute.ref`.
- **Condition: `assertion.repository=='eswrops/rust-api-deployment-starter'`**
  — matches by repository *name*, any ref.
- **Finding:** any ref of the repository (feature branch, PR merge ref,
  future renamed forks under the same name) can exchange a token for the
  deployer SA. Repository names are mutable/uniquely-claimed but not
  immutable identifiers; GitHub's OIDC token also carries `repository_id`,
  which is immutable.
- **Prepared remediation (not applied — needs operator approval):**
  `ops/gce-harden-github-oidc.sh` updates the provider to
  `assertion.repository_id=='1434567946' && assertion.ref=='refs/heads/main'`
  (additionally maps `attribute.repository_id`). `--apply` gated, dry-run by
  default, prints a rollback command. Validation path: the
  `gcp-auth-smoke.yml` workflow (dispatch-only, read-only
  `compute.instances.describe`, `production` environment) must succeed on
  `main` and fail from a feature branch after the change.

### 3. Deployer service account: `github-rust-api-deployer@…`

Keyless: the SA has only its Google-managed key (`keys list` shows one
`SYSTEM_MANAGED` entry; no user-managed JSON keys exist).

| Scope | Role | Permissions |
|---|---|---|
| SA (who may impersonate) | `roles/iam.workloadIdentityUser` | principalSet bound to `attribute.repository/eswrops/rust-api-deployment-starter` |
| Project | `projects/…/roles/rustApiDeploymentProjectAccess` | `compute.projects.get`, `compute.globalOperations.get`, `compute.zoneOperations.get` |
| Project | `projects/…/roles/rustApiIapInstanceReader` | `compute.instances.get`, `compute.instances.list` |
| Project | `roles/iap.tunnelResourceAccessor` | IAP TCP forwarding to the instance |
| Instance | `projects/…/roles/rustApiInstanceDeployer` | `compute.instances.get`, `compute.instances.list`, `compute.instances.setMetadata` |

### 4. What a deployment actually uses

1. OIDC token → `token.create` against the pool (WIF), exchanged for the SA
   credential.
2. `compute.instances.get` — read metadata (filter operator ssh-keys).
3. `compute.instances.setMetadata` — write the ssh-keys metadata with the
   operator keys preserved + this run's 10-minute expiring key.
4. `iap.tunnelResourceAccessor` — open the IAP tunnel to tcp/22.
5. `compute.zoneOperations.get` / `globalOperations.get` /
   `compute.projects.get` — used by gcloud's operation polling.
6. SSH (as `deploy`) → sudoers-gated `/usr/local/sbin/rust-api-activate`.

## Risk analysis

- **`compute.instances.setMetadata` is the widest surface.** It applies to
  the single production instance (instance-level binding) and can rewrite
  *all* instance metadata, including `ssh-keys` for any user. Combined with
  `iap.tunnelResourceAccessor`, a holder of a valid token can add an SSH key
  and reach the VM as any user in that metadata — this is precisely the
  deployment mechanism, so the grant cannot be removed without replacing
  the transport. Blast-radius mitigations in place: instance-scoped role
  (not project), `deploy`'s sudoers restricts root access to
  `rust-api-activate`-style entry points, keys written by CI expire after
  10 minutes. Residual risk: metadata writes could also disturb other
  metadata consumers (none currently beyond ssh-keys).
- **The WIF condition is the effective security boundary** — the SA-level
  `workloadIdentityUser` binding matches any ref of the repository, so
  before 1.2 lands, *any* workflow run on *any* branch that requests
  `id-token: write` could impersonate the deployer. PR 1 removes the token
  capability from non-deploy jobs (defense) and the hardened condition
  (depth) closes it.
- **No lateral movement paths found**: the SA cannot read other instances'
  metadata (no `instances.list` beyond the reader role scoped project-wide —
  see recommendation 3), cannot modify IAM, has no storage or service
  management permissions, and holds no static keys.
- **`rustApiIapInstanceReader` / `rustApiDeploymentProjectAccess`** are
  read-only and exist to satisfy gcloud's describe/operation-polling calls;
  they cannot change state.

## Recommendations

1. **Apply the hardened WIF condition** (separate approved operation):
   `ops/gce-harden-github-oidc.sh --apply`, then run `gcp-auth-smoke.yml`
   from `main` (expect success) and from a branch (expect failure).
2. **Keep `id-token: write` job-scoped** (done in PR 1); review any new
   workflow for the same pattern.
3. Optional tightening: `rustApiIapInstanceReader` grants
   `compute.instances.list` project-wide (metadata of *other* instances is
   not exposed by list, but instance names/statuses are visible). Could be
   dropped if gcloud's tunnel/describe paths tolerate it — verify with the
   smoke workflow before removing.
4. Optional hardening of the metadata write: `setMetadata` is all-or-
   nothing per metadata key. A narrower transport (e.g. OS Login or a
   metadata-agent pull model) would remove `setMetadata` entirely, but
   replaces a proven transport — the mission requires a successful
   independent test before any such change. Not planned for this mission.
5. Monitoring: add a log-based alert on
   `protoPayload.methodName="v1.compute.instances.setMetadata"` for this
   instance so any out-of-band metadata write is visible (needs an alerting
   sink; no monitoring agent is allowed on the VM — a log-metric + external
   check fits the constraint).

## Verification evidence

- `gcloud iam service-accounts keys list` → 1 × SYSTEM_MANAGED (keyless).
- `gcloud projects get-iam-policy` / instance `get-iam-policy` / SA
  `get-iam-policy` → binding tables above (2026-10-27).
- Provider describe → mapping/condition quoted above (2026-10-27).
