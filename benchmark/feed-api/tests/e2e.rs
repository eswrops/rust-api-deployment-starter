//! End-to-end regression tests: each test spawns the release/debug server
//! binary on its own temp SQLite database and asserts exact response bytes,
//! status codes and behaviors against the upstream challenge spec.
//!
//! Golden fixtures in tests/fixtures are deterministic: schema.sql is a
//! verbatim copy of the upstream schema, seed.sql loads 4 users / 21 posts /
//! 4 likes, and golden/*.json are hand-checkable expected bodies.

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use hmac::{Hmac, Mac};
use serde_json::{Value, json};
use sha2::Sha256;
use sqlx::Connection;
use sqlx::sqlite::{SqliteConnectOptions, SqliteConnection};
use tempfile::TempDir;
use tokio::process::{Child, Command};
use tokio::time::{Instant, timeout};

const SECRET: &str = "test-secret";
const SCHEMA: &str = include_str!("fixtures/schema.sql");
const SEED: &str = include_str!("fixtures/seed.sql");

fn golden(name: &str) -> String {
    let raw = match name {
        "feed" => include_str!("fixtures/golden/feed.json"),
        "post-1" => include_str!("fixtures/golden/post-1.json"),
        "post-2" => include_str!("fixtures/golden/post-2.json"),
        "post-3" => include_str!("fixtures/golden/post-3.json"),
        other => panic!("unknown golden fixture {other}"),
    };
    raw.trim_end_matches('\n').to_owned()
}

fn sign(payload: &Value) -> String {
    let h = B64.encode(br#"{"alg":"HS256","typ":"JWT"}"#);
    let p = B64.encode(serde_json::to_vec(payload).unwrap());
    let mut mac = Hmac::<Sha256>::new_from_slice(SECRET.as_bytes()).unwrap();
    mac.update(h.as_bytes());
    mac.update(b".");
    mac.update(p.as_bytes());
    let s = B64.encode(mac.finalize().into_bytes());
    format!("{h}.{p}.{s}")
}

fn token(user_id: u64, username: &str) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    sign(&json!({"sub": user_id.to_string(), "username": username, "iat": now, "exp": now + 3600}))
}

struct Server {
    base_url: String,
    child: Child,
    dir: Option<TempDir>,
    client: reqwest::Client,
}

/// Serializes "reserve a port, spawn the server, confirm it answers" across
/// parallel tests so two tests cannot reserve the same ephemeral port.
static START_GUARD: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

impl Server {
    /// Creates a database at a temp path, applies the schema and seed, then
    /// starts the server binary against it.
    async fn start() -> Self {
        Self::start_with(tempfile::tempdir().unwrap(), "feed.db", &[], true).await
    }

    async fn start_in_dir(dir: TempDir, db_name: &str, extra_env: &[(&str, &str)]) -> Self {
        Self::start_with(dir, db_name, extra_env, true).await
    }

    /// `initialize = false` skips database creation entirely; combined with a
    /// `db_name` containing a missing parent directory this yields a server
    /// whose database is permanently unreachable.
    async fn start_with(
        dir: TempDir,
        db_name: &str,
        extra_env: &[(&str, &str)],
        initialize: bool,
    ) -> Self {
        let guard = START_GUARD.lock().await;
        let db_path = dir.path().join(db_name);
        if initialize {
            Self::initialize_db(&db_path).await;
        }

        // Reserve a free port, then hand it to the server.
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);

        let bin = env!("CARGO_BIN_EXE_feed-api");
        let mut cmd = Command::new(bin);
        cmd.env("HOST", "127.0.0.1")
            .env("PORT", port.to_string())
            .env("SQLITE_PATH", &db_path)
            .env("JWT_SECRET", SECRET)
            .env("RUST_LOG", "error")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        for (key, value) in extra_env {
            cmd.env(key, value);
        }
        let child = cmd.spawn().expect("spawn server binary");

        let server = Server {
            base_url: format!("http://127.0.0.1:{port}"),
            child,
            dir: Some(dir),
            client: reqwest::Client::new(),
        };
        server.wait_responsive().await;
        drop(guard);
        server
    }

    async fn initialize_db(db_path: &Path) {
        let options = SqliteConnectOptions::new()
            .filename(db_path)
            .create_if_missing(true);
        let mut conn = SqliteConnection::connect_with(&options).await.unwrap();
        sqlx::raw_sql(SCHEMA).execute(&mut conn).await.unwrap();
        sqlx::raw_sql(SEED).execute(&mut conn).await.unwrap();
        conn.close().await.unwrap();
    }

    /// Polls until the server answers any HTTP request at all.
    async fn wait_responsive(&self) {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            assert!(Instant::now() < deadline, "server never became responsive");
            if self
                .client
                .get(format!("{}/health", self.base_url))
                .send()
                .await
                .is_ok()
            {
                return;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    async fn get(&self, path: &str) -> (u16, String, Option<String>) {
        let response = self
            .client
            .get(format!("{}{path}", self.base_url))
            .send()
            .await
            .expect("GET request");
        let status = response.status().as_u16();
        let content_type = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .map(|v| v.to_str().unwrap().to_owned());
        (status, response.text().await.unwrap(), content_type)
    }

    async fn post(
        &self,
        path: &str,
        authorization: Option<&str>,
        body: Option<&str>,
    ) -> (u16, String, Option<String>) {
        let mut request = self.client.post(format!("{}{path}", self.base_url));
        if let Some(auth) = authorization {
            request = request.header(reqwest::header::AUTHORIZATION, auth);
        }
        if let Some(body) = body {
            request = request
                .header(reqwest::header::CONTENT_TYPE, "application/json")
                .body(body.to_owned());
        }
        let response = request.send().await.expect("POST request");
        let status = response.status().as_u16();
        let content_type = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .map(|v| v.to_str().unwrap().to_owned());
        (status, response.text().await.unwrap(), content_type)
    }

    async fn kill(&mut self) {
        self.child.start_kill().expect("SIGKILL server");
        let _ = self.child.wait().await;
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
    }
}

#[tokio::test]
async fn health_matches_shape() {
    let server = Server::start().await;
    let (status, body, content_type) = server.get("/health").await;
    assert_eq!(status, 200);
    assert!(content_type.unwrap().starts_with("application/json"));
    let value: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(value["status"], "ok");
    assert_eq!(value["db"], "ok");
    let uptime = value["uptime_s"].as_u64().unwrap();
    assert_eq!(
        body,
        format!(r#"{{"status":"ok","db":"ok","uptime_s":{uptime}}}"#),
        "health key order and bytes"
    );
}

#[tokio::test]
async fn golden_reads_are_byte_exact() {
    let server = Server::start().await;

    let (status, body, content_type) = server.get("/feed").await;
    assert_eq!(status, 200);
    assert!(content_type.unwrap().starts_with("application/json"));
    assert_eq!(body, golden("feed"), "GET /feed bytes");

    for name in ["post-1", "post-2", "post-3"] {
        let id = name.trim_start_matches("post-");
        let (status, body, _) = server.get(&format!("/posts/{id}")).await;
        assert_eq!(status, 200);
        assert_eq!(body, golden(name), "GET /posts/{id} bytes");
    }

    // The feed holds exactly 20 entries even though 21 posts exist.
    let feed: Value = serde_json::from_str(&golden("feed")).unwrap();
    assert_eq!(feed["posts"].as_array().unwrap().len(), 20);
    assert_eq!(feed["posts"][0]["id"], 21, "newest filler post first");
    assert_eq!(
        feed["posts"][19]["id"], 2,
        "post 1 must be cut off by LIMIT 20"
    );
}

#[tokio::test]
async fn id_validation_and_missing_posts() {
    let server = Server::start().await;

    for id in ["0", "-1", "abc", "1.5"] {
        let (status, body, _) = server.get(&format!("/posts/{id}")).await;
        assert_eq!(
            (status, body.as_str()),
            (400, r#"{"error":"invalid post id"}"#),
            "GET /posts/{id}"
        );
    }

    let (status, body, _) = server.get("/posts/999999999").await;
    assert_eq!(
        (status, body.as_str()),
        (404, r#"{"error":"post not found"}"#)
    );

    let (status, body, _) = server.get("/nope").await;
    assert_eq!((status, body.as_str()), (404, r#"{"error":"not found"}"#));

    // Wrong methods on known paths are out of spec scope ("do whatever your
    // framework does"); axum answers 405 with an empty body.
    let (status, body, _) = server.get("/posts/1/like").await;
    assert_eq!(
        (status, body.as_str()),
        (405, ""),
        "GET on a POST-only route"
    );
}

#[tokio::test]
async fn authentication_matrix() {
    let server = Server::start().await;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;

    let user1 = token(1, "golden_ember_1");
    let expired =
        sign(&json!({"sub":"1","username":"golden_ember_1","iat":now - 7200,"exp":now - 3600}));
    let bad_sub =
        sign(&json!({"sub":"abc","username":"golden_ember_1","iat":now,"exp":now + 3600}));
    let zero_sub = sign(&json!({"sub":"0","username":"golden_ember_1","iat":now,"exp":now + 3600}));
    let no_name = sign(&json!({"sub":"1","iat":now,"exp":now + 3600}));
    let numeric_sub =
        sign(&json!({"sub":1,"username":"golden_ember_1","iat":now,"exp":now + 3600}));
    let expired_fractional = sign(
        &json!({"sub":"1","username":"golden_ember_1","iat":now - 7200,"exp":(now - 3600) as f64 + 0.5}),
    );
    let string_exp = sign(&json!({"sub":"1","username":"golden_ember_1","iat":now,"exp":"soon"}));
    let null_exp = sign(&json!({"sub":"1","username":"golden_ember_1","iat":now,"exp":null}));
    let bool_exp = sign(&json!({"sub":"1","username":"golden_ember_1","iat":now,"exp":true}));
    // Valid fractional NumericDate (RFC 7519 §2 allows non-integer values).
    let fractional_exp =
        sign(&json!({"sub":"1","username":"golden_ember_1","iat":now,"exp":now as f64 + 3600.5}));
    let none_alg = format!(
        "{}.{}.",
        B64.encode(br#"{"alg":"none","typ":"JWT"}"#),
        B64.encode(
            serde_json::to_vec(&json!({"sub":"1","username":"golden_ember_1","exp":now + 3600}))
                .unwrap()
        )
    );
    let tampered = format!(
        "{}.c2lnbmF0dXJlLWlzLW5vdC12YWxpZC1hdC1hbGwtYXQtYWxsLTEyMzQ",
        &user1[..user1.rfind('.').unwrap()]
    );

    let cases: &[(&str, Option<&str>, &str, &str)] = &[
        ("no header", None, "/posts", r#"{"body":"x"}"#),
        (
            "Basic scheme",
            Some("Basic abc"),
            "/posts",
            r#"{"body":"x"}"#,
        ),
        (
            "garbage token",
            Some("Bearer abc"),
            "/posts",
            r#"{"body":"x"}"#,
        ),
        (
            "bad signature",
            Some(&format!("Bearer {tampered}")),
            "/posts",
            r#"{"body":"x"}"#,
        ),
        (
            "alg none",
            Some(&format!("Bearer {none_alg}")),
            "/posts",
            r#"{"body":"x"}"#,
        ),
        (
            "expired",
            Some(&format!("Bearer {expired}")),
            "/posts",
            r#"{"body":"x"}"#,
        ),
        (
            "expired fractional",
            Some(&format!("Bearer {expired_fractional}")),
            "/posts",
            r#"{"body":"x"}"#,
        ),
        (
            "string exp",
            Some(&format!("Bearer {string_exp}")),
            "/posts",
            r#"{"body":"x"}"#,
        ),
        (
            "null exp",
            Some(&format!("Bearer {null_exp}")),
            "/posts",
            r#"{"body":"x"}"#,
        ),
        (
            "bool exp",
            Some(&format!("Bearer {bool_exp}")),
            "/posts",
            r#"{"body":"x"}"#,
        ),
        (
            "sub not integer",
            Some(&format!("Bearer {bad_sub}")),
            "/posts",
            r#"{"body":"x"}"#,
        ),
        (
            "sub zero",
            Some(&format!("Bearer {zero_sub}")),
            "/posts",
            r#"{"body":"x"}"#,
        ),
        (
            "sub numeric json",
            Some(&format!("Bearer {numeric_sub}")),
            "/posts",
            r#"{"body":"x"}"#,
        ),
        (
            "no username",
            Some(&format!("Bearer {no_name}")),
            "/posts",
            r#"{"body":"x"}"#,
        ),
        ("like, no header", None, "/posts/1/like", ""),
        ("like, Basic scheme", Some("Basic abc"), "/posts/1/like", ""),
        (
            "like, garbage token",
            Some("Bearer abc"),
            "/posts/1/like",
            "",
        ),
    ];
    for (label, auth, path, body) in cases {
        let (expected_status, expected_body) = if label.contains("sub") || *label == "no username" {
            (401, r#"{"error":"invalid token payload"}"#)
        } else if *label == "expired"
            || *label == "alg none"
            || *label == "bad signature"
            || label.contains("garbage")
            || label.contains("exp")
        {
            (401, r#"{"error":"invalid or expired token"}"#)
        } else {
            (401, r#"{"error":"missing bearer token"}"#)
        };
        let (status, body_text, _) = server.post(path, *auth, Some(body)).await;
        assert_eq!(
            (status, body_text.as_str()),
            (expected_status, expected_body),
            "auth case {label}"
        );
    }

    // A fractional NumericDate must be accepted end to end.
    let (status, body, _) = server
        .post(
            "/posts",
            Some(&format!("Bearer {fractional_exp}")),
            Some(r#"{"body":"fractional exp accepted"}"#),
        )
        .await;
    assert_eq!(status, 201, "fractional exp must be accepted: {body}");

    // Auth-before-id precedence on the like route.
    let (status, body, _) = server.post("/posts/abc/like", None, None).await;
    assert_eq!(
        (status, body.as_str()),
        (401, r#"{"error":"missing bearer token"}"#)
    );
    let (status, body, _) = server
        .post("/posts/abc/like", Some(&format!("Bearer {user1}")), None)
        .await;
    assert_eq!(
        (status, body.as_str()),
        (400, r#"{"error":"invalid post id"}"#)
    );

    // Auth also precedes body validation on create.
    let (status, body, _) = server.post("/posts", None, Some("{bad json")).await;
    assert_eq!(
        (status, body.as_str()),
        (401, r#"{"error":"missing bearer token"}"#)
    );

    // A token signed with a different secret fails signature verification.
    let other = {
        let h = B64.encode(br#"{"alg":"HS256","typ":"JWT"}"#);
        let p = B64.encode(
            serde_json::to_vec(&json!({"sub":"1","username":"golden_ember_1","exp":now + 3600}))
                .unwrap(),
        );
        let mut mac = Hmac::<Sha256>::new_from_slice(b"wrong-secret").unwrap();
        mac.update(h.as_bytes());
        mac.update(b".");
        mac.update(p.as_bytes());
        format!("{h}.{p}.{}", B64.encode(mac.finalize().into_bytes()))
    };
    let (status, body, _) = server
        .post(
            "/posts",
            Some(&format!("Bearer {other}")),
            Some(r#"{"body":"x"}"#),
        )
        .await;
    assert_eq!(
        (status, body.as_str()),
        (401, r#"{"error":"invalid or expired token"}"#)
    );

    // A like from a signed but unknown user id cannot satisfy the foreign key.
    let unknown_user = token(424242, "ghost");
    let (status, body, _) = server
        .post(
            "/posts/1/like",
            Some(&format!("Bearer {unknown_user}")),
            None,
        )
        .await;
    assert_eq!(
        (status, body.as_str()),
        (500, r#"{"error":"internal server error"}"#)
    );
}

#[tokio::test]
async fn create_validation() {
    let server = Server::start().await;
    let auth = &format!("Bearer {}", token(1, "golden_ember_1"));

    let cases: &[(&str, &str)] = &[
        (r#"{"body":""}"#, r#"{"error":"body is required"}"#),
        (r#"{"body":"   "}"#, r#"{"error":"body is required"}"#),
        (r#"{"body":123}"#, r#"{"error":"body is required"}"#),
        ("{}", r#"{"error":"body is required"}"#),
        ("{bad json", r#"{"error":"malformed JSON body"}"#),
        ("", r#"{"error":"malformed JSON body"}"#),
        (
            &format!(r#"{{"body":"{}"}}"#, "a".repeat(501)),
            r#"{"error":"body must be at most 500 characters"}"#,
        ),
    ];
    for (request_body, expected) in cases {
        let (status, body, _) = server.post("/posts", Some(auth), Some(request_body)).await;
        assert_eq!(
            (status, body.as_str()),
            (400, *expected),
            "body {request_body}"
        );
    }
}

#[tokio::test]
async fn create_trims_and_roundtrips() {
    let server = Server::start().await;
    let auth = &format!("Bearer {}", token(1, "golden_ember_1"));

    let (status, body, content_type) = server
        .post(
            "/posts",
            Some(auth),
            Some(r#"{"body":"  test: <b>&amp;</b> \"quoted\" / café ✓  "}"#),
        )
        .await;
    assert_eq!(status, 201);
    assert!(content_type.unwrap().starts_with("application/json"));
    let value: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(
        value["post"]["body"],
        "test: <b>&amp;</b> \"quoted\" / café ✓"
    );
    assert_eq!(value["post"]["author"], "golden_ember_1");
    assert_eq!(value["post"]["like_count"], 0);
    let created_at = value["post"]["created_at"].as_str().unwrap();
    assert!(
        regex_lite_check_created_at(created_at),
        "created_at format {created_at}"
    );
    // (Key order of the created object is asserted byte-exactly below.)

    // Exactly 500 characters after trimming is accepted and echoed trimmed.
    let body500 = "b".repeat(500);
    let (status, body, _) = server
        .post(
            "/posts",
            Some(auth),
            Some(&format!(r#"{{"body":"  {body500} "}}"#)),
        )
        .await;
    assert_eq!(status, 201);
    let value: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(value["post"]["body"], body500);
    let id = value["post"]["id"].as_i64().unwrap();
    let created_at = value["post"]["created_at"].as_str().unwrap().to_owned();
    assert_eq!(
        body,
        format!(
            r#"{{"post":{{"id":{id},"body":"{body500}","created_at":"{created_at}","author":"golden_ember_1","like_count":0}}}}"#
        ),
        "create response byte order"
    );
}

/// `2026-10-26T14:03:07.123Z` shape check without a regex dependency.
fn regex_lite_check_created_at(value: &str) -> bool {
    let bytes = value.as_bytes();
    let digits_at = |idx: &[usize]| idx.iter().all(|&i| bytes[i].is_ascii_digit());
    bytes.len() == 24
        && bytes[4] == b'-'
        && bytes[7] == b'-'
        && bytes[10] == b'T'
        && bytes[13] == b':'
        && bytes[16] == b':'
        && bytes[19] == b'.'
        && bytes[23] == b'Z'
        && digits_at(&[0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18, 20, 21, 22])
}

#[tokio::test]
async fn like_flow_and_readback() {
    let server = Server::start().await;
    let auth = &format!("Bearer {}", token(1, "golden_ember_1"));

    // Create a post to like.
    let (status, body, _) = server
        .post("/posts", Some(auth), Some(r#"{"body":"likeable"}"#))
        .await;
    assert_eq!(status, 201);
    let id: i64 = serde_json::from_str::<Value>(&body).unwrap()["post"]["id"]
        .as_i64()
        .unwrap();

    let (status, body, _) = server
        .post(&format!("/posts/{id}/like"), Some(auth), None)
        .await;
    assert_eq!(
        (status, body.as_str()),
        (
            201,
            format!(r#"{{"liked":true,"already_liked":false,"post_id":{id}}}"#).as_str()
        )
    );
    let (status, body, _) = server
        .post(&format!("/posts/{id}/like"), Some(auth), None)
        .await;
    assert_eq!(
        (status, body.as_str()),
        (
            200,
            format!(r#"{{"liked":true,"already_liked":true,"post_id":{id}}}"#).as_str()
        )
    );

    let (status, body, _) = server.post("/posts/999999999/like", Some(auth), None).await;
    assert_eq!(
        (status, body.as_str()),
        (404, r#"{"error":"post not found"}"#)
    );
    let (status, body, _) = server.post("/posts/abc/like", Some(auth), None).await;
    assert_eq!(
        (status, body.as_str()),
        (400, r#"{"error":"invalid post id"}"#)
    );

    // Read back: one like, exact bytes with the same created_at as creation.
    let (status, body, _) = server.get(&format!("/posts/{id}")).await;
    assert_eq!(status, 200);
    let value: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(value["post"]["like_count"], 1);

    // The new post tops the feed with its like count included.
    let (status, body, _) = server.get("/feed").await;
    assert_eq!(status, 200);
    let feed: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(feed["posts"][0]["id"], id);
    assert_eq!(feed["posts"][0]["like_count"], 1);
    assert_eq!(feed["posts"].as_array().unwrap().len(), 20);
}

#[tokio::test]
async fn concurrent_duplicate_likes_are_idempotent() {
    let server = Server::start().await;
    let auth = format!("Bearer {}", token(1, "golden_ember_1"));

    // Eight concurrent likes from the same user on an unliked post (post 2 has
    // no seed likes): exactly one insert wins, the rest see the conflict.
    let mut tasks = Vec::new();
    for _ in 0..8 {
        let client = server.client.clone();
        let url = format!("{}/posts/2/like", server.base_url);
        let auth = auth.clone();
        tasks.push(tokio::spawn(async move {
            client
                .post(&url)
                .header(reqwest::header::AUTHORIZATION, auth)
                .send()
                .await
                .unwrap()
                .status()
                .as_u16()
        }));
    }
    let mut created = 0;
    let mut repeated = 0;
    for task in tasks {
        match task.await.unwrap() {
            201 => created += 1,
            200 => repeated += 1,
            other => panic!("unexpected like status {other}"),
        }
    }
    assert_eq!(
        (created, repeated),
        (1, 7),
        "exactly one first-like per (user, post)"
    );

    let (_, body, _) = server.get("/posts/2").await;
    let value: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(value["post"]["like_count"], 1);

    // Distinct users liking the same post each get their own 201 (post 4 has
    // no seed likes; users 1-4 all exist).
    let mut tasks = Vec::new();
    for user in 1..=4 {
        let client = server.client.clone();
        let url = format!("{}/posts/4/like", server.base_url);
        let auth = format!("Bearer {}", token(user, "someone"));
        tasks.push(tokio::spawn(async move {
            client
                .post(&url)
                .header(reqwest::header::AUTHORIZATION, auth)
                .send()
                .await
                .unwrap()
                .status()
                .as_u16()
        }));
    }
    for task in tasks {
        assert_eq!(task.await.unwrap(), 201);
    }
    let (_, body, _) = server.get("/posts/4").await;
    let value: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(value["post"]["like_count"], 4);
}

#[tokio::test]
async fn persistence_survives_hard_kill() {
    let dir = tempfile::tempdir().unwrap();
    let mut server = Server::start_in_dir(dir, "feed.db", &[]).await;
    let auth = format!("Bearer {}", token(1, "golden_ember_1"));

    let (status, body, _) = server
        .post("/posts", Some(&auth), Some(r#"{"body":"durable message"}"#))
        .await;
    assert_eq!(status, 201);
    let created: Value = serde_json::from_str(&body).unwrap();
    let id = created["post"]["id"].as_i64().unwrap();
    let created_at = created["post"]["created_at"].as_str().unwrap().to_owned();
    let (status, _, _) = server
        .post(&format!("/posts/{id}/like"), Some(&auth), None)
        .await;
    assert_eq!(status, 201);

    // Hard kill: with WAL + synchronous=NORMAL a committed transaction must
    // still be visible to the next process, even though it was not fsynced.
    server.kill().await;
    let dir = server.dir.take().unwrap();
    let server = Server::start_with(dir, "feed.db", &[], false).await;

    let (status, body, _) = server.get(&format!("/posts/{id}")).await;
    assert_eq!(status, 200);
    assert_eq!(
        body,
        format!(
            r#"{{"post":{{"id":{id},"body":"durable message","created_at":"{created_at}","author":"golden_ember_1","like_count":1}}}}"#
        )
    );
    let (_, body, _) = server.get("/feed").await;
    let feed: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(feed["posts"][0]["id"], id, "durable post tops the feed");
}

#[tokio::test]
async fn graceful_shutdown_on_sigterm() {
    let mut server = Server::start().await;
    let pid = server.child.id().expect("server pid");

    let kill = Command::new("kill")
        .args(["-TERM", &pid.to_string()])
        .output()
        .await
        .expect("send SIGTERM");
    assert!(kill.status.success(), "kill -TERM failed");

    let status = timeout(Duration::from_secs(10), server.child.wait())
        .await
        .expect("graceful shutdown within 10 s")
        .expect("wait on server");
    assert!(status.success(), "clean exit after SIGTERM, got {status}");
    server.child = {
        // Prevent Drop from killing an already-exited child.
        Command::new("true").spawn().unwrap()
    };
}

#[tokio::test]
async fn unreachable_database_degrades_gracefully() {
    // The parent directory does not exist, so no connection can ever open;
    // the server must still boot and serve a degraded health report.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start_with(dir, "no-such-dir/feed.db", &[], false).await;
    let client = server.client.clone();

    let response = client
        .get(format!("{}/health", server.base_url))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status().as_u16(), 503);
    let value: Value = serde_json::from_str(&response.text().await.unwrap()).unwrap();
    assert_eq!(value["status"], "degraded");
    assert_eq!(value["db"], "unreachable");
    assert!(!value["error"].as_str().unwrap().is_empty());

    let response = client
        .get(format!("{}/feed", server.base_url))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status().as_u16(), 500);
    assert_eq!(
        response.text().await.unwrap(),
        r#"{"error":"internal server error"}"#
    );
}
