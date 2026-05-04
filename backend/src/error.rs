use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;

#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("not found")]
    NotFound,

    #[error("bad request: {0}")]
    BadRequest(String),

    #[error("rate limited")]
    RateLimited,

    #[error("monthly quota exceeded")]
    QuotaExceeded,

    #[error(transparent)]
    Sqlx(#[from] sqlx::Error),

    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, body) = match &self {
            AppError::NotFound => (StatusCode::NOT_FOUND, json!({"error": "not found"})),
            AppError::BadRequest(msg) => (StatusCode::BAD_REQUEST, json!({"error": msg})),
            AppError::RateLimited => (
                StatusCode::TOO_MANY_REQUESTS,
                json!({"error": "rate limited"}),
            ),
            AppError::QuotaExceeded => (
                StatusCode::TOO_MANY_REQUESTS,
                json!({"error": "monthly quota exceeded"}),
            ),
            AppError::Sqlx(e) => {
                tracing::error!(error = %e, "database error");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    json!({"error": "internal server error"}),
                )
            }
            AppError::Other(e) => {
                tracing::error!(error = %e, "unhandled error");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    json!({"error": "internal server error"}),
                )
            }
        };
        (status, Json(body)).into_response()
    }
}

pub type AppResult<T> = Result<T, AppError>;
