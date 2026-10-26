//! SQLite wiring: one write connection plus a small read pool, all with the
//! pragmas required by the challenge (WAL, foreign keys, busy timeout,
//! synchronous NORMAL or FULL). Connections are created lazily so the process
//! still boots (and answers /health with 503) when the database file is broken.

use std::time::Duration;

use sqlx::sqlite::{
    SqliteConnectOptions, SqliteJournalMode, SqlitePool, SqlitePoolOptions, SqliteSynchronous,
};

#[derive(Debug, Clone, Copy)]
pub struct PoolConfig {
    pub read_connections: u32,
    pub synchronous: SqliteSynchronous,
    pub busy_timeout: Duration,
    /// Positive value for `PRAGMA cache_size` in KiB (stored negative: whole KiB).
    pub cache_kib: Option<i64>,
    /// `PRAGMA mmap_size` in bytes; 0 keeps the SQLite default.
    pub mmap_bytes: Option<i64>,
}

impl Default for PoolConfig {
    fn default() -> Self {
        Self {
            read_connections: 2,
            synchronous: SqliteSynchronous::Normal,
            busy_timeout: Duration::from_secs(5),
            cache_kib: None,
            mmap_bytes: None,
        }
    }
}

fn connect_options(path: &str, config: &PoolConfig) -> SqliteConnectOptions {
    let mut options = SqliteConnectOptions::new()
        .filename(path)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(config.synchronous)
        .foreign_keys(true)
        .busy_timeout(config.busy_timeout)
        .create_if_missing(false);
    if let Some(kib) = config.cache_kib {
        options = options.pragma("cache_size", format!("-{kib}"));
    }
    if let Some(bytes) = config.mmap_bytes {
        options = options.pragma("mmap_size", bytes.to_string());
    }
    options
}

/// Builds the read pool (`config.read_connections` connections) and the write
/// pool (exactly one connection). `min_connections == max_connections` keeps a
/// warm set; SQLite in WAL mode lets readers run concurrently with the writer.
pub fn connect_pools(path: &str, config: &PoolConfig) -> (SqlitePool, SqlitePool) {
    let options = connect_options(path, config);
    let read = SqlitePoolOptions::new()
        .max_connections(config.read_connections)
        .min_connections(config.read_connections)
        .acquire_timeout(config.busy_timeout)
        .connect_lazy_with(options.clone());
    let write = SqlitePoolOptions::new()
        .max_connections(1)
        .min_connections(1)
        .acquire_timeout(config.busy_timeout)
        .connect_lazy_with(options);
    (read, write)
}
