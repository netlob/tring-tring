//! `DELETE /v1/users/:user_id/submittedNotifications/:external_id`
//!
//! Cancel-or-acknowledge endpoint per ADR-0014. The handler asks the
//! scheduler to flip a `pending` row to `cancelled`; if the scheduler
//! reports no pending row, we look at `notifications_log` for the same
//! identifier — if a row exists, it has already been delivered (Pushcut
//! semantic: 200 with `already_delivered`); otherwise the identifier
//! is unknown for this user, which we report as 404 regardless of
//! whether the identifier exists for a different user (cross-user
//! opacity rule from ADR-0014).

use axum::extract::{Path, State};
use axum::{Extension, Json};
use once_cell::sync::Lazy;
use regex::Regex;
use serde::Serialize;

use crate::error::{AppError, AppResult};
use crate::middleware::BearerUser;
use crate::AppState;

// Same character class as ADR-0011 names; identifiers are validated
// independently per ADR-0014 even though the regex coincides.
static EXTERNAL_ID_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^[A-Za-z0-9._-]{1,64}$").expect("valid external-id regex"));

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CancelResponse {
    pub status: &'static str,
    pub external_id: String,
}

#[tracing::instrument(
    skip(state, bearer, external_id),
    fields(user_id_prefix = %short_id(&user_id))
)]
pub async fn cancel_submitted(
    State(state): State<AppState>,
    Path((user_id, external_id)): Path<(String, String)>,
    Extension(bearer): Extension<BearerUser>,
) -> AppResult<Json<CancelResponse>> {
    if bearer.0 != user_id {
        return Err(AppError::Forbidden("token user mismatch".into()));
    }

    if !EXTERNAL_ID_RE.is_match(&external_id) {
        return Err(AppError::BadRequest("invalid identifier".into()));
    }

    let cancelled =
        crate::scheduler::cancel_by_external_id(&state.db, &user_id, &external_id).await?;

    if cancelled {
        tracing::info!("submitted notification cancelled");
        return Ok(Json(CancelResponse {
            status: "cancelled",
            external_id,
        }));
    }

    let already_logged: Option<i64> = sqlx::query_scalar(
        "SELECT id FROM notifications_log \
         WHERE user_id = ? AND external_id = ? \
         LIMIT 1",
    )
    .bind(&user_id)
    .bind(&external_id)
    .fetch_optional(&state.db)
    .await?;

    if already_logged.is_some() {
        tracing::info!("cancel target already delivered");
        return Ok(Json(CancelResponse {
            status: "already_delivered",
            external_id,
        }));
    }

    tracing::info!("cancel target unknown for user");
    Err(AppError::NotFound)
}

fn short_id(id: &str) -> &str {
    let end = id.char_indices().nth(8).map(|(i, _)| i).unwrap_or(id.len());
    &id[..end]
}
