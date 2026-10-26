//! Route handlers. SQL is kept in constants so sqlx's per-connection prepared
//! statement cache reuses one plan per query across requests.

use std::sync::{Arc, LazyLock};
use std::time::Instant;

use axum::{
    Json, Router,
    body::Bytes,
    extract::{DefaultBodyLimit, Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use sqlx::pool::PoolConnection;
use sqlx::sqlite::Sqlite;
use tower_http::trace::TraceLayer;

use crate::{
    AppState, auth,
    error::{ApiError, ApiResult},
    metrics,
    models::{
        CreatePostRequest, FeedResponse, HealthDegraded, HealthOk, InsertedPost, LikeResponse,
        Post, PostResponse,
    },
};

const POST_COLUMNS: &str = "p.id, p.body, p.created_at, u.username AS author, \
     (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count";

static FEED_SQL: LazyLock<String> = LazyLock::new(|| {
    format!(
        "SELECT {POST_COLUMNS} FROM posts p JOIN users u ON u.id = p.user_id \
         ORDER BY p.created_at DESC, p.id DESC LIMIT 20"
    )
});

static POST_BY_ID_SQL: LazyLock<String> = LazyLock::new(|| {
    format!("SELECT {POST_COLUMNS} FROM posts p JOIN users u ON u.id = p.user_id WHERE p.id = ?")
});

const INSERT_POST_SQL: &str =
    "INSERT INTO posts (user_id, body) VALUES (?, ?) RETURNING id, created_at";

const INSERT_LIKE_SQL: &str =
    "INSERT INTO likes (user_id, post_id) VALUES (?, ?) ON CONFLICT (user_id, post_id) DO NOTHING";

const POST_EXISTS_SQL: &str = "SELECT 1 FROM posts WHERE id = ?";

pub fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/feed", get(feed))
        .route("/posts/{id}", get(get_post))
        .route("/posts", post(create_post))
        .route("/posts/{id}/like", post(like_post))
        .fallback(not_found)
        .layer(DefaultBodyLimit::max(64 * 1024))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

/// Acquires a pooled connection, recording how long we had to wait. The pool
/// is bounded, so a saturated pool applies backpressure here instead of
/// queueing unboundedly.
async fn acquire(pool: &sqlx::SqlitePool) -> ApiResult<PoolConnection<Sqlite>> {
    let started = Instant::now();
    let conn = pool.acquire().await?;
    metrics::observe_acquire(started.elapsed());
    Ok(conn)
}

async fn health(State(state): State<Arc<AppState>>) -> Response {
    let started = Instant::now();
    let probe: Result<(), sqlx::Error> = async {
        let mut conn = state.read.acquire().await?;
        metrics::observe_acquire(started.elapsed());
        sqlx::query("SELECT 1")
            .execute(&mut *conn)
            .await
            .map(|_| ())
    }
    .await;
    match probe {
        Ok(()) => (
            StatusCode::OK,
            Json(HealthOk {
                status: "ok",
                db: "ok",
                uptime_s: state.started.elapsed().as_secs(),
            }),
        )
            .into_response(),
        Err(err) => {
            metrics::record_db_error(&err);
            tracing::warn!(error = %err, "health probe failed");
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(HealthDegraded {
                    status: "degraded",
                    db: "unreachable",
                    error: err.to_string(),
                }),
            )
                .into_response()
        }
    }
}

async fn feed(State(state): State<Arc<AppState>>) -> ApiResult<Response> {
    let mut conn = acquire(&state.read).await?;
    let posts: Vec<Post> = sqlx::query_as(&FEED_SQL).fetch_all(&mut *conn).await?;
    Ok((StatusCode::OK, Json(FeedResponse { posts })).into_response())
}

async fn get_post(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> ApiResult<Response> {
    let post_id = parse_post_id(&id)?;
    let mut conn = acquire(&state.read).await?;
    let post: Option<Post> = sqlx::query_as(&POST_BY_ID_SQL)
        .bind(post_id)
        .fetch_optional(&mut *conn)
        .await?;
    match post {
        Some(post) => Ok((StatusCode::OK, Json(PostResponse { post })).into_response()),
        None => Err(ApiError::PostNotFound),
    }
}

async fn create_post(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> ApiResult<Response> {
    // Auth first: a bad token must win over any body complaint.
    let claims = auth::authenticate(&headers, &state.secret)?;
    let raw = parse_create_body(&body)?;
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(ApiError::BodyRequired);
    }
    if trimmed.chars().count() > 500 {
        return Err(ApiError::BodyTooLong);
    }

    let mut conn = acquire(&state.write).await?;
    // fetch_all (not fetch_one) drives the statement to SQLITE_DONE, so the
    // autocommit commit is durable before the 201 goes out.
    let inserted: Vec<InsertedPost> = sqlx::query_as(INSERT_POST_SQL)
        .bind(claims.user_id)
        .bind(trimmed)
        .fetch_all(&mut *conn)
        .await?;
    let Some(InsertedPost { id, created_at }) = inserted.into_iter().next() else {
        return Err(ApiError::Internal);
    };

    let post = Post {
        id,
        body: trimmed.to_owned(),
        created_at,
        author: claims.username,
        like_count: 0,
    };
    Ok((StatusCode::CREATED, Json(PostResponse { post })).into_response())
}

async fn like_post(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> ApiResult<Response> {
    // Auth before id validation, per spec.
    let claims = auth::authenticate(&headers, &state.secret)?;
    let post_id = parse_post_id(&id)?;

    let mut conn = acquire(&state.write).await?;
    let inserted = sqlx::query(INSERT_LIKE_SQL)
        .bind(claims.user_id)
        .bind(post_id)
        .execute(&mut *conn)
        .await;
    match inserted {
        Ok(result) => {
            let already_liked = result.rows_affected() == 0;
            Ok((
                if already_liked {
                    StatusCode::OK
                } else {
                    StatusCode::CREATED
                },
                Json(LikeResponse {
                    liked: true,
                    already_liked,
                    post_id,
                }),
            )
                .into_response())
        }
        // foreign_keys=ON turns a missing post into a constraint failure; the
        // insert is a no-op write so we disambiguate with a cheap PK lookup.
        Err(err) if is_foreign_key_violation(&err) => {
            let exists: Option<i64> = sqlx::query_scalar(POST_EXISTS_SQL)
                .bind(post_id)
                .fetch_optional(&mut *conn)
                .await?;
            if exists.is_some() {
                // The post is there, so the violated reference was the token's user id.
                tracing::warn!(user_id = claims.user_id, "like from unknown user id");
                Err(ApiError::Internal)
            } else {
                Err(ApiError::PostNotFound)
            }
        }
        Err(err) => Err(err.into()),
    }
}

async fn not_found() -> ApiError {
    ApiError::NotFound
}

fn parse_post_id(raw: &str) -> Result<i64, ApiError> {
    raw.parse::<i64>()
        .ok()
        .filter(|id| *id > 0)
        .ok_or(ApiError::InvalidPostId)
}

fn parse_create_body(body: &Bytes) -> ApiResult<String> {
    match serde_json::from_slice::<CreatePostRequest>(body) {
        Ok(parsed) => Ok(parsed.body),
        Err(err) => Err(match err.classify() {
            serde_json::error::Category::Data => ApiError::BodyRequired,
            _ => ApiError::MalformedJsonBody,
        }),
    }
}

fn is_foreign_key_violation(err: &sqlx::Error) -> bool {
    err.as_database_error()
        .map(|db| {
            db.code().as_deref() == Some("787")
                || db.message().contains("FOREIGN KEY constraint failed")
        })
        .unwrap_or(false)
}
