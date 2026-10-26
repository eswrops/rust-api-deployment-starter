//! Service-level tests: they run the actual `rust-api` binary — the migrate
//! subcommand, the two health endpoints, graceful shutdown, database
//! unavailability, and persistence across application restarts.

use std::process::Stdio;
use std::time::Duration;

use tempfile::TempDir;
use tokio::process::{Child, Command};
use tokio::time::Instant;

const BIN: &str = env!("CARGO_BIN_EXE_rust-api");

struct Server {
    base_url: String,
    child: Child,
    dir: Option<TempDir>,
}

fn free_port() -> u16 {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    port
}

/// Serializes "reserve a port, spawn the server, confirm it answers" across
/// parallel tests: two tests could otherwise reserve the same ephemeral port
/// between dropping the probe listener and the server binding it.
static START_GUARD: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

async fn run_migrate(dir: &TempDir) -> std::process::Output {
    Command::new(BIN)
        .arg("migrate")
        .env(
            "DATABASE_URL",
            format!("sqlite://{}/app.db", dir.path().display()),
        )
        .env("RUST_LOG", "error")
        .output()
        .await
        .expect("run rust-api migrate")
}

async fn start_server(dir: TempDir, db_name: &str) -> Server {
    let guard = START_GUARD.lock().await;
    let port = free_port();
    let child = Command::new(BIN)
        .env("APP_BIND", format!("127.0.0.1:{port}"))
        .env(
            "DATABASE_URL",
            format!("sqlite://{}/{db_name}", dir.path().display()),
        )
        .env("RUST_LOG", "error")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .expect("spawn rust-api");
    let server = Server {
        base_url: format!("http://127.0.0.1:{port}"),
        child,
        dir: Some(dir),
    };
    server.wait_responsive().await;
    drop(guard);
    server
}

impl Server {
    async fn wait_responsive(&self) {
        let client = reqwest::Client::new();
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            assert!(Instant::now() < deadline, "server never became responsive");
            if client
                .get(format!("{}/health/live", self.base_url))
                .send()
                .await
                .is_ok()
            {
                return;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    async fn get(&self, path: &str) -> (u16, String) {
        let response = reqwest::Client::new()
            .get(format!("{}{path}", self.base_url))
            .send()
            .await
            .expect("GET");
        (response.status().as_u16(), response.text().await.unwrap())
    }

    async fn terminate(mut self) -> std::process::ExitStatus {
        let pid = self.child.id().expect("server pid");
        Command::new("kill")
            .args(["-TERM", &pid.to_string()])
            .output()
            .await
            .expect("send SIGTERM");
        timeout_wait(self.child.wait()).await
    }
}

async fn timeout_wait(
    wait: impl std::future::Future<Output = Result<std::process::ExitStatus, std::io::Error>>,
) -> std::process::ExitStatus {
    tokio::time::timeout(Duration::from_secs(15), wait)
        .await
        .expect("process exited within 15 s")
        .expect("wait")
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
    }
}

#[tokio::test]
async fn migrate_subcommand_prepares_the_database() {
    let dir = tempfile::tempdir().unwrap();
    let output = run_migrate(&dir).await;
    assert!(
        output.status.success(),
        "migrate must succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("1 pending migration"), "stdout: {stdout}");
    assert!(
        dir.path().join("app.db").exists(),
        "database file must be created"
    );

    let output = run_migrate(&dir).await;
    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("0 pending migration"),
        "second run: {stdout}"
    );
}

#[tokio::test]
async fn live_and_ready_report_health_and_sigterm_shuts_down_cleanly() {
    let dir = tempfile::tempdir().unwrap();
    assert!(run_migrate(&dir).await.status.success());
    let server = start_server(dir, "app.db").await;

    let (status, body) = server.get("/health/live").await;
    assert_eq!(status, 200);
    assert_eq!(body, r#"{"status":"ok","version":"dev"}"#);

    let (status, body) = server.get("/health/ready").await;
    assert_eq!(status, 200);
    assert_eq!(body, r#"{"status":"ok","version":"dev"}"#);

    let status = server.terminate().await;
    assert!(status.success(), "clean exit after SIGTERM, got {status}");
}

#[tokio::test]
async fn unreachable_database_degrades_readiness_but_not_liveness() {
    let dir = tempfile::tempdir().unwrap();
    // No migration ran, and the parent directory does not exist either.
    let server = start_server(dir, "missing/app.db").await;

    let (status, body) = server.get("/health/live").await;
    assert_eq!(
        (status, body.as_str()),
        (200, r#"{"status":"ok","version":"dev"}"#)
    );

    let (status, body) = server.get("/health/ready").await;
    assert_eq!(status, 503);
    let value: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(value["status"], "degraded");
    assert!(!value["error"].as_str().unwrap().is_empty());
}

#[tokio::test]
async fn data_persists_across_application_restarts() {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite://{}/app.db", dir.path().display());
    assert!(run_migrate(&dir).await.status.success());

    // First run: healthy.
    let mut server = start_server(dir, "app.db").await;
    let (status, _) = server.get("/health/ready").await;
    assert_eq!(status, 200);
    let _dir = server.dir.take().unwrap();
    server.terminate().await;

    // Between runs, a writer commits data.
    {
        let database = rust_api::db::Database::connect(&rust_api::db::DbConfig {
            url: url.clone(),
            ..rust_api::db::DbConfig::default()
        })
        .unwrap();
        sqlx::query("INSERT INTO users (id, username) VALUES (1, 'restarter')")
            .execute(&database.write)
            .await
            .unwrap();
        database.close().await;
    }

    // Second run on the same database file: still healthy, data intact.
    let port = free_port();
    let child = Command::new(BIN)
        .env("APP_BIND", format!("127.0.0.1:{port}"))
        .env("DATABASE_URL", &url)
        .env("RUST_LOG", "error")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let base = format!("http://127.0.0.1:{port}");
    let client = reqwest::Client::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        assert!(
            Instant::now() < deadline,
            "restarted server never became responsive"
        );
        match client.get(format!("{base}/health/ready")).send().await {
            Ok(response) if response.status().as_u16() == 200 => break,
            _ => tokio::time::sleep(Duration::from_millis(50)).await,
        }
    }

    let database = rust_api::db::Database::connect(&rust_api::db::DbConfig {
        url,
        ..rust_api::db::DbConfig::default()
    })
    .unwrap();
    let usernames: Vec<String> = sqlx::query_scalar("SELECT username FROM users")
        .fetch_all(&database.read)
        .await
        .unwrap();
    assert_eq!(usernames, vec!["restarter".to_owned()]);
    database.close().await;
    drop(child);
}
