//! Benchmark feed API: Axum + Tokio + SQLx + SQLite implementation of the
//! twelve-dollar-server-challenge spec (see ../README.md for the mapping).

mod auth;
mod db;
mod error;
mod metrics;
mod models;
mod routes;

use std::process::ExitCode;
use std::sync::Arc;
use std::time::{Duration, Instant};

use sqlx::sqlite::SqliteSynchronous;
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;

use crate::db::PoolConfig;

/// Shared handler state. Pools are behind the single `Arc`; handlers clone the
/// `Arc` per request (one refcount bump, no per-request allocation otherwise).
pub struct AppState {
    pub read: sqlx::SqlitePool,
    pub write: sqlx::SqlitePool,
    pub secret: Vec<u8>,
    pub started: Instant,
}

fn env_or(name: &str, default: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| default.to_owned())
}

fn env_parsed<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

async fn shutdown_signal() {
    let ctrl_c = tokio::signal::ctrl_c();
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        let mut terminate = signal(SignalKind::terminate()).expect("SIGTERM handler");
        tokio::select! {
            result = ctrl_c => { result.expect("CTRL-C handler"); }
            _ = terminate.recv() => {}
        }
    }
    #[cfg(not(unix))]
    {
        ctrl_c.await.expect("CTRL-C handler");
    }
}

fn load_config() -> Result<(String, String, String, Vec<u8>, PoolConfig), String> {
    let host = env_or("HOST", "127.0.0.1");
    let port = env_or("PORT", "3000");
    if port.parse::<u16>().is_err() {
        return Err(format!("PORT must be a valid port number, got {port:?}"));
    }
    let sqlite_path = env_or("SQLITE_PATH", "feed.db");
    let secret = match std::env::var("JWT_SECRET") {
        Ok(secret) if !secret.is_empty() => secret.into_bytes(),
        _ => return Err("JWT_SECRET must be set to a non-empty value".to_owned()),
    };

    let read_connections = env_parsed("SQLITE_READ_POOL", 2u32).clamp(1, 64);
    let synchronous = match env_or("SQLITE_SYNCHRONOUS", "NORMAL")
        .to_ascii_uppercase()
        .as_str()
    {
        "NORMAL" => SqliteSynchronous::Normal,
        "FULL" => SqliteSynchronous::Full,
        other => {
            return Err(format!(
                "SQLITE_SYNCHRONOUS must be NORMAL or FULL, got {other:?}"
            ));
        }
    };
    let config = PoolConfig {
        read_connections,
        synchronous,
        busy_timeout: Duration::from_millis(env_parsed("SQLITE_BUSY_TIMEOUT_MS", 5_000u64)),
        cache_kib: std::env::var("SQLITE_CACHE_KIB")
            .ok()
            .and_then(|v| v.parse().ok()),
        mmap_bytes: std::env::var("SQLITE_MMAP_KIB")
            .ok()
            .and_then(|v| v.parse::<i64>().ok())
            .map(|kib| kib * 1024),
    };
    Ok((host, port, sqlite_path, secret, config))
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let (host, port, sqlite_path, secret, pool_config) = match load_config() {
        Ok(config) => config,
        Err(message) => return Err(message.into()),
    };

    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("info,tower_http=warn")),
        )
        .init();

    let (read, write) = db::connect_pools(&sqlite_path, &pool_config);

    // Warm the pools and surface database problems at startup without refusing
    // to serve: /health reports degraded until the database answers.
    for (label, pool) in [("read", &read), ("write", &write)] {
        match sqlx::query("SELECT 1").execute(pool).await {
            Ok(_) => {}
            Err(err) => tracing::warn!(pool = label, error = %err, "startup database probe failed"),
        }
    }

    let state = Arc::new(AppState {
        read,
        write,
        secret,
        started: Instant::now(),
    });
    metrics::spawn_reporter(state.read.clone(), state.write.clone());

    let listener = TcpListener::bind((host.as_str(), port.parse::<u16>()?)).await?;
    tracing::info!(
        bind = %listener.local_addr()?,
        sqlite_path = %sqlite_path,
        read_pool = pool_config.read_connections,
        write_pool = 1,
        synchronous = ?pool_config.synchronous,
        "feed API started"
    );

    axum::serve(listener, routes::router(state.clone()))
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    // Close SQLite cleanly: this checkpoints the WAL and releases locks.
    state.read.close().await;
    state.write.close().await;
    tracing::info!("feed API stopped");
    Ok(())
}

fn main() -> ExitCode {
    match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("tokio runtime")
        .block_on(run())
    {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("fatal: {err}");
            ExitCode::FAILURE
        }
    }
}
