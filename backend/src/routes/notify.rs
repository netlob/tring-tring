use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use once_cell::sync::Lazy;
use regex::Regex;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::dispatch::{self, DispatchInput, ParsedAction};
use crate::error::{AppError, AppResult};
use crate::models;
use crate::rate_limit;
use crate::AppState;

static NAME_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^[A-Za-z0-9._-]{1,64}$").expect("valid notification-name regex"));

static IDENTIFIER_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^[A-Za-z0-9._-]{1,64}$").expect("valid identifier regex"));

static ACTION_NAME_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^[A-Za-z0-9._\- ]{1,32}$").expect("valid action-name regex"));

const IMAGE_DATA_MAX_BYTES: usize = 3072;
const MAX_DELAY_SECS: i64 = 7 * 24 * 60 * 60;
const SCHEDULE_PAST_SKEW_SECS: i64 = 30;

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DefaultActionBody {
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    url_background_options: Option<Value>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ActionBody {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    input: Option<String>,
    #[serde(default)]
    keep_notification: Option<bool>,
    #[serde(default)]
    run_on_server: Option<bool>,
    #[serde(default)]
    url_background_options: Option<Value>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotifyBody {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    identifier: Option<String>,
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
    default_action: Option<DefaultActionBody>,
    #[serde(default)]
    input: Option<String>,
    #[serde(default)]
    image: Option<String>,
    #[serde(default)]
    image_data: Option<String>,
    #[serde(default)]
    devices: Option<Vec<String>>,
    #[serde(default)]
    actions: Option<Vec<ActionBody>>,
    #[serde(default)]
    delay: Option<String>,
    #[serde(default)]
    schedule_timestamp: Option<i64>,
}

// `defaultAction` is a nested object in the JSON body and is awkward to express
// as a query parameter, so on GET we accept the URL as a flat
// `defaultActionUrl` query param (Pushcut compatibility is best-effort on GET).
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotifyQuery {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    identifier: Option<String>,
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
    #[serde(default)]
    image: Option<String>,
    #[serde(default)]
    delay: Option<String>,
    #[serde(default)]
    schedule_timestamp: Option<i64>,
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
) -> AppResult<axum::response::Response> {
    let body = payload.map(|Json(b)| b).unwrap_or_default();
    let value = serde_json::to_value(&body).unwrap_or(Value::Object(Default::default()));
    process_send(state, user_id, name, value).await
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
) -> AppResult<axum::response::Response> {
    let body = NotifyBody {
        id: query.id,
        identifier: query.identifier,
        title: query.title,
        text: query.text,
        sound: query.sound,
        thread_id: query.thread_id,
        is_time_sensitive: query.is_time_sensitive,
        default_action: query.default_action_url.map(|u| DefaultActionBody {
            url: Some(u),
            url_background_options: None,
        }),
        input: query.input,
        image: query.image,
        image_data: None,
        devices: None,
        actions: None,
        delay: query.delay,
        schedule_timestamp: query.schedule_timestamp,
    };
    let value = serde_json::to_value(&body).unwrap_or(Value::Object(Default::default()));
    process_send(state, user_id, name, value).await
}

async fn process_send(
    state: AppState,
    user_id: String,
    name: String,
    request_value: Value,
) -> AppResult<axum::response::Response> {
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

    let merged =
        crate::templates::merge_with_template(&state.db, &user_id, &name, request_value).await?;

    let body: NotifyBody = serde_json::from_value(merged.clone())
        .map_err(|e| AppError::BadRequest(format!("invalid payload after merge: {e}")))?;

    let validated = validate(body)?;

    let send_at = compute_send_at(&validated, now)?;

    if let Some(send_at_unix) = send_at {
        // Scheduled path. Mint an external_id if absent and persist via the
        // scheduler. We do not write a notifications_log row at schedule time
        // (the schema's CHECK on status doesn't include 'scheduled'); the row
        // is written when the scheduler dispatches.
        let external_id = validated
            .external_id
            .clone()
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());

        crate::scheduler::enqueue(
            &state.db,
            &user_id,
            &name,
            Some(&external_id),
            &merged,
            send_at_unix,
        )
        .await?;

        let body = json!({
            "identifier": external_id,
            "status": "scheduled",
            "sendAt": send_at_unix,
        });
        return Ok((StatusCode::ACCEPTED, Json(body)).into_response());
    }

    let dispatch_input = build_dispatch_input(name.clone(), validated);
    let outcome = dispatch::run(&state, &user_id, dispatch_input).await?;

    if outcome.any_succeeded {
        return Ok(Json(json!({})).into_response());
    }

    if let Some(msg) = outcome.last_transport_error {
        return Err(AppError::ApnsTransport(msg));
    }
    if let (Some(status), Some(reason)) = (outcome.last_apns_status, outcome.last_apns_reason) {
        return Err(AppError::ApnsRejected { status, reason });
    }

    Err(AppError::DeviceGone)
}

#[derive(Debug)]
struct ValidatedNotify {
    external_id: Option<String>,
    title: Option<String>,
    text: Option<String>,
    sound: Option<String>,
    thread_id: Option<String>,
    is_time_sensitive: bool,
    default_action_url: Option<String>,
    default_action_options: Option<Value>,
    input: Option<String>,
    image: Option<String>,
    image_data: Option<String>,
    devices: Option<Vec<String>>,
    actions: Vec<ParsedAction>,
    delay: Option<String>,
    schedule_timestamp_ms: Option<i64>,
}

fn validate(b: NotifyBody) -> AppResult<ValidatedNotify> {
    let external_id = b.identifier.or(b.id);
    if let Some(ref id) = external_id {
        if !IDENTIFIER_RE.is_match(id) {
            return Err(AppError::BadRequest("invalid identifier".into()));
        }
    }

    if let Some(ref url) = b.image {
        if !url.starts_with("https://") {
            return Err(AppError::BadRequest("image must be HTTPS".into()));
        }
    }

    if let Some(ref data) = b.image_data {
        if data.len() > IMAGE_DATA_MAX_BYTES {
            return Err(AppError::PayloadTooLarge);
        }
        if B64.decode(data.as_bytes()).is_err() {
            return Err(AppError::BadRequest("imageData is not valid base64".into()));
        }
    }

    let actions = match b.actions {
        Some(list) => {
            if list.len() > 3 {
                return Err(AppError::BadRequest(
                    "max 3 actions per notification".into(),
                ));
            }
            let mut out = Vec::with_capacity(list.len());
            let mut seen = std::collections::HashSet::new();
            for a in list {
                let name = a
                    .name
                    .as_deref()
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| AppError::BadRequest("action name is required".into()))?
                    .to_string();
                if !ACTION_NAME_RE.is_match(&name) {
                    return Err(AppError::BadRequest("invalid action name".into()));
                }
                if !seen.insert(name.clone()) {
                    return Err(AppError::BadRequest("duplicate action name".into()));
                }
                let run_on_server = a.run_on_server.unwrap_or(false);
                if a.url.is_none() && !run_on_server {
                    return Err(AppError::BadRequest(
                        "action must have url or runOnServer".into(),
                    ));
                }
                if let Some(ref url) = a.url {
                    if !url.starts_with("https://") {
                        return Err(AppError::BadRequest("action url must be HTTPS".into()));
                    }
                }
                out.push(ParsedAction {
                    name,
                    url: a.url,
                    input: a.input,
                    keep_notification: a.keep_notification.unwrap_or(false),
                    run_on_server,
                    url_background_options: a.url_background_options,
                });
            }
            out
        }
        None => Vec::new(),
    };

    let devices = b.devices.and_then(|list| {
        let cleaned: Vec<String> = list
            .into_iter()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        if cleaned.is_empty() {
            None
        } else {
            Some(cleaned)
        }
    });

    if b.delay.is_some() && b.schedule_timestamp.is_some() {
        return Err(AppError::BadRequest(
            "specify delay OR scheduleTimestamp, not both".into(),
        ));
    }

    let (default_action_url, default_action_options) = match b.default_action {
        Some(da) => (da.url, da.url_background_options),
        None => (None, None),
    };

    Ok(ValidatedNotify {
        external_id,
        title: b.title,
        text: b.text,
        sound: b.sound,
        thread_id: b.thread_id,
        is_time_sensitive: b.is_time_sensitive.unwrap_or(false),
        default_action_url,
        default_action_options,
        input: b.input,
        image: b.image,
        image_data: b.image_data,
        devices,
        actions,
        delay: b.delay,
        schedule_timestamp_ms: b.schedule_timestamp,
    })
}

fn compute_send_at(v: &ValidatedNotify, now_unix: i64) -> AppResult<Option<i64>> {
    if let Some(ref s) = v.delay {
        let secs = crate::delay::parse_delay_seconds(s)
            .map_err(|e| AppError::BadRequest(format!("invalid delay: {e}")))?;
        if secs <= 0 {
            return Ok(None);
        }
        if secs > MAX_DELAY_SECS {
            return Err(AppError::BadRequest("schedule exceeds 7-day cap".into()));
        }
        return Ok(Some(now_unix + secs));
    }

    if let Some(ms) = v.schedule_timestamp_ms {
        let target_secs = ms / 1000;
        if target_secs < now_unix - SCHEDULE_PAST_SKEW_SECS {
            return Err(AppError::BadRequest(
                "scheduleTimestamp is in the past".into(),
            ));
        }
        if target_secs > now_unix + MAX_DELAY_SECS {
            return Err(AppError::BadRequest("schedule exceeds 7-day cap".into()));
        }
        if target_secs <= now_unix {
            return Ok(None);
        }
        return Ok(Some(target_secs));
    }

    Ok(None)
}

fn build_dispatch_input(name: String, v: ValidatedNotify) -> DispatchInput {
    DispatchInput {
        external_id: v.external_id,
        name,
        title: v.title,
        body: v.text,
        sound: map_sound(v.sound),
        thread_id: v.thread_id,
        time_sensitive: v.is_time_sensitive,
        default_url: v.default_action_url,
        default_url_background_options: v.default_action_options,
        input: v.input,
        image_url: v.image,
        image_data: v.image_data,
        devices_filter: v.devices,
        actions: v.actions,
    }
}

/// Pushcut sound names pass through verbatim — iOS resolves `<name>.caf` from
/// the bundle. `vibrateOnly` is a special case that means silent (no sound key).
fn map_sound(sound: Option<String>) -> Option<String> {
    match sound.as_deref() {
        Some("vibrateOnly") => None,
        Some(_) => sound,
        None => None,
    }
}

impl serde::Serialize for NotifyBody {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let mut m = serializer.serialize_map(None)?;
        if let Some(ref v) = self.id {
            m.serialize_entry("id", v)?;
        }
        if let Some(ref v) = self.identifier {
            m.serialize_entry("identifier", v)?;
        }
        if let Some(ref v) = self.title {
            m.serialize_entry("title", v)?;
        }
        if let Some(ref v) = self.text {
            m.serialize_entry("text", v)?;
        }
        if let Some(ref v) = self.sound {
            m.serialize_entry("sound", v)?;
        }
        if let Some(ref v) = self.thread_id {
            m.serialize_entry("threadId", v)?;
        }
        if let Some(v) = self.is_time_sensitive {
            m.serialize_entry("isTimeSensitive", &v)?;
        }
        if let Some(ref v) = self.default_action {
            m.serialize_entry("defaultAction", v)?;
        }
        if let Some(ref v) = self.input {
            m.serialize_entry("input", v)?;
        }
        if let Some(ref v) = self.image {
            m.serialize_entry("image", v)?;
        }
        if let Some(ref v) = self.image_data {
            m.serialize_entry("imageData", v)?;
        }
        if let Some(ref v) = self.devices {
            m.serialize_entry("devices", v)?;
        }
        if let Some(ref v) = self.actions {
            m.serialize_entry("actions", v)?;
        }
        if let Some(ref v) = self.delay {
            m.serialize_entry("delay", v)?;
        }
        if let Some(v) = self.schedule_timestamp {
            m.serialize_entry("scheduleTimestamp", &v)?;
        }
        m.end()
    }
}

impl serde::Serialize for DefaultActionBody {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let mut m = serializer.serialize_map(None)?;
        if let Some(ref v) = self.url {
            m.serialize_entry("url", v)?;
        }
        if let Some(ref v) = self.url_background_options {
            m.serialize_entry("urlBackgroundOptions", v)?;
        }
        m.end()
    }
}

impl serde::Serialize for ActionBody {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let mut m = serializer.serialize_map(None)?;
        if let Some(ref v) = self.name {
            m.serialize_entry("name", v)?;
        }
        if let Some(ref v) = self.url {
            m.serialize_entry("url", v)?;
        }
        if let Some(ref v) = self.input {
            m.serialize_entry("input", v)?;
        }
        if let Some(v) = self.keep_notification {
            m.serialize_entry("keepNotification", &v)?;
        }
        if let Some(v) = self.run_on_server {
            m.serialize_entry("runOnServer", &v)?;
        }
        if let Some(ref v) = self.url_background_options {
            m.serialize_entry("urlBackgroundOptions", v)?;
        }
        m.end()
    }
}
