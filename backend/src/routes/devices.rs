use axum::extract::{Path, State};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::error::{AppError, AppResult};
use crate::models::{self, User};
use crate::AppState;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterDeviceRequest {
    pub apple_identity_token: String,
    pub raw_nonce: String,
    pub apns_token: String,
    pub apns_env: String,
    #[serde(default)]
    pub device_name: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterDeviceResponse {
    pub user_id: String,
    pub webhook_url: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceSummary {
    pub device_id: String,
    pub device_name: Option<String>,
    pub apns_env: String,
    pub created_at: i64,
    pub last_seen_at: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LogEntry {
    pub id: i64,
    pub device_id: Option<String>,
    pub name: Option<String>,
    pub status: String,
    pub apns_status: Option<i64>,
    pub apns_reason: Option<String>,
    pub sent_at: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UserDetailsResponse {
    pub user_id: String,
    pub apple_user_sub: String,
    pub email: Option<String>,
    pub is_private_email: bool,
    pub created_at: i64,
    pub last_seen_at: i64,
    pub devices: Vec<DeviceSummary>,
    pub recent_log: Vec<LogEntry>,
}

#[tracing::instrument(skip(state, payload))]
pub async fn register_device(
    State(state): State<AppState>,
    Json(payload): Json<RegisterDeviceRequest>,
) -> AppResult<Json<RegisterDeviceResponse>> {
    validate_apns_token(&payload.apns_token)?;
    validate_apns_env(&payload.apns_env)?;

    let claims = state
        .siwa
        .verify(&payload.apple_identity_token, &payload.raw_nonce)
        .await
        .map_err(|e| {
            tracing::warn!(error = %e, "siwa verification failed");
            AppError::Unauthorized
        })?;

    let now = models::now_unix();

    let existing: Option<User> = sqlx::query_as::<_, User>(
        "SELECT id, apple_user_sub, email, is_private_email, created_at, last_seen_at \
         FROM users WHERE apple_user_sub = ?",
    )
    .bind(&claims.sub)
    .fetch_optional(&state.db)
    .await?;

    let user_id = match existing {
        Some(user) => {
            sqlx::query("UPDATE users SET last_seen_at = ? WHERE id = ?")
                .bind(now)
                .bind(&user.id)
                .execute(&state.db)
                .await?;
            user.id
        }
        None => {
            let new_id = models::generate_user_id();
            let is_private = if claims.is_private_email {
                1_i64
            } else {
                0_i64
            };
            sqlx::query(
                "INSERT INTO users (id, apple_user_sub, email, is_private_email, created_at, last_seen_at) \
                 VALUES (?, ?, ?, ?, ?, ?)",
            )
            .bind(&new_id)
            .bind(&claims.sub)
            .bind(&claims.email)
            .bind(is_private)
            .bind(now)
            .bind(now)
            .execute(&state.db)
            .await?;
            new_id
        }
    };

    let existing_device: Option<(String, String)> = sqlx::query_as::<_, (String, String)>(
        "SELECT id, user_id FROM devices WHERE apns_token = ?",
    )
    .bind(&payload.apns_token)
    .fetch_optional(&state.db)
    .await?;

    let device_id = match existing_device {
        Some((id, _prior_user_id)) => {
            sqlx::query(
                "UPDATE devices SET user_id = ?, apns_env = ?, device_name = ?, last_seen_at = ? \
                 WHERE id = ?",
            )
            .bind(&user_id)
            .bind(&payload.apns_env)
            .bind(&payload.device_name)
            .bind(now)
            .bind(&id)
            .execute(&state.db)
            .await?;
            id
        }
        None => {
            let new_device_id = uuid::Uuid::new_v4().to_string();
            sqlx::query(
                "INSERT INTO devices (id, user_id, apns_token, apns_env, device_name, created_at, last_seen_at) \
                 VALUES (?, ?, ?, ?, ?, ?, ?)",
            )
            .bind(&new_device_id)
            .bind(&user_id)
            .bind(&payload.apns_token)
            .bind(&payload.apns_env)
            .bind(&payload.device_name)
            .bind(now)
            .bind(now)
            .execute(&state.db)
            .await?;
            new_device_id
        }
    };

    let base = state.config.public_base_url.trim_end_matches('/');
    let webhook_url = format!("{base}/{user_id}/notifications/example");

    tracing::info!(
        user_id_prefix = %short_id(&user_id),
        device_id_prefix = %short_id(&device_id),
        "device registered"
    );

    Ok(Json(RegisterDeviceResponse {
        user_id,
        webhook_url,
    }))
}

#[tracing::instrument(skip(state))]
pub async fn get_user_by_id(
    State(state): State<AppState>,
    Path(user_id): Path<String>,
) -> AppResult<Json<UserDetailsResponse>> {
    let user: User = sqlx::query_as::<_, User>(
        "SELECT id, apple_user_sub, email, is_private_email, created_at, last_seen_at \
         FROM users WHERE id = ?",
    )
    .bind(&user_id)
    .fetch_optional(&state.db)
    .await?
    .ok_or(AppError::NotFound)?;

    let devices: Vec<DeviceSummary> = sqlx::query_as::<_, DeviceSummary>(
        "SELECT id AS device_id, device_name, apns_env, created_at, last_seen_at \
         FROM devices WHERE user_id = ? ORDER BY created_at ASC",
    )
    .bind(&user.id)
    .fetch_all(&state.db)
    .await?;

    let recent_log: Vec<LogEntry> = sqlx::query_as::<_, LogEntry>(
        "SELECT id, device_id, name, status, apns_status, apns_reason, sent_at \
         FROM notifications_log WHERE user_id = ? ORDER BY sent_at DESC LIMIT 50",
    )
    .bind(&user.id)
    .fetch_all(&state.db)
    .await?;

    let now = models::now_unix();
    sqlx::query("UPDATE users SET last_seen_at = ? WHERE id = ?")
        .bind(now)
        .bind(&user.id)
        .execute(&state.db)
        .await?;

    tracing::info!(
        user_id_prefix = %short_id(&user.id),
        device_count = devices.len(),
        log_count = recent_log.len(),
        "user details fetched"
    );

    Ok(Json(UserDetailsResponse {
        user_id: user.id,
        apple_user_sub: user.apple_user_sub,
        email: user.email,
        is_private_email: user.is_private_email,
        created_at: user.created_at,
        last_seen_at: now,
        devices,
        recent_log,
    }))
}

impl<'r> sqlx::FromRow<'r, sqlx::sqlite::SqliteRow> for DeviceSummary {
    fn from_row(row: &'r sqlx::sqlite::SqliteRow) -> sqlx::Result<Self> {
        use sqlx::Row;
        Ok(DeviceSummary {
            device_id: row.try_get("device_id")?,
            device_name: row.try_get("device_name")?,
            apns_env: row.try_get("apns_env")?,
            created_at: row.try_get("created_at")?,
            last_seen_at: row.try_get("last_seen_at")?,
        })
    }
}

impl<'r> sqlx::FromRow<'r, sqlx::sqlite::SqliteRow> for LogEntry {
    fn from_row(row: &'r sqlx::sqlite::SqliteRow) -> sqlx::Result<Self> {
        use sqlx::Row;
        Ok(LogEntry {
            id: row.try_get("id")?,
            device_id: row.try_get("device_id")?,
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
    let end = id.char_indices().nth(8).map(|(i, _)| i).unwrap_or(id.len());
    &id[..end]
}
