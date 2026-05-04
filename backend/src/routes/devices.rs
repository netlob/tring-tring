use axum::extract::{Path, State};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::error::{AppError, AppResult};
use crate::models::{generate_webhook_secret, now_unix, Device};
use crate::AppState;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterDeviceRequest {
    pub apns_token: String,
    pub apns_env: String,
    #[serde(default)]
    pub device_name: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterDeviceResponse {
    pub device_id: String,
    pub webhook_secret: String,
    pub webhook_url: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LogEntry {
    pub id: i64,
    pub name: Option<String>,
    pub status: String,
    pub apns_status: Option<i64>,
    pub apns_reason: Option<String>,
    pub sent_at: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceDetailsResponse {
    pub device_id: String,
    pub device_name: Option<String>,
    pub apns_env: String,
    pub created_at: i64,
    pub last_seen_at: i64,
    pub recent_log: Vec<LogEntry>,
}

#[tracing::instrument(skip(state, payload))]
pub async fn register_device(
    State(state): State<AppState>,
    Json(payload): Json<RegisterDeviceRequest>,
) -> AppResult<Json<RegisterDeviceResponse>> {
    validate_apns_token(&payload.apns_token)?;
    validate_apns_env(&payload.apns_env)?;

    let now = now_unix();

    let existing: Option<Device> =
        sqlx::query_as::<_, Device>("SELECT id, webhook_secret, apns_token, apns_env, device_name, created_at, last_seen_at FROM devices WHERE apns_token = ?")
            .bind(&payload.apns_token)
            .fetch_optional(&state.db)
            .await?;

    let device = match existing {
        Some(d) => {
            sqlx::query(
                "UPDATE devices SET apns_env = ?, device_name = ?, last_seen_at = ? WHERE id = ?",
            )
            .bind(&payload.apns_env)
            .bind(&payload.device_name)
            .bind(now)
            .bind(&d.id)
            .execute(&state.db)
            .await?;

            tracing::info!(device_id_prefix = %short_id(&d.id), "device re-registered");
            (d.id, d.webhook_secret)
        }
        None => {
            let id = uuid::Uuid::new_v4().to_string();
            let secret = generate_webhook_secret();

            sqlx::query(
                "INSERT INTO devices (id, webhook_secret, apns_token, apns_env, device_name, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            )
            .bind(&id)
            .bind(&secret)
            .bind(&payload.apns_token)
            .bind(&payload.apns_env)
            .bind(&payload.device_name)
            .bind(now)
            .bind(now)
            .execute(&state.db)
            .await?;

            tracing::info!(device_id_prefix = %short_id(&id), "device registered");
            (id, secret)
        }
    };

    let (device_id, webhook_secret) = device;
    let base = state.config.public_base_url.trim_end_matches('/');
    let webhook_url = format!("{base}/{webhook_secret}/notifications/example");

    Ok(Json(RegisterDeviceResponse {
        device_id,
        webhook_secret,
        webhook_url,
    }))
}

#[tracing::instrument(skip(state))]
pub async fn get_device_by_secret(
    State(state): State<AppState>,
    Path(secret): Path<String>,
) -> AppResult<Json<DeviceDetailsResponse>> {
    let device: Option<Device> = sqlx::query_as::<_, Device>(
        "SELECT id, webhook_secret, apns_token, apns_env, device_name, created_at, last_seen_at FROM devices WHERE webhook_secret = ?",
    )
    .bind(&secret)
    .fetch_optional(&state.db)
    .await?;

    let device = device.ok_or(AppError::NotFound)?;

    let recent_log: Vec<LogEntry> = sqlx::query_as::<_, LogEntry>(
        "SELECT id, name, status, apns_status, apns_reason, sent_at FROM notifications_log WHERE device_id = ? ORDER BY sent_at DESC LIMIT 50",
    )
    .bind(&device.id)
    .fetch_all(&state.db)
    .await?;

    tracing::info!(device_id_prefix = %short_id(&device.id), "device fetched");

    Ok(Json(DeviceDetailsResponse {
        device_id: device.id,
        device_name: device.device_name,
        apns_env: device.apns_env,
        created_at: device.created_at,
        last_seen_at: device.last_seen_at,
        recent_log,
    }))
}

impl<'r> sqlx::FromRow<'r, sqlx::sqlite::SqliteRow> for LogEntry {
    fn from_row(row: &'r sqlx::sqlite::SqliteRow) -> sqlx::Result<Self> {
        use sqlx::Row;
        Ok(LogEntry {
            id: row.try_get("id")?,
            name: row.try_get("name")?,
            status: row.try_get("status")?,
            apns_status: row.try_get("apns_status")?,
            apns_reason: row.try_get("apns_reason")?,
            sent_at: row.try_get("sent_at")?,
        })
    }
}

fn validate_apns_token(token: &str) -> AppResult<()> {
    let len = token.len();
    if !(64..=128).contains(&len) {
        return Err(AppError::BadRequest(
            "apnsToken must be 64-128 hex chars".into(),
        ));
    }
    if !token
        .bytes()
        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(AppError::BadRequest(
            "apnsToken must be lowercase hex".into(),
        ));
    }
    Ok(())
}

fn validate_apns_env(env: &str) -> AppResult<()> {
    match env {
        "sandbox" | "production" => Ok(()),
        _ => Err(AppError::BadRequest(
            "apnsEnv must be 'sandbox' or 'production'".into(),
        )),
    }
}

fn short_id(id: &str) -> &str {
    let end = id.len().min(8);
    &id[..end]
}
