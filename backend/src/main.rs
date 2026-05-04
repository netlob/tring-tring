mod apns;
mod config;
mod db;
mod error;
mod models;
mod rate_limit;
mod retention;
mod routes;

use std::env;
use std::sync::Arc;

use axum::routing::{get, post};
use axum::Router;
use sqlx::SqlitePool;
use tokio::net::TcpListener;
use tokio::signal;
use tower_http::trace::TraceLayer;

use crate::apns::ApnsClient;
use crate::config::Config;
use crate::rate_limit::RateLimiter;

#[derive(Clone)]
pub struct AppState {
    pub db: SqlitePool,
    pub config: Arc<Config>,
    pub apns: ApnsClient,
    pub rate_limiter: Arc<RateLimiter>,
    pub litestream_enabled: bool,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let _ = dotenvy::dotenv();
    init_tracing();

    let cfg = Config::from_env()?;
    let listen_addr = cfg.listen_addr.clone();
    let db_url = cfg.database_url.clone();

    tracing::info!(
        bundle = %cfg.apns.bundle_id,
        env = ?cfg.apns.env,
        rate_limit_per_minute = cfg.rate_limit_per_minute,
        monthly_quota = cfg.monthly_quota,
        "starting tring-tring"
    );

    let db = db::connect(&db_url).await?;
    tracing::info!("database ready (WAL mode, migrations applied)");

    let apns = ApnsClient::new(&cfg.apns)
        .map_err(|e| anyhow::anyhow!("apns client init failed: {e}"))?;
    tracing::info!("apns client initialized");

    let rate_limiter = Arc::new(RateLimiter::new(cfg.rate_limit_per_minute));

    let litestream_enabled = env::var("LITESTREAM_REPLICA_URL")
        .map(|v| !v.is_empty())
        .unwrap_or(false);
    if litestream_enabled {
        tracing::info!("litestream: enabled (replication active out-of-process)");
    } else {
        tracing::warn!("litestream: disabled — set LITESTREAM_REPLICA_URL to enable off-host backups");
    }

    let _retention_handle = retention::spawn(db.clone());
    tracing::info!("retention task spawned");

    let state = AppState {
        db,
        config: Arc::new(cfg),
        apns,
        rate_limiter,
        litestream_enabled,
    };

    let app = Router::new()
        .route("/healthz", get(routes::health::healthz))
        .route("/v1/devices", post(routes::devices::register_device))
        .route("/v1/devices/:secret", get(routes::devices::get_device_by_secret))
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let listener = TcpListener::bind(&listen_addr).await?;
    tracing::info!(addr = %listen_addr, "listening");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    Ok(())
}

fn init_tracing() {
    use tracing_subscriber::{fmt, prelude::*, EnvFilter};
    tracing_subscriber::registry()
        .with(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .with(fmt::layer().with_target(false))
        .init();
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = signal::ctrl_c().await;
    };

    #[cfg(unix)]
    let terminate = async {
        let _ = signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("install SIGTERM handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => tracing::info!("received SIGINT, shutting down"),
        _ = terminate => tracing::info!("received SIGTERM, shutting down"),
    }
}
