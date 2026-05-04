use axum::extract::{Path, Query, State};
use axum::Json;
use once_cell::sync::Lazy;
use regex::Regex;
use serde::Deserialize;
use serde_json::Value;

use crate::apns::{ApnsError, ApnsPayload};
use crate::error::{AppError, AppResult};
use crate::models::{now_unix, Device};
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

#[tracing::instrument(
    skip(state, payload),
    fields(secret_prefix = %&secret[..8.min(secret.len())])
)]
pub async fn notify_post(
    State(state): State<AppState>,
    Path((secret, name)): Path<(String, String)>,
    payload: Option<Json<NotifyBody>>,
) -> AppResult<Json<Value>> {
    let input = payload
        .map(|Json(b)| NotifyInput::from(b))
        .unwrap_or_default();
    process_send(state, secret, name, input).await
}

#[tracing::instrument(
    skip(state, payload),
    fields(secret_prefix = %&secret[..8.min(secret.len())])
)]
pub async fn notify_get(
    State(state): State<AppState>,
    Path((secret, name)): Path<(String, String)>,
    Query(payload): Query<NotifyQuery>,
) -> AppResult<Json<Value>> {
    process_send(state, secret, name, NotifyInput::from(payload)).await
}

async fn process_send(
    state: AppState,
    secret: String,
    name: String,
    input: NotifyInput,
) -> AppResult<Json<Value>> {
    if !NAME_RE.is_match(&name) {
        return Err(AppError::BadRequest("invalid notification name".into()));
    }

    let device: Option<Device> = sqlx::query_as::<_, Device>(
        "SELECT id, webhook_secret, apns_token, apns_env, device_name, created_at, last_seen_at FROM devices WHERE webhook_secret = ?",
    )
    .bind(&secret)
    .fetch_optional(&state.db)
    .await?;
    let device = device.ok_or(AppError::NotFound)?;

    state.rate_limiter.check(&device.id)?;
    rate_limit::check_monthly_quota(&state.db, &device.id, state.config.monthly_quota).await?;

    let sound = map_sound(input.sound.as_deref());
    let payload = ApnsPayload {
        name: name.clone(),
        title: input.title,
        body: input.text,
        sound,
        thread_id: input.thread_id,
        time_sensitive: input.is_time_sensitive,
        default_url: input.default_action_url,
        input: input.input,
    };

    match state.apns.send(&device.apns_token, payload).await {
        Ok(outcome) => {
            tracing::info!(
                device_id_prefix = %short_id(&device.id),
                name = %name,
                apns_status = outcome.apns_status,
                "notification sent"
            );
            rate_limit::record_notification(
                &state.db,
                &device.id,
                Some(&name),
                "sent",
                Some(outcome.apns_status as i64),
                outcome.apns_reason.as_deref(),
                now_unix(),
            )
            .await?;
            Ok(Json(serde_json::json!({})))
        }
        Err(ApnsError::DeviceGone { status, reason }) => {
            tracing::warn!(
                device_id_prefix = %short_id(&device.id),
                apns_status = status,
                apns_reason = %reason,
                "device gone — deleting"
            );
            sqlx::query("DELETE FROM devices WHERE id = ?")
                .bind(&device.id)
                .execute(&state.db)
                .await?;
            Err(AppError::DeviceGone)
        }
        Err(ApnsError::ClientError { status, reason }) => {
            rate_limit::record_notification(
                &state.db,
                &device.id,
                Some(&name),
                "failed",
                Some(status as i64),
                Some(&reason),
                now_unix(),
            )
            .await?;
            Err(AppError::ApnsRejected { status, reason })
        }
        Err(ApnsError::ServerError { status, reason }) => {
            rate_limit::record_notification(
                &state.db,
                &device.id,
                Some(&name),
                "failed",
                Some(status as i64),
                Some(&reason),
                now_unix(),
            )
            .await?;
            Err(AppError::ApnsRejected { status, reason })
        }
        Err(ApnsError::Transport(msg)) => {
            tracing::error!(
                device_id_prefix = %short_id(&device.id),
                error = %msg,
                "apns transport error"
            );
            rate_limit::record_notification(
                &state.db,
                &device.id,
                Some(&name),
                "failed",
                None,
                Some(&msg),
                now_unix(),
            )
            .await?;
            Err(AppError::ApnsTransport(msg))
        }
        Err(ApnsError::InvalidName(msg)) => Err(AppError::BadRequest(msg)),
    }
}

fn map_sound(raw: Option<&str>) -> Option<String> {
    match raw {
        None => None,
        Some("vibrateOnly") => None,
        Some(_) => Some("default".into()),
    }
}

fn short_id(id: &str) -> &str {
    let end = id.len().min(8);
    &id[..end]
}
