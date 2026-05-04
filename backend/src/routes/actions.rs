//! `POST /v1/users/:user_id/actions/run` — execute a run-on-server action
//! that was previously persisted by the dispatcher.
//!
//! See ADR-0017. Bearer auth and per-user rate-limiting are enforced upstream
//! (middleware); this handler trusts that the bearer is a valid `userId` and
//! checks ownership of the `pendingActionId` against the path `userId`.
//!
//! The actual outbound HTTPS call lives in [`crate::runner`], which enforces
//! all SSRF guardrails. This route is a thin adapter on top.

use axum::extract::{Path, State};
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::{AppError, AppResult};
use crate::models;
use crate::runner::{self, HttpHeader, RunnerError, UrlBackgroundOptions};
use crate::AppState;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunPendingActionRequest {
    pub pending_action_id: String,
    #[serde(default)]
    pub idempotency_key: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunPendingActionResponse {
    /// Upstream HTTP status, if a request was issued. `None` for a no-op.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<u16>,
    pub executed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub elapsed_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

#[tracing::instrument(
    skip(state, payload),
    fields(
        user_prefix = %&user_id[..8.min(user_id.len())],
        idempotency_key = tracing::field::Empty,
    )
)]
pub async fn run_pending_action(
    State(state): State<AppState>,
    Path(user_id): Path<String>,
    Json(payload): Json<RunPendingActionRequest>,
) -> AppResult<Json<RunPendingActionResponse>> {
    if let Some(key) = payload.idempotency_key.as_deref() {
        // v1 hint only; we don't enforce idempotency yet.
        tracing::Span::current().record("idempotency_key", tracing::field::display(key));
    }

    // 1. Fetch the row.
    let row: Option<(String, String, i64)> = sqlx::query_as::<_, (String, String, i64)>(
        "SELECT user_id, payload_json, expires_at \
         FROM pending_actions WHERE id = ?",
    )
    .bind(&payload.pending_action_id)
    .fetch_optional(&state.db)
    .await?;

    let (row_user_id, payload_json, expires_at) = row.ok_or(AppError::NotFound)?;

    // 2. Ownership.
    if row_user_id != user_id {
        return Err(AppError::Forbidden("not your action".into()));
    }

    // 3. TTL.
    let now = models::now_unix();
    if now >= expires_at {
        return Err(AppError::Conflict("action expired".into()));
    }

    // 4. Parse the persisted action object.
    let action: PersistedAction = serde_json::from_str(&payload_json)
        .map_err(|e| AppError::BadRequest(format!("stored action is not a valid object: {e}")))?;

    // Pushcut convention: `online: false` means "don't actually run this; just
    // acknowledge it". Callers can use it as a tap-receipt.
    if matches!(action.online, Some(false)) {
        return Ok(Json(RunPendingActionResponse {
            status: None,
            executed: false,
            elapsed_ms: None,
            reason: Some("online flag false".into()),
        }));
    }

    let url = action
        .url
        .ok_or_else(|| AppError::BadRequest("stored action has no url".into()))?;
    let options = action
        .url_background_options
        .map(map_options)
        .unwrap_or_default();

    // 5. Execute via the SSRF-safe runner.
    let result = runner::execute(&url, &options).await;

    // 8. Decision: keep the row in `pending_actions`. Lets users retry within
    // the TTL; the retention sweep cleans up after `expires_at`.
    map_runner_result(result)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersistedAction {
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    online: Option<bool>,
    #[serde(default)]
    url_background_options: Option<PersistedUrlBackgroundOptions>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersistedUrlBackgroundOptions {
    #[serde(default)]
    http_method: Option<String>,
    #[serde(default)]
    http_content_type: Option<String>,
    #[serde(default)]
    http_header: Option<Vec<PersistedHttpHeader>>,
    #[serde(default)]
    http_body: Option<Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersistedHttpHeader {
    #[serde(default)]
    key: Option<String>,
    #[serde(default)]
    value: Option<String>,
}

fn map_options(opts: PersistedUrlBackgroundOptions) -> UrlBackgroundOptions {
    let http_header = opts
        .http_header
        .unwrap_or_default()
        .into_iter()
        .filter_map(|h| match (h.key, h.value) {
            (Some(k), Some(v)) if !k.is_empty() => Some(HttpHeader { key: k, value: v }),
            _ => None,
        })
        .collect();

    UrlBackgroundOptions {
        http_method: opts.http_method,
        http_content_type: opts.http_content_type,
        http_header,
        http_body: opts.http_body.map(stringify_body),
    }
}

/// Pushcut convention: `httpBody` is a string. We accept JSON values for
/// callers that pass an object/array — those get serialized; strings pass
/// through verbatim.
pub(crate) fn stringify_body(v: Value) -> String {
    match v {
        Value::String(s) => s,
        other => other.to_string(),
    }
}

pub(crate) fn map_runner_result(
    result: Result<runner::ExecutionOutcome, RunnerError>,
) -> AppResult<Json<RunPendingActionResponse>> {
    match result {
        Ok(outcome) => Ok(Json(RunPendingActionResponse {
            status: Some(outcome.status),
            executed: true,
            elapsed_ms: Some(outcome.elapsed_ms),
            reason: None,
        })),
        Err(RunnerError::NonSuccess { status }) => Ok(Json(RunPendingActionResponse {
            status: Some(status),
            executed: true,
            elapsed_ms: None,
            reason: None,
        })),
        Err(RunnerError::NotHttps) => Err(AppError::Forbidden("only https:// is allowed".into())),
        Err(RunnerError::ParseUrl(msg)) => Err(AppError::Forbidden(format!("invalid url: {msg}"))),
        Err(RunnerError::BlockedIp) => {
            Err(AppError::Forbidden("resolved address not permitted".into()))
        }
        Err(RunnerError::DnsFailed) => Err(AppError::Forbidden("dns resolution failed".into())),
        Err(RunnerError::ConnectTimeout) => Err(AppError::Upstream("connect timeout".into())),
        Err(RunnerError::Timeout) => Err(AppError::Upstream("request timed out".into())),
        Err(RunnerError::Transport(msg)) => Err(AppError::Upstream(msg)),
    }
}
