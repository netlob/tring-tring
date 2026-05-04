use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use rand::rngs::OsRng;
use rand::RngCore;
use serde::Serialize;
use time::OffsetDateTime;

#[derive(Debug, Serialize, sqlx::FromRow)]
pub struct Device {
    pub id: String,
    pub webhook_secret: String,
    pub apns_token: String,
    pub apns_env: String,
    pub device_name: Option<String>,
    pub created_at: i64,
    pub last_seen_at: i64,
}

pub fn generate_webhook_secret() -> String {
    let mut bytes = [0u8; 32];
    OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

pub fn now_unix() -> i64 {
    OffsetDateTime::now_utc().unix_timestamp()
}
