use std::env;

#[derive(Debug, Clone)]
pub struct Config {
    pub listen_addr: String,
    pub database_url: String,
    pub public_base_url: String,
    pub rate_limit_per_minute: u32,
    pub monthly_quota: u64,
    pub apns: ApnsConfig,
}

#[derive(Debug, Clone)]
pub struct ApnsConfig {
    pub key_path: String,
    pub key_id: String,
    pub team_id: String,
    pub bundle_id: String,
    pub env: ApnsEnv,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApnsEnv {
    Sandbox,
    Production,
}

impl Config {
    pub fn from_env() -> anyhow::Result<Self> {
        Ok(Self {
            listen_addr: env::var("LISTEN_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".into()),
            database_url: required("DATABASE_URL")?,
            public_base_url: required("PUBLIC_BASE_URL")?,
            rate_limit_per_minute: parse_or_default("RATE_LIMIT_PER_MINUTE", 10)?,
            monthly_quota: parse_or_default("MONTHLY_QUOTA", 100_000)?,
            apns: ApnsConfig::from_env()?,
        })
    }
}

impl ApnsConfig {
    fn from_env() -> anyhow::Result<Self> {
        Ok(Self {
            key_path: required("APNS_KEY_PATH")?,
            key_id: required("APNS_KEY_ID")?,
            team_id: required("APNS_TEAM_ID")?,
            bundle_id: required("APNS_BUNDLE_ID")?,
            env: match required("APNS_ENV")?.as_str() {
                "sandbox" => ApnsEnv::Sandbox,
                "production" => ApnsEnv::Production,
                other => anyhow::bail!("APNS_ENV must be 'sandbox' or 'production', got '{other}'"),
            },
        })
    }
}

fn required(key: &str) -> anyhow::Result<String> {
    env::var(key).map_err(|_| anyhow::anyhow!("missing required env var: {key}"))
}

fn parse_or_default<T: std::str::FromStr>(key: &str, default: T) -> anyhow::Result<T>
where
    T::Err: std::fmt::Display,
{
    match env::var(key) {
        Ok(v) => v
            .parse()
            .map_err(|e| anyhow::anyhow!("env {key}: parse error: {e}")),
        Err(_) => Ok(default),
    }
}
