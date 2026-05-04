use axum::extract::{Path, Query, State};
use axum::Json;
use futures::future::join_all;
use once_cell::sync::Lazy;
use regex::Regex;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::apns::{ApnsError, ApnsPayload};
use crate::error::{AppError, AppResult};
use crate::models;
use crate::rate_limit;
use crate::AppState;

static NAME_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^[A-Za-z0-9._-]{1,64}$").expect("valid notification-name regex"));

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DefaultAction {
    #[serde(default)]
    url: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotifyBody {
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    sound: Option<String>,
    #[serde(default)]
    thread_id: Option<String>,
    #[serde(default)]
    is_time_sensitive: Option<bool>,
    #[serde(default)]
    default_action: Option<DefaultAction>,
    #[serde(default)]
    input: Option<String>,
}

// `defaultAction` is a nested object in the JSON body and is awkward to express
// as a query parameter, so on GET we accept the URL as a flat
// `defaultActionUrl` query param (Pushcut compatibility is best-effort on GET).
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotifyQuery {
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    sound: Option<String>,
    #[serde(default)]
    thread_id: Option<String>,
    #[serde(default)]
    is_time_sensitive: Option<bool>,
    #[serde(default)]
    default_action_url: Option<String>,
    #[serde(default)]
    input: Option<String>,
}

#[derive(Debug, Default)]
struct NotifyInput {
    title: Option<String>,
    text: Option<String>,
    sound: Option<String>,
    thread_id: Option<String>,
    is_time_sensitive: bool,
    default_action_url: Option<String>,
    input: Option<String>,
}

impl From<NotifyBody> for NotifyInput {
    fn from(b: NotifyBody) -> Self {
        Self {
            title: b.title,
            text: b.text,
            sound: b.sound,
            thread_id: b.thread_id,
            is_time_sensitive: b.is_time_sensitive.unwrap_or(false),
            default_action_url: b.default_action.and_then(|d| d.url),
            input: b.input,
        }
    }
}

impl From<NotifyQuery> for NotifyInput {
    fn from(q: NotifyQuery) -> Self {
        Self {
            title: q.title,
            text: q.text,
            sound: q.sound,
            thread_id: q.thread_id,
            is_time_sensitive: q.is_time_sensitive.unwrap_or(false),
            default_action_url: q.default_action_url,
            input: q.input,
        }
    }
}

#[tracing::instrument(
    skip(state, payload),
    fields(
        user_prefix = %&user_id[..8.min(user_id.len())],
        name = %name
    )
)]
pub async fn notify_post(
    State(state): State<AppState>,
    Path((user_id, name)): Path<(String, String)>,
    payload: Option<Json<NotifyBody>>,
) -> AppResult<Json<Value>> {
    let input = payload
        .map(|Json(b)| NotifyInput::from(b))
        .unwrap_or_default();
    process_send(state, user_id, name, input).await
}

#[tracing::instrument(
    skip(state, query),
    fields(
        user_prefix = %&user_id[..8.min(user_id.len())],
        name = %name
    )
)]
pub async fn notify_get(
    State(state): State<AppState>,
    Path((user_id, name)): Path<(String, String)>,
    Query(query): Query<NotifyQuery>,
) -> AppResult<Json<Value>> {
    process_send(state, user_id, name, NotifyInput::from(query)).await
}

async fn process_send(
    state: AppState,
    user_id: String,
    name: String,
    input: NotifyInput,
) -> AppResult<Json<Value>> {
    if !NAME_RE.is_match(&name) {
        return Err(AppError::BadRequest("invalid notification name".into()));
    }

    let now = models::now_unix();

    let user_exists: Option<String> = sqlx::query_scalar("SELECT id FROM users WHERE id = ?")
        .bind(&user_id)
        .fetch_optional(&state.db)
        .await?;
    if user_exists.is_none() {
        return Err(AppError::NotFound);
    }

    sqlx::query("UPDATE users SET last_seen_at = ? WHERE id = ?")
        .bind(now)
        .bind(&user_id)
        .execute(&state.db)
        .await?;

    state.rate_limiter.check(&user_id)?;
    rate_limit::check_monthly_quota(&state.db, &user_id, state.config.monthly_quota).await?;

    let devices: Vec<(String, String)> = sqlx::query_as::<_, (String, String)>(
        "SELECT id, apns_token FROM devices WHERE user_id = ?",
    )
    .bind(&user_id)
    .fetch_all(&state.db)
    .await?;

    if devices.is_empty() {
        rate_limit::record_log_row(
            &state.db,
            &user_id,
            None,
            Some(&name),
            "no_devices",
            None,
            None,
            now,
        )
        .await?;
        return Err(AppError::DeviceGone);
    }

    let payload = ApnsPayload {
        name: name.clone(),
        title: input.title,
        body: input.text,
        sound: map_sound(input.sound),
        thread_id: input.thread_id,
        time_sensitive: input.is_time_sensitive,
        default_url: input.default_action_url,
        input: input.input,
    };

    let send_futures = devices.iter().map(|(_id, token)| {
        let payload = payload.clone();
        let token = token.clone();
        let apns = state.apns.clone();
        async move { apns.send(&token, payload).await }
    });
    let results: Vec<Result<_, _>> = join_all(send_futures).await;

    let mut any_succeeded = false;
    let mut last_client_error: Option<(u16, String)> = None;
    let mut last_server_error: Option<(u16, String)> = None;
    let mut last_transport_error: Option<String> = None;

    for ((device_id, _token), result) in devices.iter().zip(results) {
        match result {
            Ok(outcome) => {
                let apns_status = outcome.apns_status as i64;
                rate_limit::record_log_row(
                    &state.db,
                    &user_id,
                    Some(device_id),
                    Some(&name),
                    "sent",
                    Some(apns_status),
                    outcome.apns_reason.as_deref(),
                    now,
                )
                .await?;
                any_succeeded = true;
            }
            Err(ApnsError::DeviceGone { status, reason: _ }) => {
                sqlx::query("DELETE FROM devices WHERE id = ?")
                    .bind(device_id)
                    .execute(&state.db)
                    .await?;
                rate_limit::record_log_row(
                    &state.db,
                    &user_id,
                    None,
                    Some(&name),
                    "failed",
                    Some(status as i64),
                    Some("device gone"),
                    now,
                )
                .await?;
            }
            Err(ApnsError::ClientError { status, reason }) => {
                rate_limit::record_log_row(
                    &state.db,
                    &user_id,
                    Some(device_id),
                    Some(&name),
                    "failed",
                    Some(status as i64),
                    Some(&reason),
                    now,
                )
                .await?;
                last_client_error = Some((status, reason));
            }
            Err(ApnsError::ServerError { status, reason }) => {
                rate_limit::record_log_row(
                    &state.db,
                    &user_id,
                    Some(device_id),
                    Some(&name),
                    "failed",
                    Some(status as i64),
                    Some(&reason),
                    now,
                )
                .await?;
                last_server_error = Some((status, reason));
            }
            Err(ApnsError::Transport(msg)) => {
                rate_limit::record_log_row(
                    &state.db,
                    &user_id,
                    Some(device_id),
                    Some(&name),
                    "failed",
                    None,
                    Some(&msg),
                    now,
                )
                .await?;
                last_transport_error = Some(msg);
            }
            Err(ApnsError::InvalidName(_)) => {
                return Err(AppError::BadRequest("invalid name (apns)".into()));
            }
        }
    }

    if any_succeeded {
        rate_limit::increment_monthly_usage(&state.db, &user_id, now).await?;
        return Ok(Json(json!({})));
    }

    if let Some(msg) = last_transport_error {
        return Err(AppError::ApnsTransport(msg));
    }
    if let Some((status, reason)) = last_client_error.or(last_server_error) {
        return Err(AppError::ApnsRejected { status, reason });
    }

    Err(AppError::DeviceGone)
}

/// Pushcut sound name → APNs `sound` field.
/// `Some("vibrateOnly")` silences the alert (no `sound` key); any other named
/// value collapses to APNs's `default` sound for v1; `None` stays unset.
fn map_sound(sound: Option<String>) -> Option<String> {
    match sound.as_deref() {
        Some("vibrateOnly") => None,
        Some(_) => Some("default".to_string()),
        None => None,
    }
}
