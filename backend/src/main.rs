mod apns;
mod config;
mod db;
mod delay;
mod dispatch;
mod error;
mod middleware;
mod models;
mod rate_limit;
mod retention;
mod routes;
mod runner;
mod scheduler;
mod siwa;
mod templates;

use std::env;
use std::sync::Arc;
use std::time::Duration;

use axum::middleware::from_fn_with_state;
use axum::routing::{delete, get, post};
use axum::Router;
use sqlx::SqlitePool;
use tokio::net::TcpListener;
use tokio::signal;
use tower_http::trace::TraceLayer;

use crate::apns::ApnsClient;
use crate::config::Config;
use crate::middleware::require_bearer;
use crate::rate_limit::RateLimiter;
use crate::siwa::AppleVerifier;

#[derive(Clone)]
pub struct AppState {
    pub db: SqlitePool,
    pub config: Arc<Config>,
    pub apns: ApnsClient,
    pub rate_limiter: Arc<RateLimiter>,
    pub siwa: Arc<AppleVerifier>,
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

    let apns =
        ApnsClient::new(&cfg.apns).map_err(|e| anyhow::anyhow!("apns client init failed: {e}"))?;
    tracing::info!("apns client initialized");

    let rate_limiter = Arc::new(RateLimiter::new(cfg.rate_limit_per_minute));

    let siwa = Arc::new(AppleVerifier::new(cfg.apns.bundle_id.clone()));
    tracing::info!("apple verifier initialized");

    let litestream_enabled = env::var("LITESTREAM_REPLICA_URL")
        .map(|v| !v.is_empty())
        .unwrap_or(false);
    if litestream_enabled {
        tracing::info!("litestream: enabled (replication active out-of-process)");
    } else {
        tracing::warn!(
            "litestream: disabled — set LITESTREAM_REPLICA_URL to enable off-host backups"
        );
    }

    let _retention_handle = retention::spawn(db.clone());
    tracing::info!("retention task spawned");

    let state = AppState {
        db,
        config: Arc::new(cfg),
        apns,
        rate_limiter,
        siwa,
        litestream_enabled,
    };

    let _scheduler_handle = scheduler::spawn(state.clone(), Duration::from_secs(1));
    tracing::info!("scheduler task spawned");

    // Bearer-auth-protected /v1/* routes (ADR-0019). The webhook endpoint and
    // POST /v1/devices stay outside this subrouter — the webhook authenticates
    // via the userId-as-path-secret model and /v1/devices uses SIWA.
    let bearer_routes = Router::new()
        .route("/v1/users/:user_id", get(routes::devices::get_user_by_id))
        .route(
            "/v1/users/:user_id/notifications",
            get(routes::listing::list_notifications),
        )
        .route(
            "/v1/users/:user_id/submittedNotifications/:external_id",
            delete(routes::scheduled::cancel_submitted),
        )
        .route(
            "/v1/users/:user_id/actions/run",
            post(routes::actions::run_pending_action),
        )
        .route(
            "/v1/users/:user_id/templates",
            get(routes::templates::list_templates),
        )
        .route(
            "/v1/users/:user_id/templates/:name",
            get(routes::templates::get_template)
                .put(routes::templates::put_template)
                .delete(routes::templates::delete_template),
        )
        .route("/v1/execute", post(routes::execute::execute))
        .route_layer(from_fn_with_state(state.clone(), require_bearer));

    let app = Router::new()
        .route("/healthz", get(routes::health::healthz))
        .route("/v1/devices", post(routes::devices::register_device))
        .route(
            "/:user_id/notifications/:name",
            post(routes::notify::notify_post).get(routes::notify::notify_get),
        )
        .merge(bearer_routes)
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
