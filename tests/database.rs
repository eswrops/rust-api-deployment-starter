//! Database-layer behavior through the production pools: concurrent reads
//! and writes, duplicate-like idempotency, foreign-key enforcement, error
//! classification and persistence across pool reconnects.

use std::str::FromStr;

use rust_api::db::{Database, DbConfig};

async fn migrated_database(dir: &tempfile::TempDir) -> Database {
    let url = format!("sqlite://{}/app.db", dir.path().display());
    db_migrate(&url).await;
    Database::connect(&DbConfig {
        url,
        ..DbConfig::default()
    })
    .expect("connect pools")
}

async fn db_migrate(url: &str) {
    rust_api::db::apply_migrations(url)
        .await
        .expect("migrations");
}

async fn seed_user(db: &Database, id: i64, username: &str) {
    sqlx::query("INSERT INTO users (id, username) VALUES (?, ?)")
        .bind(id)
        .bind(username)
        .execute(&db.write)
        .await
        .unwrap();
}

#[tokio::test]
async fn concurrent_reads_and_writes_succeed() {
    let dir = tempfile::tempdir().unwrap();
    let db = migrated_database(&dir).await;
    seed_user(&db, 1, "writer").await;

    // Four concurrent writers on the single write connection plus four
    // concurrent readers on the read pool: WAL lets both proceed.
    let mut tasks = Vec::new();
    for n in 0..4 {
        let write = db.write.clone();
        let read = db.read.clone();
        tasks.push(tokio::spawn(async move {
            sqlx::query("INSERT INTO posts (user_id, body) VALUES (1, ?)")
                .bind(format!("concurrent post {n}"))
                .execute(&write)
                .await
                .expect("insert");
            let count: i64 = sqlx::query_scalar("SELECT count(*) FROM posts")
                .fetch_one(&read)
                .await
                .expect("read");
            count
        }));
    }
    for task in tasks {
        assert!(task.await.unwrap() >= 1, "readers must observe progress");
    }

    let total: i64 = sqlx::query_scalar("SELECT count(*) FROM posts")
        .fetch_one(&db.read)
        .await
        .unwrap();
    assert_eq!(total, 4);
    db.close().await;
}

#[tokio::test]
async fn duplicate_likes_are_idempotent() {
    let dir = tempfile::tempdir().unwrap();
    let db = migrated_database(&dir).await;
    seed_user(&db, 1, "liker").await;
    sqlx::query("INSERT INTO posts (id, user_id, body) VALUES (7, 1, 'likeable')")
        .execute(&db.write)
        .await
        .unwrap();

    let sql = "INSERT INTO likes (user_id, post_id) VALUES (1, 7) ON CONFLICT (user_id, post_id) DO NOTHING";
    let first = sqlx::query(sql).execute(&db.write).await.unwrap();
    assert_eq!(first.rows_affected(), 1, "first like inserts");
    let repeat = sqlx::query(sql).execute(&db.write).await.unwrap();
    assert_eq!(repeat.rows_affected(), 0, "repeat like is a no-op");

    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM likes WHERE post_id = 7")
        .fetch_one(&db.read)
        .await
        .unwrap();
    assert_eq!(count, 1);

    // foreign_keys=ON rejects a like for a missing post; the error classifies
    // as a constraint failure, not busy/locked.
    let missing = sqlx::query("INSERT INTO likes (user_id, post_id) VALUES (1, 424242)")
        .execute(&db.write)
        .await;
    let err = missing.expect_err("missing post must violate the foreign key");
    assert!(
        err.to_string().contains("FOREIGN KEY"),
        "unexpected error: {err}"
    );
    assert_eq!(rust_api::db::describe_db_error(&err), "other");
    db.close().await;
}

#[tokio::test]
async fn data_persists_across_pool_reconnects() {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite://{}/app.db", dir.path().display());
    db_migrate(&url).await;

    {
        let db = Database::connect(&DbConfig {
            url: url.clone(),
            ..DbConfig::default()
        })
        .unwrap();
        seed_user(&db, 1, "persistent").await;
        sqlx::query("INSERT INTO posts (user_id, body) VALUES (1, 'survives restarts')")
            .execute(&db.write)
            .await
            .unwrap();
        db.close().await;
    }

    let db = Database::connect(&DbConfig {
        url,
        ..DbConfig::default()
    })
    .unwrap();
    let bodies: Vec<String> = sqlx::query_scalar("SELECT body FROM posts ORDER BY id")
        .fetch_all(&db.read)
        .await
        .unwrap();
    assert_eq!(bodies, vec!["survives restarts".to_owned()]);
    db.close().await;
}

#[tokio::test]
async fn readiness_reflects_database_state() {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite://{}/app.db", dir.path().display());
    db_migrate(&url).await;
    let db = Database::connect(&DbConfig {
        url: url.clone(),
        ..DbConfig::default()
    })
    .unwrap();
    db.ready_check().await.expect("ready on a healthy database");
    db.close().await;

    // A missing file with create_if_missing(false) must fail readiness.
    let missing = Database::connect(&DbConfig {
        url: format!("sqlite://{}/nope/app.db", dir.path().display()),
        ..DbConfig::default()
    })
    .unwrap();
    assert!(
        missing.ready_check().await.is_err(),
        "missing database must not be ready"
    );
}

#[tokio::test]
async fn sqlite_urls_accept_absolute_paths() {
    // The documented production URL form must parse to the expected file.
    let options =
        sqlx::sqlite::SqliteConnectOptions::from_str("sqlite:///var/lib/rust-api/app.db").unwrap();
    assert_eq!(
        options.get_filename(),
        std::path::Path::new("/var/lib/rust-api/app.db")
    );
}
