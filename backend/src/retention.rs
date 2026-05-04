use std::time::Duration;

use sqlx::Row;
use sqlx::SqlitePool;
use tokio::task::JoinHandle;

const RETENTION_SECONDS: i64 = 90 * 24 * 60 * 60;
const SLEEP_INTERVAL: Duration = Duration::from_secs(24 * 60 * 60);

/// Spawn the retention task. Returns the JoinHandle so the caller can
/// abort it on shutdown.
pub fn spawn(pool: SqlitePool) -> JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            // Sleep first: avoid surprising deletes immediately after a restore.
            tokio::time::sleep(SLEEP_INTERVAL).await;

            if let Err(err) = run_once(&pool).await {
                tracing::error!(error = %err, "retention: iteration failed");
            }
        }
    })
}

async fn run_once(pool: &SqlitePool) -> Result<(), sqlx::Error> {
    let cutoff = current_unix_seconds() - RETENTION_SECONDS;

    let result = sqlx::query("DELETE FROM notifications_log WHERE sent_at < ?")
        .bind(cutoff)
        .execute(pool)
        .await?;

    let deleted = result.rows_affected();

    let row = sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
        .fetch_one(pool)
        .await?;

    // PRAGMA wal_checkpoint returns: busy (0/1), log frames, checkpointed frames.
    let busy: i64 = row.try_get(0).unwrap_or(-1);
    let log_frames: i64 = row.try_get(1).unwrap_or(-1);
    let checkpointed: i64 = row.try_get(2).unwrap_or(-1);

    tracing::info!(
        deleted_rows = deleted,
        cutoff_unix = cutoff,
        checkpoint_busy = busy,
        checkpoint_log_frames = log_frames,
        checkpoint_pages = checkpointed,
        "retention: pruned notifications_log and checkpointed WAL"
    );

    Ok(())
}

fn current_unix_seconds() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
