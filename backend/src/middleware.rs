//! Bearer-userId auth middleware for `/v1/*` REST endpoints.
//!
//! See ADR-0019: every non-webhook endpoint authenticates via
//! `Authorization: Bearer <userId>`. The userId IS the bearer token —
//! same secret, same trust model, just in a header instead of a path.
//!
//! This middleware only validates that the token corresponds to a real
//! user; handlers that also have a `:user_id` path parameter must
//! additionally verify it equals the bearer token (axum 0.7 does not
//! expose path params from middleware).

use axum::extract::State;
use axum::http::{header, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use axum::Json;
use once_cell::sync::Lazy;
use regex::Regex;
use serde_json::json;

use crate::AppState;

/// Verified userId extracted by `require_bearer`. Handlers receive this
/// via `axum::Extension<BearerUser>` once the middleware has confirmed
/// the token format and that the user exists.
#[derive(Debug, Clone)]
pub struct BearerUser(pub String);

static USER_ID_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^[A-Za-z0-9]{32}$").expect("valid user-id regex"));

/// Authorization: Bearer <userId>
///
/// On success, stores the verified `BearerUser` in request extensions
/// for downstream extractors. On failure, returns 401 Unauthorized
/// without disclosing which check failed (per ADR-0019: every auth
/// failure is the same opaque 401).
pub async fn require_bearer(
    State(state): State<AppState>,
    mut req: axum::extract::Request,
    next: Next,
) -> Response {
    let auth_header = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok());

    let token = match auth_header.and_then(parse_bearer) {
        Some(t) => t,
        None => {
            tracing::warn!("auth: missing or malformed Authorization header");
            return unauthorized();
        }
    };

    if !USER_ID_RE.is_match(token) {
        tracing::warn!(
            token_prefix = %short_token(token),
            "auth: bearer token failed format check"
        );
        return unauthorized();
    }

    let exists: Option<i64> = match sqlx::query_scalar("SELECT 1 FROM users WHERE id = ?")
        .bind(token)
        .fetch_optional(&state.db)
        .await
    {
        Ok(v) => v,
        Err(err) => {
            tracing::error!(error = %err, "auth: db lookup failed");
            return unauthorized();
        }
    };

    if exists.is_none() {
        tracing::warn!(
            token_prefix = %short_token(token),
            "auth: bearer token does not match any user"
        );
        return unauthorized();
    }

    let user_id = token.to_owned();
    tracing::debug!(
        user_id_prefix = %short_token(&user_id),
        "auth: bearer accepted"
    );

    req.extensions_mut().insert(BearerUser(user_id));
    next.run(req).await
}

fn parse_bearer(header_value: &str) -> Option<&str> {
    let trimmed = header_value.trim();
    let rest = trimmed.strip_prefix("Bearer")?;
    let token = rest.trim_start();
    if token.is_empty() || token == rest {
        // Either no whitespace after "Bearer" or empty token.
        return None;
    }
    Some(token)
}

fn unauthorized() -> Response {
    (
        StatusCode::UNAUTHORIZED,
        Json(json!({"error": "unauthorized"})),
    )
        .into_response()
}

fn short_token(token: &str) -> &str {
    let end = token
        .char_indices()
        .nth(8)
        .map(|(i, _)| i)
        .unwrap_or(token.len());
    &token[..end]
}
