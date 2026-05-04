use std::str::FromStr;

use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous};
use sqlx::SqlitePool;

pub async fn connect(database_url: &str) -> anyhow::Result<SqlitePool> {
    let opts = SqliteConnectOptions::from_str(database_url)?
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Normal)
        .foreign_keys(true)
        .busy_timeout(std::time::Duration::from_secs(5));

    // SQLite is single-writer; a small pool is correct.
    let pool = SqlitePoolOptions::new()
        .max_connections(8)
        .connect_with(opts)
        .await?;

    sqlx::migrate!("./migrations").run(&pool).await?;

    let mode: String = sqlx::query_scalar("PRAGMA journal_mode")
        .fetch_one(&pool)
        .await?;
    if mode.to_lowercase() != "wal" {
        anyhow::bail!("expected WAL journal mode, got '{mode}' — refusing to start");
    }

    Ok(pool)
}
