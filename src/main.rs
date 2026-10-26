use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use axum::{
    Json, Router,
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::get,
};
use serde::Serialize;
use tokio::net::TcpListener;
use tower_http::{limit::RequestBodyLimitLayer, timeout::TimeoutLayer, trace::TraceLayer};
use tracing_subscriber::EnvFilter;

use rust_api::db;

use db::{Database, DbConfig};

#[derive(Serialize)]
struct Health<'a> {
    status: &'a str,
    version: &'a str,
}

#[derive(Serialize)]
struct DegradedHealth {
    status: &'static str,
    error: String,
}

fn git_sha() -> &'static str {
    option_env!("GIT_SHA").unwrap_or("dev")
}

async fn live() -> Json<Health<'static>> {
    // Liveness deliberately never touches the database.
    Json(Health {
        status: "ok",
        version: git_sha(),
    })
}

async fn ready(State(state): State<AppState>) -> Response {
    match state.database.ready_check().await {
        Ok(()) => Json(Health {
            status: "ok",
            version: git_sha(),
        })
        .into_response(),
        Err(err) => {
            tracing::warn!(error = %err, kind = db::describe_db_error(&err), "readiness check failed");
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(DegradedHealth {
                    status: "degraded",
                    error: err.to_string(),
                }),
            )
                .into_response()
        }
    }
}

#[derive(Clone)]
struct AppState {
    database: Arc<Database>,
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

fn tracing_init() {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("rust_api=info,tower_http=info")),
        )
        .init();
}

fn database_url() -> String {
    std::env::var("DATABASE_URL").unwrap_or_else(|_| db::DEFAULT_DATABASE_URL.to_owned())
}

/// `rust-api migrate`: apply pending migrations to `$DATABASE_URL`, then exit.
/// Intentionally a separate command — the server never changes the schema at
/// startup or per request.
async fn migrate_command() -> ExitCode {
    let url = database_url();
    match db::apply_migrations(&url).await {
        Ok(applied) => {
            println!("applied {applied} pending migration(s) to {url}");
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("migration failed for {url}: {err}");
            ExitCode::FAILURE
        }
    }
}

async fn serve() -> Result<(), Box<dyn std::error::Error>> {
    tracing_init();

    let bind = std::env::var("APP_BIND").unwrap_or_else(|_| "127.0.0.1:8080".to_owned());
    let url = database_url();
    let config = DbConfig {
        url,
        ..DbConfig::default()
    };
    let database = Arc::new(Database::connect(&config)?);

    // Log (but do not fail) startup if the database is not usable yet: the
    // process must come up so /health endpoints can report the truth.
    if let Err(err) = database.ready_check().await {
        tracing::warn!(error = %err, kind = db::describe_db_error(&err), "startup database probe failed");
    }

    let state = AppState {
        database: database.clone(),
    };
    let app = Router::new()
        .route("/health/live", get(live))
        .route("/health/ready", get(ready))
        .layer(RequestBodyLimitLayer::new(1024 * 1024))
        .layer(TimeoutLayer::with_status_code(
            StatusCode::GATEWAY_TIMEOUT,
            Duration::from_secs(15),
        ))
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let listener = TcpListener::bind(&bind).await?;
    tracing::info!(%bind, database = %config.url, "API started");
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    // Checkpoint the WAL and release SQLite locks before exit.
    database.close().await;
    Ok(())
}

#[tokio::main(flavor = "multi_thread", worker_threads = 1)]
async fn main() -> ExitCode {
    match std::env::args().nth(1).as_deref() {
        Some("migrate") => migrate_command().await,
        Some(other) => {
            eprintln!("unknown command {other:?}; expected `migrate` or no argument");
            ExitCode::from(2)
        }
        None => match serve().await {
            Ok(()) => ExitCode::SUCCESS,
            Err(err) => {
                eprintln!("fatal: {err}");
                ExitCode::FAILURE
            }
        },
    }
}
