//! `POST /v1/execute` — fire an arbitrary URL action server-side (ADR-0019).
//!
//! Bearer auth is enforced by middleware; once we get here the caller is a
//! valid user. The body is Pushcut-shaped: a single action object with
//! `url`, optional `urlBackgroundOptions`, `online`, and `name`. The same
//! SSRF-safe execution path used by [`super::actions`] runs the request.

use axum::extract::State;
use axum::Json;
use serde::Deserialize;
use serde_json::Value;

use crate::error::{AppError, AppResult};
use crate::routes::actions::{map_runner_result, stringify_body, RunPendingActionResponse};
use crate::runner::{self, HttpHeader, UrlBackgroundOptions};
use crate::AppState;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExecuteRequest {
    pub url: String,
    #[serde(default)]
    pub url_background_options: Option<ExecuteUrlBackgroundOptions>,
    #[serde(default)]
    pub online: Option<bool>,
    /// Optional human-friendly label; logged but otherwise unused.
    #[serde(default)]
    pub name: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExecuteUrlBackgroundOptions {
    #[serde(default)]
    pub http_method: Option<String>,
    #[serde(default)]
    pub http_content_type: Option<String>,
    #[serde(default)]
    pub http_header: Option<Vec<ExecuteHttpHeader>>,
    #[serde(default)]
    pub http_body: Option<Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExecuteHttpHeader {
    #[serde(default)]
    pub key: Option<String>,
    #[serde(default)]
    pub value: Option<String>,
}

#[tracing::instrument(
    skip(_state, payload),
    fields(action_name = tracing::field::Empty)
)]
pub async fn execute(
    State(_state): State<AppState>,
    Json(payload): Json<ExecuteRequest>,
) -> AppResult<Json<RunPendingActionResponse>> {
    if let Some(name) = payload.name.as_deref() {
        tracing::Span::current().record("action_name", tracing::field::display(name));
    }

    // Pushcut convention: `online: false` is "acknowledge but don't actually
    // run". Mirrors the same path in routes/actions.rs.
    if matches!(payload.online, Some(false)) {
        return Ok(Json(RunPendingActionResponse {
            status: None,
            executed: false,
            elapsed_ms: None,
            reason: Some("online flag false".into()),
        }));
    }

    if payload.url.trim().is_empty() {
        return Err(AppError::BadRequest("url is required".into()));
    }

    let options = payload
        .url_background_options
        .map(map_options)
        .unwrap_or_default();

    let result = runner::execute(&payload.url, &options).await;
    map_runner_result(result)
}

fn map_options(opts: ExecuteUrlBackgroundOptions) -> UrlBackgroundOptions {
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
