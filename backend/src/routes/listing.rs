//! `GET /v1/users/:user_id/notifications` — paginated notification log.
//!
//! Bearer-userId auth (ADR-0019). The path `user_id` and the bearer
//! token must match exactly; mismatch is treated as forbidden.
//!
//! Pagination is by descending `notifications_log.id` (a monotonic
//! `INTEGER PRIMARY KEY AUTOINCREMENT`). The `before` cursor is the id
//! of the last row in the prior page; absent → newest page. This is
//! more stable than offset under concurrent insertions and is bounded
//! at 200 rows per call (`LIMIT min(limit, 200)`).

use axum::extract::{Path, Query, State};
use axum::{Extension, Json};
use serde::{Deserialize, Serialize};

use crate::error::{AppError, AppResult};
use crate::middleware::BearerUser;
use crate::AppState;

const DEFAULT_LIMIT: u32 = 50;
const MAX_LIMIT: u32 = 200;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListQuery {
    #[serde(default)]
    pub limit: Option<u32>,
    #[serde(default)]
    pub before: Option<i64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LogRow {
    pub id: i64,
    pub name: Option<String>,
    pub external_id: Option<String>,
    pub status: String,
    pub apns_status: Option<i64>,
    pub apns_reason: Option<String>,
    pub sent_at: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ListResponse {
    pub notifications: Vec<LogRow>,
    pub next_before: Option<i64>,
}

#[tracing::instrument(
    skip(state, bearer),
    fields(user_id_prefix = %short_id(&user_id))
)]
pub async fn list_notifications(
    State(state): State<AppState>,
    Path(user_id): Path<String>,
    Query(q): Query<ListQuery>,
    Extension(bearer): Extension<BearerUser>,
) -> AppResult<Json<ListResponse>> {
    if bearer.0 != user_id {
        return Err(AppError::Forbidden("token user mismatch".into()));
    }

    let limit = q.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);

    let rows: Vec<LogRow> = if let Some(before) = q.before {
        sqlx::query_as::<_, LogRow>(
            "SELECT id, name, external_id, status, apns_status, apns_reason, sent_at \
             FROM notifications_log \
             WHERE user_id = ? AND id < ? \
             ORDER BY id DESC \
             LIMIT ?",
        )
        .bind(&user_id)
        .bind(before)
        .bind(limit as i64)
        .fetch_all(&state.db)
        .await?
    } else {
        sqlx::query_as::<_, LogRow>(
            "SELECT id, name, external_id, status, apns_status, apns_reason, sent_at \
             FROM notifications_log \
             WHERE user_id = ? \
             ORDER BY id DESC \
             LIMIT ?",
        )
        .bind(&user_id)
        .bind(limit as i64)
        .fetch_all(&state.db)
        .await?
    };

    let next_before = if rows.len() as u32 == limit {
        rows.last().map(|r| r.id)
    } else {
        None
    };

    tracing::info!(count = rows.len(), "notifications listed");

    Ok(Json(ListResponse {
        notifications: rows,
        next_before,
    }))
}

impl<'r> sqlx::FromRow<'r, sqlx::sqlite::SqliteRow> for LogRow {
    fn from_row(row: &'r sqlx::sqlite::SqliteRow) -> sqlx::Result<Self> {
        use sqlx::Row;
        Ok(LogRow {
            id: row.try_get("id")?,
            name: row.try_get("name")?,
            external_id: row.try_get("external_id")?,
            status: row.try_get("status")?,
            apns_status: row.try_get("apns_status")?,
            apns_reason: row.try_get("apns_reason")?,
            sent_at: row.try_get("sent_at")?,
        })
    }
}

fn short_id(id: &str) -> &str {
    let end = id.char_indices().nth(8).map(|(i, _)| i).unwrap_or(id.len());
    &id[..end]
}
