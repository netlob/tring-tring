//! Scheduled notification dispatcher (ADR-0015).
//!
//! Two responsibilities:
//!   1. `enqueue` / `cancel_by_external_id` — write-side helpers used by
//!      the webhook (when a `delay` / `scheduleTimestamp` is supplied) and
//!      by the cancel endpoint (ADR-0014).
//!   2. `spawn` — a single tokio task polling `scheduled_notifications` for
//!      due rows at a fixed cadence. Per ADR-0015, the scheduler holds no
//!      in-memory state; SQLite is the source of truth. Restart resumes
//!      from whatever the table says — missed-window pushes fire on the
//!      next tick (best-effort catchup).
//!
//! The dispatch path is shared with the immediate webhook via
//! `crate::dispatch::run` so that template/payload semantics, fan-out,
//! quota accounting, and APNs error handling stay in one place.

use std::time::Duration;

use serde::Deserialize;
use serde_json::Value;
use sqlx::SqlitePool;
use tokio::task::JoinHandle;

use crate::AppState;

/// Insert a row into `scheduled_notifications`. Returns the row id (UUID).
///
/// Idempotent on `(user_id, external_id)` when `external_id` is supplied:
/// if a `pending` row already exists with the same pair, return its id
/// without inserting again. The 24-hour window from ADR-0014 is upheld at
/// the webhook layer (idempotency cache + retention sweep); here we simply
/// honour any pending row regardless of age — once it has fired it leaves
/// the `pending` status and a fresh schedule call will succeed.
///
/// `payload_json` is the canonical webhook payload after any template
/// merge has been applied (ADR-0018) — opaque to the scheduler per the
/// "operational rules" section of ADR-0015.
pub async fn enqueue(
    pool: &SqlitePool,
    user_id: &str,
    name: &str,
    external_id: Option<&str>,
    payload_json: &Value,
    send_at_unix: i64,
) -> sqlx::Result<String> {
    if let Some(eid) = external_id {
        let existing: Option<String> = sqlx::query_scalar(
            "SELECT id FROM scheduled_notifications \
             WHERE user_id = ? AND external_id = ? AND status = 'pending' \
             LIMIT 1",
        )
        .bind(user_id)
        .bind(eid)
        .fetch_optional(pool)
        .await?;

        if let Some(id) = existing {
            return Ok(id);
        }
    }

    let id = uuid::Uuid::new_v4().to_string();
    let now = now_unix();
    let payload_str = payload_json.to_string();

    sqlx::query(
        "INSERT INTO scheduled_notifications \
           (id, user_id, name, external_id, payload_json, send_at, status, created_at) \
         VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)",
    )
    .bind(&id)
    .bind(user_id)
    .bind(name)
    .bind(external_id)
    .bind(&payload_str)
    .bind(send_at_unix)
    .bind(now)
    .execute(pool)
    .await?;

    Ok(id)
}

/// Cancel a pending scheduled notification by external identifier.
/// Returns `true` if a `pending` row was transitioned to `cancelled`,
/// `false` otherwise (already dispatched / cancelled / failed / unknown).
///
/// Per ADR-0014 the cancel handler treats `false` as "already_delivered"
/// versus "unknown identifier" by also looking at `notifications_log`;
/// that disambiguation is the caller's job, not ours.
pub async fn cancel_by_external_id(
    pool: &SqlitePool,
    user_id: &str,
    external_id: &str,
) -> sqlx::Result<bool> {
    let result = sqlx::query(
        "UPDATE scheduled_notifications \
         SET status = 'cancelled', dispatched_at = NULL \
         WHERE user_id = ? AND external_id = ? AND status = 'pending'",
    )
    .bind(user_id)
    .bind(external_id)
    .execute(pool)
    .await?;

    Ok(result.rows_affected() > 0)
}

/// Spawn the polling task. Returns the `JoinHandle` so the caller can
/// abort it during graceful shutdown.
///
/// The first poll happens *after* the first sleep (mirrors `retention.rs`):
/// this avoids a flurry of dispatches racing the rest of the boot
/// sequence. At the recommended `tick_interval = 1s` the worst-case
/// dispatch latency is ~1s + one fan-out duration, well within the
/// "best-effort late delivery" envelope documented in ADR-0015.
pub fn spawn(state: AppState, tick_interval: Duration) -> JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(tick_interval).await;
            do_pass(&state).await;
        }
    })
}

/// One scheduler pass: pick up at most 100 due rows, dispatch them, and
/// update their status. Per-row failures are logged and swallowed — the
/// next pass will retry rows that are still `pending`.
async fn do_pass(state: &AppState) {
    let now = now_unix();

    // The partial / composite `idx_scheduled_due (status, send_at)` from
    // migration 0003 makes this a microsecond query even with millions of
    // dispatched rows accumulated.
    let rows = match sqlx::query_as::<_, DueRow>(
        "SELECT id, user_id, name, external_id, payload_json, send_at \
         FROM scheduled_notifications \
         WHERE status = 'pending' AND send_at <= ? \
         ORDER BY send_at \
         LIMIT 100",
    )
    .bind(now)
    .fetch_all(&state.db)
    .await
    {
        Ok(rs) => rs,
        Err(err) => {
            tracing::warn!(error = %err, "scheduler: select failed");
            return;
        }
    };

    if rows.is_empty() {
        return;
    }

    let mut dispatched_count = 0_usize;
    for row in rows {
        match dispatch_row(state, &row).await {
            Ok(()) => {
                if let Err(err) = mark_dispatched(&state.db, &row.id).await {
                    tracing::warn!(
                        scheduled_id = %row.id,
                        error = %err,
                        "scheduler: failed to mark row dispatched"
                    );
                } else {
                    dispatched_count += 1;
                }
            }
            Err(reason) => {
                tracing::warn!(
                    scheduled_id = %row.id,
                    name = %row.name,
                    reason = %reason,
                    "scheduler: dispatch failed, marking row failed"
                );
                if let Err(err) = mark_failed(&state.db, &row.id, &reason).await {
                    tracing::warn!(
                        scheduled_id = %row.id,
                        error = %err,
                        "scheduler: failed to mark row failed"
                    );
                }
            }
        }
    }

    if dispatched_count > 0 {
        tracing::info!(dispatched = dispatched_count, "scheduler: pass complete");
    }
}

/// Convert a `DueRow` into a `DispatchInput` and call `dispatch::run`.
async fn dispatch_row(state: &AppState, row: &DueRow) -> Result<(), String> {
    let payload: SchedulerPayload =
        serde_json::from_str(&row.payload_json).map_err(|e| format!("payload deserialize: {e}"))?;

    // Mirror routes/notify.rs::map_sound (vibrateOnly -> silent, else passthrough).
    let sound = match payload.sound.as_deref() {
        Some("vibrateOnly") => None,
        Some(_) => payload.sound,
        None => None,
    };

    let (default_url, default_url_background_options) = match payload.default_action {
        Some(da) => (da.url, da.url_background_options),
        None => (None, None),
    };

    let actions = payload
        .actions
        .unwrap_or_default()
        .into_iter()
        .filter_map(|a| {
            let name = a.name?;
            Some(crate::dispatch::ParsedAction {
                name,
                url: a.url,
                input: a.input,
                keep_notification: a.keep_notification.unwrap_or(false),
                run_on_server: a.run_on_server.unwrap_or(false),
                url_background_options: a.url_background_options,
            })
        })
        .collect();

    let devices_filter = payload.devices.and_then(|list| {
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

    let input = crate::dispatch::DispatchInput {
        external_id: row.external_id.clone(),
        name: row.name.clone(),
        title: payload.title,
        body: payload.text,
        sound,
        thread_id: payload.thread_id,
        time_sensitive: payload.is_time_sensitive.unwrap_or(false),
        default_url,
        default_url_background_options,
        input: payload.input,
        image_url: payload.image,
        image_data: payload.image_data,
        devices_filter,
        actions,
    };

    crate::dispatch::run(state, &row.user_id, input)
        .await
        .map(|_| ())
        .map_err(|e| e.to_string())
}

async fn mark_dispatched(pool: &SqlitePool, id: &str) -> sqlx::Result<()> {
    sqlx::query(
        "UPDATE scheduled_notifications \
         SET status = 'dispatched', dispatched_at = ? \
         WHERE id = ? AND status = 'pending'",
    )
    .bind(now_unix())
    .bind(id)
    .execute(pool)
    .await?;
    Ok(())
}

async fn mark_failed(pool: &SqlitePool, id: &str, reason: &str) -> sqlx::Result<()> {
    sqlx::query(
        "UPDATE scheduled_notifications \
         SET status = 'failed', dispatched_at = ?, failed_reason = ? \
         WHERE id = ? AND status = 'pending'",
    )
    .bind(now_unix())
    .bind(reason)
    .bind(id)
    .execute(pool)
    .await?;
    Ok(())
}

#[derive(Debug, sqlx::FromRow)]
struct DueRow {
    id: String,
    user_id: String,
    name: String,
    external_id: Option<String>,
    payload_json: String,
    #[allow(dead_code)]
    send_at: i64,
}

/// Mirrors the field set of `routes::notify::NotifyBody`. Duplicated
/// deliberately to keep the scheduler independent of the route module's
/// private types — ADR-0015 explicitly notes that scheduled rows must
/// survive webhook-schema evolution.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SchedulerPayload {
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
    default_action: Option<SchedulerDefaultAction>,
    #[serde(default)]
    input: Option<String>,
    #[serde(default)]
    image: Option<String>,
    #[serde(default)]
    image_data: Option<String>,
    #[serde(default)]
    devices: Option<Vec<String>>,
    #[serde(default)]
    actions: Option<Vec<SchedulerAction>>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SchedulerDefaultAction {
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    url_background_options: Option<serde_json::Value>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SchedulerAction {
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
    url_background_options: Option<serde_json::Value>,
}

fn now_unix() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
