//! Error type whose wire format is dictated by the challenge spec:
//! every error body is exactly `{"error":"<message>"}` with the documented
//! status code, and internal failures must never leak details into the body.

use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde::Serialize;

#[derive(Debug, PartialEq, Eq)]
pub enum ApiError {
    NotFound,
    InvalidPostId,
    PostNotFound,
    MissingBearerToken,
    InvalidToken,
    InvalidTokenPayload,
    MalformedJsonBody,
    BodyRequired,
    BodyTooLong,
    Internal,
}

impl ApiError {
    fn status(&self) -> StatusCode {
        match self {
            ApiError::NotFound => StatusCode::NOT_FOUND,
            ApiError::InvalidPostId => StatusCode::BAD_REQUEST,
            ApiError::PostNotFound => StatusCode::NOT_FOUND,
            ApiError::MissingBearerToken
            | ApiError::InvalidToken
            | ApiError::InvalidTokenPayload => StatusCode::UNAUTHORIZED,
            ApiError::MalformedJsonBody | ApiError::BodyRequired | ApiError::BodyTooLong => {
                StatusCode::BAD_REQUEST
            }
            ApiError::Internal => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }

    fn message(&self) -> &'static str {
        match self {
            ApiError::NotFound => "not found",
            ApiError::InvalidPostId => "invalid post id",
            ApiError::PostNotFound => "post not found",
            ApiError::MissingBearerToken => "missing bearer token",
            ApiError::InvalidToken => "invalid or expired token",
            ApiError::InvalidTokenPayload => "invalid token payload",
            ApiError::MalformedJsonBody => "malformed JSON body",
            ApiError::BodyRequired => "body is required",
            ApiError::BodyTooLong => "body must be at most 500 characters",
            ApiError::Internal => "internal server error",
        }
    }
}

#[derive(Serialize)]
struct ErrorBody<'a> {
    error: &'a str,
}

impl From<sqlx::Error> for ApiError {
    fn from(err: sqlx::Error) -> Self {
        crate::metrics::record_db_error(&err);
        tracing::warn!(error = %err, "sqlite error");
        ApiError::Internal
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        if self.status() == StatusCode::INTERNAL_SERVER_ERROR {
            tracing::error!(error = self.message(), "internal error response");
        }
        (
            self.status(),
            Json(ErrorBody {
                error: self.message(),
            }),
        )
            .into_response()
    }
}

pub type ApiResult<T> = Result<T, ApiError>;
