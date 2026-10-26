# feed-api — Rust / Axum / SQLx / SQLite submission for the $12 Server Challenge

Implements the five-endpoint feed API from [`SPEC.md`](https://github.com/arjaythedev/twelve-dollar-server-challenge/blob/main/SPEC.md)
exactly: `GET /health`, `GET /feed`, `GET /posts/:id`, `POST /posts`, `POST /posts/:id/like`.

- **Language / framework:** Rust 1.99.1 (pinned in `rust-toolchain.toml`), Axum 0.8 on Tokio, hyper 1.x HTTP/1.1 with keep-alive.
- **Driver:** SQLx 0.8 (`sqlx-sqlite`, bundled libsqlite3 via libsqlite3-sys) — one dedicated write connection plus a small reader pool.
- **JSON:** serde / serde_json with typed response structs; field declaration order is the wire key order.
- **Transport choice: direct** (`HOST=0.0.0.0 PORT=80` with `CAP_NET_BIND_SERVICE`). No Nginx: hyper handles tens of thousands of
  keep-alive sockets itself, and skipping the proxy saves the 14–20 % CPU Nginx used in the video. For the challenge test harness
  (`test/run.sh`) the server simply binds `$HOST:$PORT` (default `127.0.0.1:3000`), which works with or without the benchmark Nginx.

## Layout

| File | Purpose |
|---|---|
| `src/main.rs` | config from env, pool construction, router, graceful shutdown, metrics reporter |
| `src/routes.rs` | the five endpoints, exact error/status handling |
| `src/auth.rs` | HS256 JWT verification (signature + `exp` + payload typing) |
| `src/db.rs` | SQLite pragmas, reader/writer pools |
| `src/error.rs` | the `{"error":"…"}` wire format |
| `src/models.rs` | typed responses; serialization order is contract |
| `src/metrics.rs` | pool-wait histogram + SQLite busy/locked counters (observability only) |
| `tests/e2e.rs` | 11 end-to-end regression tests against the compiled binary |
| `bench/stress.js`, `bench/run-bench.sh` | local tuning harness (not part of the submission) |
| `install.sh` / `build.sh` / `start.sh` | upstream submission scripts |

## Design decisions and why

**Pools: one writer, N readers.** SQLite allows concurrent readers with a single writer in WAL mode. All mutations go through
one pooled connection (serialized by the pool — no cross-process contention, no `SQLITE_BUSY` between our own writes), while
reads fan out across `SQLITE_READ_POOL` connections (default 2, benchmarked with 2 and 4). Connections are warm
(`min == max_connections`) and created lazily so the process boots even when the database file is broken; `/health` reports
`503 {"status":"degraded","db":"unreachable",…}` until a `SELECT 1` succeeds. Hyper's HTTP/1 server has no idle-connection
timeout, satisfying the ≥65 s keep-alive requirement behind the benchmark Nginx.

**SQL.** The spec's reference queries are already optimal (verified with `EXPLAIN QUERY PLAN`; see the report below): the feed
is an index-ordered scan of `posts_created_at_id_idx` (no sort node), the author join and like-count subquery are PK/covering-index
lookups. Statements live in constants so sqlx's per-connection prepared-statement cache reuses one plan per query; every value is
bound, nothing is string-interpolated.

**Write durability before 201.** Single-statement writes run in autocommit — no explicit transaction to unwind. `POST /posts`
uses `INSERT … RETURNING id, created_at` fetched with `fetch_all` so the statement is driven to `SQLITE_DONE` (commit applied)
before the response is serialized. Likes use `INSERT … ON CONFLICT (user_id, post_id) DO NOTHING`: one round-trip returns 201 on
the fast path; `rows_affected == 0` means the conflict already existed (200); a foreign-key violation means the post (or user)
is missing, disambiguated with one cheap PK lookup (404 vs 500).

**JWT.** Hand-rolled HS256 verification (~80 lines, fully unit-tested): constant-time HMAC check via `hmac::Mac::verify_slice`,
`alg` must equal `HS256` (so `alg=none` and `HS512` are rejected), `exp` must be present, a finite number, and strictly in the
future — compared with fractional-second precision, per RFC 7519 §2 which allows non-integer NumericDates (integer and
fractional `exp` both verify; strings, booleans, null and expired values are rejected).
Structural problems map to `invalid or expired token`; a correctly signed token with a non-integer `sub` or non-string
`username` maps to `invalid token payload`. Nothing is cached across requests — every authenticated request verifies the signature.

**No benchmark tricks.** No response caching, no remembered JWT verifications, no schema changes, no extra indexes, no
load-generator detection. SQLite's own page cache is the only cache.

**Observability.** A lock-free acquire-time histogram and SQLite busy/locked counters are logged once a minute; request tracing
via `tower_http::TraceLayer` is enabled but suppressed at the default log level (`RUST_LOG=info,tower_http=warn`) so per-request
spans never cost anything during load runs.

## Environment

`HOST` (default `127.0.0.1`), `PORT` (default `3000`), `SQLITE_PATH` (default `feed.db`), `JWT_SECRET` (required — the server
refuses to start without it). Tuning knobs used for the experiments below (all optional): `SQLITE_READ_POOL`,
`SQLITE_SYNCHRONOUS` (`NORMAL`|`FULL`), `SQLITE_BUSY_TIMEOUT_MS`, `SQLITE_CACHE_KIB`, `SQLITE_MMAP_KIB`.

## Running the tests

```bash
bash ../../seed/make-seed.sh                        # upstream repo: builds seed/feed.db (~250 MB) and seed/tokens.json
bash test/run.sh path/to/this/folder                # upstream: build + start on a fresh DB copy + 42-check suite
```

In-repo regression suite (no seed database needed; uses a deterministic synthetic fixture and the upstream schema verbatim):

```bash
cargo test --locked                                 # 10 unit + 11 end-to-end tests
```

The end-to-end tests cover: byte-exact golden reads, invalid/missing ids, the full auth error matrix (missing/garbage/bad
signature/`alg=none`/expired (integer and fractional)/string/null/boolean `exp`/bad payload), fractional-`exp` acceptance,
auth-before-id precedence, body trimming/Unicode/500-char limit, first-like 201 vs
repeat 200, eight concurrent duplicate likes (exactly one 201), four concurrent distinct-user likes, SIGKILL durability +
read-after-write on restart, SIGTERM graceful shutdown, and degraded health when the database is unreachable.

Fault-injection and transport-pressure tests (`tests/*.py`, self-contained: each spawns its own server on its own database
copy — fixture by default, the challenge seed via `SEED_DB=`; CI runs all three):

- `tests/commit_check.sh` (Linux only — GNU ld `--wrap`; refuses elsewhere): builds `bin/commit-test`, the unmodified release
  binary linked with `tests/commit_fault.c`, which installs a SQLite commit hook controlled by marker files. Proves that a
  failed `COMMIT` returns 500, rolls back (checked through the API and by reading SQLite directly), consumes the hook's
  `fail` marker and leaves the server usable — and, by holding the commit inside the hook, that no success response is sent
  before the commit finishes, with the committed row then visible in SQLite and through the API.
- `tests/pressure_regression.py`: starts the server with `nofile=256`, holds 160 idle keep-alive connections plus an extra
  30 to approach the descriptor ceiling, and completes a fragmented upload, 32 write/readback pairs, duplicate likes
  (201 then idempotent 200, count stays 1), 20 abrupt client disconnects (RST) and a post-disconnect write, then checks
  keep-alive recovery after the pressure subsides. `EXPECT_RETIREMENT=1` additionally asserts
  `Connection: close` load-shedding once the server implements it (gated until then).
- `tests/idle_client.py`: opens `IDLE_COUNT` (default 15,000) idle keep-alive connections, re-verifies every socket, and
  reports RSS, CPU, descriptor usage, failed attempts and platform — the measured basis for the memory figures in the
  performance report. CI runs a deterministic subset (3,000); the full 15,000-connection benchmark stays manual
  (`workflow_dispatch` with `idle_connections: 15000`, or `IDLE_COUNT=15000 python3 tests/idle_client.py`).

## Performance report

Environment: Apple Silicon (M-series, 2024), 24 GB RAM, macOS 27, k6 on the same machine (best-effort comparisons — the scored
run happens on the challenge's 1 vCPU / 2 GB droplet, where absolute numbers will be lower; the *relative* pool/pragma
comparisons carry over). Load: `bench/stress.js` (feed + post read, 20 % like, 5 % create, 50 ms pause — far heavier writes
than the scored upstream profile). Peak RSS from `ps` sampling / `/usr/bin/time -l`; CPU from 1 Hz `ps` sampling of the server
process (k6 shares the machine, so CPU is context, not budget).

`EXPLAIN QUERY PLAN` for the two hot queries (fresh copy of `seed/feed.db`, 500k posts / 2M likes):

```
feed:   SCAN p USING INDEX posts_created_at_id_idx
        SEARCH u USING INTEGER PRIMARY KEY (rowid=?)
        CORRELATED SCALAR SUBQUERY
          SEARCH l USING COVERING INDEX likes_post_id_idx (post_id=?)
post:   SEARCH p USING INTEGER PRIMARY KEY (rowid=?)
        SEARCH u USING INTEGER PRIMARY KEY (rowid=?)
        CORRELATED SCALAR SUBQUERY
          SEARCH l USING COVERING INDEX likes_post_id_idx (post_id=?)
```

No sort node (the `ORDER BY created_at DESC, id DESC LIMIT 20` is satisfied by the index), no table scans — the fixed schema
already serves these queries optimally, so no query rewrites were needed.

<!-- PERFORMANCE-MATRIX -->

Stress-profile tuning matrix (single runs on a shared machine, so treat differences under ~10 % as noise; VUS = 200 concurrent
connections):

| config | rps | p50 ms | p95 ms | p99 ms | errors | CPU % avg/max | peak RSS |
|---|---|---|---|---|---|---|---|
| read pool 2, `synchronous=NORMAL` (shipped default) | 7541 | 0.7 | 2.4 | 4.1 | 0.00 % | 107 / 129 | 14.6 MB |
| read pool 2, `synchronous=FULL` | 7528 | 0.7 | 2.5 | 5.1 | 0.00 % | 109 / 152 | 14.3 MB |
| read pool 4, `synchronous=NORMAL` | 7355 | 0.9 | 3.6 | 13.2 | 0.00 % | 198 / 276 | 15.5 MB |
| read pool 4, `synchronous=FULL` | 6689 | 1.4 | 13.1 | 47.8 | 0.00 % | 166 / 239 | 15.5 MB |
| read pool 2, NORMAL, 16 MiB page cache + 256 MiB mmap | 6941 | 1.5 | 9.5 | 26.6 | 0.00 % | 140 / 232 | 24.0 MB |

SQLite busy/locked errors: **0 in every configuration** (the server's own counters, confirmed by the 0.00 % error rate — the
single write connection removes writer/writer contention by construction).

Upstream scoring profile (`bench/load.js`, real user think time, direct connection, read pool 2 / NORMAL — the shipped default):

| VUs | rps | p50 ms | p95 ms | p99 ms | errors | CPU % avg/max | peak RSS |
|---|---|---|---|---|---|---|---|
| 1,000 | 88 | 0.2 | 0.4 | 0.8 | 0.00 % | 0.9 / 5.0 | 41 MB |
| 4,000 | 352 | 0.3 | 0.9 | 2.0 | 0.00 % | 12 / 23 | 138 MB |

At 4,000 keep-alive connections the p99 is 2 ms against the 1,000 ms pass threshold — three orders of magnitude of headroom.
RSS at scale was measured directly with `tests/idle_client.py` (all connections health-checked and re-verified on their
original sockets): 103 MB at 3,000 idle connections, 492 MB at 15,000 — about 33 KB per idle keep-alive socket plus a small
fixed base. That puts the ~15,000-connection direct-connection ceiling near 500 MB, still inside a 2 GB droplet but close to
2.5× the ~13 KB/socket the earlier projection assumed, so capacity planning should use the measured figure.

**Conclusions.**

- The read pool size (2 vs 4) does not matter at realistic concurrency: requests acquire a connection and hold it for
  well under a millisecond, so the pool is never the bottleneck; queueing theory and the measurements agree.
- `synchronous=FULL` costs little under this write mix because SQLite in WAL mode fsyncs only the WAL at commit and the
  stress profile's write rate is still modest; NORMAL remains the shipped default (it is what the upstream rules assume and
  it wins the tail on the droplet-class hardware where fsync latency is 10–100× higher).
- Page-cache/mmap tuning (`SQLITE_CACHE_KIB`, `SQLITE_MMAP_KIB`) showed no measurable benefit: the 250 MB database's hot
  working set (newest posts + their likes) already fits SQLite's default cache during the run.
- Zero SQLite busy/locked errors in every run: the single-writer pool design eliminates self-inflicted contention.

**Known limitations.**

- Absolute numbers here are indicative only (different CPU class, same-machine k6, no Nginx). The scored run is upstream's.
- `panic = "unwind"` is kept (instead of `abort`) so a panicking task cannot take the whole service down; a panic in a
  handler drops that connection only.
- Body sizes over 64 KiB are rejected with 413 (spec leaves >16 KiB bodies out of scope).
- Wrong-method requests on known paths get Axum's default 405 with an empty body (spec leaves these out of scope).
- A signed token whose `sub` names a non-existent user makes the like insert fail the foreign key and returns 500
  ("anything else" per the spec); the create endpoint would likewise fail. The challenge's pre-signed tokens (users 1–20,000)
  never hit this path.
