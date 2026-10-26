//! Migration validation: migrations apply cleanly, are idempotent, and
//! produce the documented schema. CI runs this file explicitly as the
//! migration gate in addition to the full `cargo test` pass.

use std::str::FromStr;

use rust_api::db;
use sqlx::Connection;

fn temp_db_url(dir: &tempfile::TempDir) -> String {
    format!("sqlite://{}/app.db", dir.path().display())
}

#[tokio::test]
async fn migrations_apply_and_are_idempotent() {
    let dir = tempfile::tempdir().unwrap();
    let url = temp_db_url(&dir);

    let applied_first = db::apply_migrations(&url)
        .await
        .expect("first migration run");
    assert!(
        applied_first >= 1,
        "expected at least one pending migration, got {applied_first}"
    );

    let applied_second = db::apply_migrations(&url)
        .await
        .expect("second migration run");
    assert_eq!(
        applied_second, 0,
        "re-running migrations must apply nothing"
    );
}

#[tokio::test]
async fn migrations_create_the_documented_schema() {
    let dir = tempfile::tempdir().unwrap();
    let url = temp_db_url(&dir);
    db::apply_migrations(&url).await.expect("migrations");

    let options = sqlx::sqlite::SqliteConnectOptions::from_str(&url).unwrap();
    let mut conn = sqlx::SqliteConnection::connect_with(&options)
        .await
        .unwrap();

    for table in ["users", "posts", "likes"] {
        let name: Option<String> =
            sqlx::query_scalar("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?")
                .bind(table)
                .fetch_optional(&mut conn)
                .await
                .unwrap();
        assert_eq!(name.as_deref(), Some(table), "table {table} must exist");
    }
    for index in [
        "posts_created_at_id_idx",
        "posts_user_id_idx",
        "likes_post_id_idx",
    ] {
        let name: Option<String> =
            sqlx::query_scalar("SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?")
                .bind(index)
                .fetch_optional(&mut conn)
                .await
                .unwrap();
        assert_eq!(name.as_deref(), Some(index), "index {index} must exist");
    }

    // WAL must be active on the migrated file (set at connect time).
    let mode: String = sqlx::query_scalar("PRAGMA journal_mode")
        .fetch_one(&mut conn)
        .await
        .unwrap();
    assert_eq!(mode.to_ascii_lowercase(), "wal");
    conn.close().await.unwrap();
}
