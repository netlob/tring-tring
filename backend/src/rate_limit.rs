use std::num::NonZeroU32;
use std::sync::Arc;

use dashmap::DashMap;
use governor::clock::DefaultClock;
use governor::state::{InMemoryState, NotKeyed};
use governor::{Quota, RateLimiter as GovRateLimiter};
use time::format_description::FormatItem;
use time::macros::format_description;
use time::OffsetDateTime;

use crate::error::{AppError, AppResult};

type DeviceLimiter = GovRateLimiter<NotKeyed, InMemoryState, DefaultClock>;

// In-memory only for v1; the `rate_limit_buckets` table is reserved for a
// future ADR if cross-restart rate limits become necessary.
pub struct RateLimiter {
    quota: Quota,
    buckets: DashMap<String, Arc<DeviceLimiter>>,
}

impl RateLimiter {
    pub fn new(per_minute: u32) -> Self {
        let n = NonZeroU32::new(per_minute).unwrap_or_else(|| NonZeroU32::new(1).unwrap());
        Self {
            quota: Quota::per_minute(n),
            buckets: DashMap::new(),
        }
    }

    /// In-memory token-bucket check keyed on the caller-supplied identifier.
    /// Per ADR-0012, callers pass `user_id`; the limiter itself is opaque to
    /// the meaning of the key.
    pub fn check(&self, key: &str) -> AppResult<()> {
        let limiter = if let Some(existing) = self.buckets.get(key) {
            existing.clone()
        } else {
            self.buckets
                .entry(key.to_string())
                .or_insert_with(|| Arc::new(GovRateLimiter::direct(self.quota)))
                .clone()
        };

        match limiter.check() {
            Ok(()) => Ok(()),
            Err(_) => {
                tracing::debug!(user_prefix = %short_id(key), "rate limited");
                Err(AppError::RateLimited)
            }
        }
    }
}

const MONTH_FMT: &[FormatItem<'_>] = format_description!("[year]-[month]");

fn current_month_utc() -> String {
    OffsetDateTime::now_utc()
        .format(MONTH_FMT)
        .unwrap_or_else(|_| "0000-00".to_string())
}

fn short_id(id: &str) -> &str {
    let end = id.char_indices().nth(8).map(|(i, _)| i).unwrap_or(id.len());
    &id[..end]
}

pub async fn check_monthly_quota(
    pool: &sqlx::SqlitePool,
    user_id: &str,
    monthly_quota: u64,
) -> AppResult<()> {
    let month = current_month_utc();

    let count: Option<i64> =
        sqlx::query_scalar("SELECT sent_count FROM monthly_usage WHERE user_id = ? AND month = ?")
            .bind(user_id)
            .bind(&month)
            .fetch_optional(pool)
            .await?;

    let used = count.unwrap_or(0).max(0) as u64;
    if used >= monthly_quota {
        tracing::info!(
            user_prefix = %short_id(user_id),
            month = %month,
            used,
            quota = monthly_quota,
            "monthly quota exceeded"
        );
        return Err(AppError::QuotaExceeded);
    }
    Ok(())
}

/// Insert a single row into notifications_log. Use one call per device on
/// a fan-out webhook. Returns immediately on insert (no transaction).
#[allow(clippy::too_many_arguments)]
pub async fn record_log_row(
    pool: &sqlx::SqlitePool,
    user_id: &str,
    device_id: Option<&str>,
    name: Option<&str>,
    status: &str,
    apns_status: Option<i64>,
    apns_reason: Option<&str>,
    now_unix: i64,
) -> sqlx::Result<()> {
    sqlx::query(
        "INSERT INTO notifications_log (user_id, device_id, name, status, apns_status, apns_reason, sent_at) \
         VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(user_id)
    .bind(device_id)
    .bind(name)
    .bind(status)
    .bind(apns_status)
    .bind(apns_reason)
    .bind(now_unix)
    .execute(pool)
    .await?;
    Ok(())
}

/// UPSERT one increment to monthly_usage for the user / current UTC month.
/// Call exactly once per webhook, only if at least one device delivery
/// succeeded (`status='sent'` for at least one fan-out target). Per
/// ADR-0008-amended: counter increments once per webhook, not per device.
pub async fn increment_monthly_usage(
    pool: &sqlx::SqlitePool,
    user_id: &str,
    _now_unix: i64,
) -> sqlx::Result<()> {
    let month = current_month_utc();
    sqlx::query(
        "INSERT INTO monthly_usage (user_id, month, sent_count) VALUES (?, ?, 1) \
         ON CONFLICT (user_id, month) DO UPDATE SET sent_count = sent_count + 1",
    )
    .bind(user_id)
    .bind(&month)
    .execute(pool)
    .await?;
    Ok(())
}
