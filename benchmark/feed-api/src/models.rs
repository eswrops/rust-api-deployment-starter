//! Wire models. Field declaration order is load-bearing: serde serializes
//! struct fields in order and the spec requires exact JSON key order.

use serde::{Deserialize, Serialize};
use sqlx::sqlite::SqliteRow;
use sqlx::{Error, FromRow, Row};

#[derive(Debug, Serialize)]
pub struct Post {
    pub id: i64,
    pub body: String,
    pub created_at: String,
    pub author: String,
    pub like_count: i64,
}

// Hand-written FromRow keeps the sqlx macro machinery out of the build.
impl<'r> FromRow<'r, SqliteRow> for Post {
    fn from_row(row: &'r SqliteRow) -> Result<Self, Error> {
        Ok(Self {
            id: row.try_get("id")?,
            body: row.try_get("body")?,
            created_at: row.try_get("created_at")?,
            author: row.try_get("author")?,
            like_count: row.try_get("like_count")?,
        })
    }
}

#[derive(Serialize)]
pub struct PostResponse {
    pub post: Post,
}

#[derive(Serialize)]
pub struct FeedResponse {
    pub posts: Vec<Post>,
}

#[derive(Serialize)]
pub struct HealthOk {
    pub status: &'static str,
    pub db: &'static str,
    pub uptime_s: u64,
}

#[derive(Serialize)]
pub struct HealthDegraded {
    pub status: &'static str,
    pub db: &'static str,
    pub error: String,
}

#[derive(Serialize)]
pub struct LikeResponse {
    pub liked: bool,
    pub already_liked: bool,
    pub post_id: i64,
}

#[derive(Deserialize)]
pub struct CreatePostRequest {
    pub body: String,
}

/// Columns returned by `INSERT ... RETURNING id, created_at`.
#[derive(Debug)]
pub struct InsertedPost {
    pub id: i64,
    pub created_at: String,
}

impl<'r> FromRow<'r, SqliteRow> for InsertedPost {
    fn from_row(row: &'r SqliteRow) -> Result<Self, Error> {
        Ok(Self {
            id: row.try_get("id")?,
            created_at: row.try_get("created_at")?,
        })
    }
}
