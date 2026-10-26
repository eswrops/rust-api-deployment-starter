//! SQLite wiring for the production API: one dedicated write connection plus
//! a small reader pool, all with WAL, foreign keys and a busy timeout.
//!
//! Durability posture: `synchronous=FULL` so a committed write is on disk
//! before the caller is told it succeeded. Connections are created lazily so
//! the process boots (and `/health/live` keeps answering) even while the
//! database file is broken or missing; `/health/ready` reports the truth.
//!
//! Migrations are NOT applied here: run `rust-api migrate` explicitly during
//! deployment (see README section on migrations).

use std::str::FromStr;
use std::time::Duration;

use sqlx::Connection;
use sqlx::sqlite::{
    SqliteConnectOptions, SqliteJournalMode, SqlitePool, SqlitePoolOptions, SqliteSynchronous,
};

pub const DEFAULT_DATABASE_URL: &str = "sqlite:///var/lib/rust-api/app.db";

#[derive(Debug, Clone)]
pub struct DbConfig {
    pub url: String,
    pub read_connections: u32,
    pub busy_timeout: Duration,
}

impl Default for DbConfig {
    fn default() -> Self {
        Self {
            url: DEFAULT_DATABASE_URL.to_owned(),
            read_connections: 2,
            busy_timeout: Duration::from_secs(5),
        }
    }
}

#[derive(Debug)]
pub struct Database {
    pub read: SqlitePool,
    pub write: SqlitePool,
}

fn connect_options(
    url: &str,
    create_if_missing: bool,
) -> Result<SqliteConnectOptions, sqlx::Error> {
    Ok(SqliteConnectOptions::from_str(url)?
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Full)
        .foreign_keys(true)
        .busy_timeout(Duration::from_secs(5))
        .create_if_missing(create_if_missing))
}

impl Database {
    /// Builds the reader pool (`config.read_connections` connections) and the
    /// single-connection writer pool. Connections are warm (`min == max`) and
    /// created lazily, so construction never fails on a bad database.
    pub fn connect(config: &DbConfig) -> Result<Self, sqlx::Error> {
        let options = connect_options(&config.url, false)?;
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
        Ok(Self { read, write })
    }

    /// The readiness probe: one `SELECT 1` on the reader pool.
    pub async fn ready_check(&self) -> Result<(), sqlx::Error> {
        let mut conn = self.read.acquire().await?;
        sqlx::query("SELECT 1")
            .execute(&mut *conn)
            .await
            .map(|_| ())
    }

    pub async fn close(&self) {
        self.read.close().await;
        self.write.close().await;
    }
}

/// Applies pending versioned migrations from `migrations/`. Used by the
/// `rust-api migrate` command and by tests; the server itself never mutates
/// the schema. Returns how many pending migrations were applied.
pub async fn apply_migrations(url: &str) -> Result<usize, Box<dyn std::error::Error>> {
    use sqlx::migrate::Migrate;

    let options = connect_options(url, true)?;
    let mut conn = sqlx::SqliteConnection::connect_with(&options).await?;
    let migrator = sqlx::migrate!();
    conn.ensure_migrations_table().await?;
    let applied: std::collections::HashSet<i64> = conn
        .list_applied_migrations()
        .await?
        .into_iter()
        .map(|m| m.version)
        .collect();
    let pending = migrator
        .iter()
        .filter(|m| !applied.contains(&m.version))
        .count();
    migrator.run(&mut conn).await?;
    conn.close().await?;
    Ok(pending)
}

/// Classifies a SQLite error for logging/metrics. SQLITE_BUSY (5) and
/// SQLITE_LOCKED (6) are reported distinctly so pool sizing decisions are
/// driven by data rather than guesswork.
pub fn describe_db_error(err: &sqlx::Error) -> &'static str {
    let sqlx::Error::Database(db) = err else {
        return "other";
    };
    let code = db.code();
    let code = code.as_deref().unwrap_or_default();
    if code == "5" || db.message().contains("database is locked") {
        "busy"
    } else if code == "6" || db.message().contains("database table is locked") {
        "locked"
    } else {
        "other"
    }
}
