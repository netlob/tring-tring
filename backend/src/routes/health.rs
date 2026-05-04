use axum::extract::State;
use axum::Json;
use serde::Serialize;
use sqlx::SqlitePool;

use crate::AppState;

#[derive(Serialize)]
pub struct Health {
    status: &'static str,
    db: &'static str,
    replication: &'static str,
}

pub async fn healthz(State(state): State<AppState>) -> Json<Health> {
    let db_ok = ping(&state.db).await.is_ok();
    let replication = if state.litestream_enabled {
        "enabled"
    } else {
        "disabled"
    };
    Json(Health {
        status: if db_ok { "ok" } else { "degraded" },
        db: if db_ok { "ok" } else { "error" },
        replication,
    })
}

async fn ping(pool: &SqlitePool) -> sqlx::Result<()> {
    sqlx::query_scalar::<_, i32>("SELECT 1")
        .fetch_one(pool)
        .await?;
    Ok(())
}
