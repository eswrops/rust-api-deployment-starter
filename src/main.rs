use std::time::Duration;

use axum::{Json, Router, http::StatusCode, routing::get};
use serde::Serialize;
use tokio::net::TcpListener;
use tower_http::{limit::RequestBodyLimitLayer, timeout::TimeoutLayer, trace::TraceLayer};
use tracing_subscriber::EnvFilter;

#[derive(Serialize)]
struct Health<'a> {
    status: &'a str,
    version: &'a str,
}

async fn live() -> Json<Health<'static>> {
    Json(Health {
        status: "ok",
        version: option_env!("GIT_SHA").unwrap_or("dev"),
    })
}

// Replace this with a real DB/dependency readiness check when persistence is added.
async fn ready() -> Json<Health<'static>> {
    live().await
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

#[tokio::main(flavor = "multi_thread", worker_threads = 1)]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("rust_api=info,tower_http=info")),
        )
        .init();

    let app = Router::new()
        .route("/health/live", get(live))
        .route("/health/ready", get(ready))
        .layer(RequestBodyLimitLayer::new(1024 * 1024))
        .layer(TimeoutLayer::with_status_code(
            StatusCode::GATEWAY_TIMEOUT,
            Duration::from_secs(15),
        ))
        .layer(TraceLayer::new_for_http());

    let bind = std::env::var("APP_BIND").unwrap_or_else(|_| "127.0.0.1:8080".to_owned());
    let listener = TcpListener::bind(&bind).await?;
    tracing::info!(%bind, "API started");
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}
