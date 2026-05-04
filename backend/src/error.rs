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

    #[error("device unregistered with apns")]
    DeviceGone,

    #[error("apns rejected request: {reason} ({status})")]
    ApnsRejected { status: u16, reason: String },

    #[error("apns transport error: {0}")]
    ApnsTransport(String),

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
            AppError::DeviceGone => (StatusCode::GONE, json!({"error": "device unregistered"})),
            AppError::ApnsRejected { status, reason } => {
                tracing::warn!(apns_status = status, apns_reason = %reason, "apns rejected push");
                (StatusCode::BAD_GATEWAY, json!({"error": "apns rejected", "apnsReason": reason}))
            }
            AppError::ApnsTransport(msg) => {
                tracing::error!(error = %msg, "apns transport error");
                (StatusCode::BAD_GATEWAY, json!({"error": "apns transport error"}))
            }
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
