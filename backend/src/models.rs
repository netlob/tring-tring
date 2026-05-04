use rand::rngs::OsRng;
use rand::RngCore;
use serde::Serialize;
use time::OffsetDateTime;

#[derive(Debug, Serialize, sqlx::FromRow)]
pub struct User {
    pub id: String,
    pub apple_user_sub: String,
    pub email: Option<String>,
    pub is_private_email: bool,
    pub created_at: i64,
    pub last_seen_at: i64,
}

const BASE62: &[u8; 62] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

/// 32 chars from `[0-9A-Za-z]`, CSPRNG, rejection-sampled to avoid modulo bias.
pub fn generate_user_id() -> String {
    // Reject bytes >= 248 (256 - 256 % 62 = 256 - 8 = 248) so the remaining
    // 248 outcomes (4 full cycles of 62) map uniformly onto the alphabet.
    const REJECT_THRESHOLD: u8 = 248;
    let mut out = String::with_capacity(32);
    let mut buf = [0u8; 32];
    while out.len() < 32 {
        OsRng.fill_bytes(&mut buf);
        for &b in buf.iter() {
            if b < REJECT_THRESHOLD {
                out.push(BASE62[(b % 62) as usize] as char);
                if out.len() == 32 {
                    break;
                }
            }
        }
    }
    out
}

pub fn now_unix() -> i64 {
    OffsetDateTime::now_utc().unix_timestamp()
}
