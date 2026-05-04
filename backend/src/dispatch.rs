//! Shared fan-out dispatch logic.
//!
//! Used by `routes/notify.rs` (immediate path) and by `scheduler.rs` (deferred
//! path, ADR-0015). The same function signature serves both: a fully validated
//! [`DispatchInput`] is fanned out to the user's matching devices, every
//! attempt is logged, the monthly counter is bumped at most once per call,
//! and any `runOnServer` actions are persisted into `pending_actions`.

use futures::future::join_all;
use serde_json::{Map, Value};
use sqlx::Row;
use uuid::Uuid;

use crate::apns::{ApnsActionInfo, ApnsError, ApnsPayload};
use crate::error::AppResult;
use crate::rate_limit;
use crate::AppState;

const PENDING_ACTION_TTL_SECS: i64 = 24 * 60 * 60;

/// Input to dispatch — the canonical "what to send" struct after parsing,
/// validation, and template merge.
#[derive(Debug, Clone)]
pub struct DispatchInput {
    pub external_id: Option<String>,
    pub name: String,
    pub title: Option<String>,
    pub body: Option<String>,
    pub sound: Option<String>,
    pub thread_id: Option<String>,
    pub time_sensitive: bool,
    pub default_url: Option<String>,
    pub default_url_background_options: Option<Value>,
    pub input: Option<String>,
    pub image_url: Option<String>,
    pub image_data: Option<String>,
    pub devices_filter: Option<Vec<String>>,
    pub actions: Vec<ParsedAction>,
}

#[derive(Debug, Clone)]
pub struct ParsedAction {
    pub name: String,
    pub url: Option<String>,
    pub input: Option<String>,
    pub keep_notification: bool,
    pub run_on_server: bool,
    pub url_background_options: Option<Value>,
}

#[derive(Debug)]
pub struct DispatchOutcome {
    pub any_succeeded: bool,
    pub last_apns_status: Option<u16>,
    pub last_apns_reason: Option<String>,
    pub last_transport_error: Option<String>,
}

/// Look up the user's devices (filtered by device name if requested), build
/// the APNs payload, fan out via `futures::future::join_all`, write per-device
/// log rows, increment `monthly_usage` exactly once iff any delivery
/// succeeded, persist any `runOnServer` action records to `pending_actions`,
/// and return the outcome.
///
/// 410 Gone semantics (no devices) is the caller's job: this function returns
/// `Ok(DispatchOutcome { any_succeeded: false, ... })` with one log row of
/// `status="no_devices"` already written when the user's filtered device set
/// is empty.
pub async fn run(
    state: &AppState,
    user_id: &str,
    input: DispatchInput,
) -> AppResult<DispatchOutcome> {
    let now = crate::models::now_unix();

    let devices = load_devices(&state.db, user_id, input.devices_filter.as_deref()).await?;

    if devices.is_empty() {
        rate_limit::record_log_row(
            &state.db,
            user_id,
            None,
            Some(&input.name),
            "no_devices",
            None,
            None,
            now,
        )
        .await?;
        return Ok(DispatchOutcome {
            any_succeeded: false,
            last_apns_status: None,
            last_apns_reason: None,
            last_transport_error: None,
        });
    }

    let mut pending_action_ids: Vec<Option<String>> = Vec::with_capacity(input.actions.len());
    for action in &input.actions {
        if action.run_on_server {
            pending_action_ids.push(Some(Uuid::new_v4().to_string()));
        } else {
            pending_action_ids.push(None);
        }
    }

    let category = match input.actions.len() {
        0 => None,
        n @ 1..=3 => Some(format!("tt-{n}")),
        _ => Some("tt-3".to_string()),
    };

    let action_infos: Option<Vec<ApnsActionInfo>> = if input.actions.is_empty() {
        None
    } else {
        Some(
            input
                .actions
                .iter()
                .enumerate()
                .map(|(i, a)| ApnsActionInfo {
                    identifier: format!("act-{i}"),
                    title: a.name.clone(),
                    url: a.url.clone(),
                    input: a.input.clone(),
                    keep_notification: a.keep_notification,
                    run_on_server: a.run_on_server,
                    pending_action_id: pending_action_ids[i].clone(),
                })
                .collect(),
        )
    };

    let mut extra = Map::new();
    if let Some(ref ext_id) = input.external_id {
        extra.insert("identifier".to_string(), Value::String(ext_id.clone()));
    }
    if let Some(ref opts) = input.default_url_background_options {
        extra.insert("defaultActionOptions".to_string(), opts.clone());
    }
    let extra_user_info = if extra.is_empty() { None } else { Some(extra) };

    let payload = ApnsPayload {
        name: input.name.clone(),
        title: input.title.clone(),
        body: input.body.clone(),
        sound: input.sound.clone(),
        thread_id: input.thread_id.clone(),
        time_sensitive: input.time_sensitive,
        default_url: input.default_url.clone(),
        input: input.input.clone(),
        image_url: input.image_url.clone(),
        image_data: input.image_data.clone(),
        category,
        actions: action_infos,
        extra_user_info,
    };

    let send_futures = devices.iter().map(|d| {
        let payload = payload.clone();
        let token = d.apns_token.clone();
        let apns = state.apns.clone();
        async move { apns.send(&token, payload).await }
    });
    let results: Vec<Result<_, _>> = join_all(send_futures).await;

    let mut any_succeeded = false;
    let mut first_success_log_id: Option<i64> = None;
    let mut last_apns_status: Option<u16> = None;
    let mut last_apns_reason: Option<String> = None;
    let mut last_transport_error: Option<String> = None;

    for (device, result) in devices.iter().zip(results) {
        match result {
            Ok(outcome) => {
                let log_id = insert_log_row(
                    &state.db,
                    user_id,
                    Some(&device.id),
                    Some(&input.name),
                    input.external_id.as_deref(),
                    "sent",
                    Some(outcome.apns_status as i64),
                    outcome.apns_reason.as_deref(),
                    now,
                )
                .await?;
                if first_success_log_id.is_none() {
                    first_success_log_id = Some(log_id);
                }
                any_succeeded = true;
            }
            Err(ApnsError::DeviceGone { status, reason }) => {
                sqlx::query("DELETE FROM devices WHERE id = ?")
                    .bind(&device.id)
                    .execute(&state.db)
                    .await?;
                insert_log_row(
                    &state.db,
                    user_id,
                    None,
                    Some(&input.name),
                    input.external_id.as_deref(),
                    "failed",
                    Some(status as i64),
                    Some(&format!("device gone: {reason}")),
                    now,
                )
                .await?;
                last_apns_status = Some(status);
                last_apns_reason = Some(reason);
            }
            Err(ApnsError::ClientError { status, reason }) => {
                insert_log_row(
                    &state.db,
                    user_id,
                    Some(&device.id),
                    Some(&input.name),
                    input.external_id.as_deref(),
                    "failed",
                    Some(status as i64),
                    Some(&reason),
                    now,
                )
                .await?;
                last_apns_status = Some(status);
                last_apns_reason = Some(reason);
            }
            Err(ApnsError::ServerError { status, reason }) => {
                insert_log_row(
                    &state.db,
                    user_id,
                    Some(&device.id),
                    Some(&input.name),
                    input.external_id.as_deref(),
                    "failed",
                    Some(status as i64),
                    Some(&reason),
                    now,
                )
                .await?;
                last_apns_status = Some(status);
                last_apns_reason = Some(reason);
            }
            Err(ApnsError::Transport(msg)) => {
                insert_log_row(
                    &state.db,
                    user_id,
                    Some(&device.id),
                    Some(&input.name),
                    input.external_id.as_deref(),
                    "failed",
                    None,
                    Some(&msg),
                    now,
                )
                .await?;
                last_transport_error = Some(msg);
            }
            Err(ApnsError::InvalidName(msg)) => {
                last_transport_error = Some(format!("invalid name: {msg}"));
            }
        }
    }

    if any_succeeded {
        rate_limit::increment_monthly_usage(&state.db, user_id, now).await?;
    }

    persist_pending_actions(
        &state.db,
        user_id,
        first_success_log_id,
        &input.actions,
        &pending_action_ids,
        now,
    )
    .await?;

    Ok(DispatchOutcome {
        any_succeeded,
        last_apns_status,
        last_apns_reason,
        last_transport_error,
    })
}

#[derive(Debug)]
struct DeviceRow {
    id: String,
    apns_token: String,
}

async fn load_devices(
    db: &sqlx::SqlitePool,
    user_id: &str,
    filter: Option<&[String]>,
) -> AppResult<Vec<DeviceRow>> {
    let rows = sqlx::query("SELECT id, apns_token, device_name FROM devices WHERE user_id = ?")
        .bind(user_id)
        .fetch_all(db)
        .await?;

    let mut all: Vec<(String, String, Option<String>)> = rows
        .into_iter()
        .map(|r| {
            let id: String = r.get("id");
            let apns_token: String = r.get("apns_token");
            let device_name: Option<String> = r.get("device_name");
            (id, apns_token, device_name)
        })
        .collect();

    if let Some(names) = filter {
        let normalized: Vec<String> = names
            .iter()
            .map(|n| n.trim().to_lowercase())
            .filter(|n| !n.is_empty())
            .collect();
        if normalized.is_empty() {
            return Ok(all
                .drain(..)
                .map(|(id, apns_token, _)| DeviceRow { id, apns_token })
                .collect());
        }
        all.retain(|(_, _, dn)| {
            dn.as_deref()
                .map(|s| normalized.contains(&s.trim().to_lowercase()))
                .unwrap_or(false)
        });
    }

    Ok(all
        .into_iter()
        .map(|(id, apns_token, _)| DeviceRow { id, apns_token })
        .collect())
}

#[allow(clippy::too_many_arguments)]
async fn insert_log_row(
    db: &sqlx::SqlitePool,
    user_id: &str,
    device_id: Option<&str>,
    name: Option<&str>,
    external_id: Option<&str>,
    status: &str,
    apns_status: Option<i64>,
    apns_reason: Option<&str>,
    now_unix: i64,
) -> AppResult<i64> {
    let row = sqlx::query(
        "INSERT INTO notifications_log \
         (user_id, device_id, name, status, apns_status, apns_reason, sent_at, external_id) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?) \
         RETURNING id",
    )
    .bind(user_id)
    .bind(device_id)
    .bind(name)
    .bind(status)
    .bind(apns_status)
    .bind(apns_reason)
    .bind(now_unix)
    .bind(external_id)
    .fetch_one(db)
    .await?;
    let id: i64 = row.get("id");
    Ok(id)
}

async fn persist_pending_actions(
    db: &sqlx::SqlitePool,
    user_id: &str,
    notification_log_id: Option<i64>,
    actions: &[ParsedAction],
    ids: &[Option<String>],
    now: i64,
) -> AppResult<()> {
    let expires_at = now + PENDING_ACTION_TTL_SECS;
    for (action, id_opt) in actions.iter().zip(ids.iter()) {
        let Some(id) = id_opt else { continue };
        let payload = serde_json::to_string(&serde_json::json!({
            "name": action.name,
            "url": action.url,
            "input": action.input,
            "keepNotification": action.keep_notification,
            "runOnServer": action.run_on_server,
            "urlBackgroundOptions": action.url_background_options,
        }))
        .unwrap_or_else(|_| "{}".to_string());

        sqlx::query(
            "INSERT INTO pending_actions \
             (id, user_id, notification_log_id, action_name, payload_json, created_at, expires_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(id)
        .bind(user_id)
        .bind(notification_log_id)
        .bind(&action.name)
        .bind(&payload)
        .bind(now)
        .bind(expires_at)
        .execute(db)
        .await?;
    }
    Ok(())
}
