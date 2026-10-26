//! Lightweight runtime observability: SQLite busy/locked error counts and
//! connection-pool acquisition times, kept in lock-free atomics and dumped to
//! the log periodically. Deliberately no cross-request caching of anything
//! user-visible; these counters only observe the process itself.

use std::sync::atomic::{AtomicU64, Ordering};

/// Upper bounds (in microseconds) of the pool-acquisition histogram buckets.
const ACQUIRE_BUCKETS_US: [u64; 12] = [
    10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 50_000, 250_000,
];

static ACQUIRE_TOTAL: AtomicU64 = AtomicU64::new(0);
static ACQUIRE_SLOWEST_US: AtomicU64 = AtomicU64::new(0);
static ACQUIRE_BUCKETS: [AtomicU64; 13] = {
    #[allow(clippy::declare_interior_mutable_const)]
    const B: AtomicU64 = AtomicU64::new(0);
    [B; 13]
};
static BUSY_ERRORS: AtomicU64 = AtomicU64::new(0);
static LOCKED_ERRORS: AtomicU64 = AtomicU64::new(0);
static DB_ERRORS: AtomicU64 = AtomicU64::new(0);

pub fn observe_acquire(elapsed: std::time::Duration) {
    let us = elapsed.as_micros() as u64;
    ACQUIRE_TOTAL.fetch_add(1, Ordering::Relaxed);
    ACQUIRE_SLOWEST_US.fetch_max(us, Ordering::Relaxed);
    let bucket = ACQUIRE_BUCKETS_US.partition_point(|&b| b < us);
    ACQUIRE_BUCKETS[bucket].fetch_add(1, Ordering::Relaxed);
}

pub fn record_db_error(err: &sqlx::Error) {
    DB_ERRORS.fetch_add(1, Ordering::Relaxed);
    let sqlx::Error::Database(db) = err else {
        return;
    };
    let code = db.code();
    let code = code.as_deref().unwrap_or_default();
    if code == "5" || db.message().contains("database is locked") {
        BUSY_ERRORS.fetch_add(1, Ordering::Relaxed);
    } else if code == "6" || db.message().contains("database table is locked") {
        LOCKED_ERRORS.fetch_add(1, Ordering::Relaxed);
    }
}

/// Emits one line every `interval` with cumulative counters and the acquire
/// histogram. `read`/`write` pool sizes are logged to correlate wait times
/// with pool configuration.
pub fn spawn_reporter(read: sqlx::SqlitePool, write: sqlx::SqlitePool) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            interval.tick().await;
            let buckets: Vec<u64> = ACQUIRE_BUCKETS
                .iter()
                .map(|b| b.load(Ordering::Relaxed))
                .collect();
            tracing::info!(
                acquires = ACQUIRE_TOTAL.load(Ordering::Relaxed),
                acquire_slowest_us = ACQUIRE_SLOWEST_US.load(Ordering::Relaxed),
                acquire_bucket_upper_bounds_us = ?ACQUIRE_BUCKETS_US,
                acquire_buckets = ?buckets,
                sqlite_busy_errors = BUSY_ERRORS.load(Ordering::Relaxed),
                sqlite_locked_errors = LOCKED_ERRORS.load(Ordering::Relaxed),
                sqlite_errors_total = DB_ERRORS.load(Ordering::Relaxed),
                read_pool_size = read.size(),
                read_pool_idle = read.num_idle(),
                write_pool_size = write.size(),
                "runtime metrics"
            );
        }
    });
}
