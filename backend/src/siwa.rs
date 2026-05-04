//! Sign in with Apple identity-token verification.
//!
//! Implements ADR-0012: verifies an Apple-issued JWT against the JWKS at
//! `https://appleid.apple.com/auth/keys`, validates `iss`/`aud`/`exp`, and
//! checks that `claims.nonce == sha256_hex(raw_nonce)`.
//!
//! `AppleVerifier` is constructed once at startup; clone the `Arc` handle into
//! `AppState`. JWKS responses are cached for 24h and force-refreshed on a `kid`
//! miss.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use base64::Engine;
use jsonwebtoken::errors::ErrorKind as JwtErrorKind;
use jsonwebtoken::{decode, decode_header, Algorithm, DecodingKey, Validation};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use thiserror::Error;
use tokio::sync::RwLock;

const JWKS_URL: &str = "https://appleid.apple.com/auth/keys";
const JWKS_TTL: Duration = Duration::from_secs(24 * 60 * 60);
const APPLE_ISSUER: &str = "https://appleid.apple.com";
const HTTP_TIMEOUT: Duration = Duration::from_secs(5);

/// Verifier handle. Cheap to clone via `Arc`; share across requests.
pub struct AppleVerifier {
    audience: String,
    http: reqwest::Client,
    jwks: RwLock<JwksCache>,
}

/// Trusted claims extracted from a verified Apple identity token.
#[derive(Debug, Clone)]
pub struct AppleClaims {
    /// Stable per Apple ID per Team ID — primary key for our `users` table.
    pub sub: String,
    /// Only present on the user's first authentication for the app.
    pub email: Option<String>,
    /// `true` when Apple issued a private relay address; `false` otherwise.
    pub is_private_email: bool,
}

#[derive(Debug, Error)]
pub enum SiwaError {
    #[error("failed to fetch Apple JWKS: {0}")]
    JwksFetch(String),

    #[error("identity token header is missing 'kid'")]
    MissingKid,

    #[error("Apple JWKS does not contain key id {kid}")]
    UnknownKey { kid: String },

    #[error("identity token signature is invalid")]
    InvalidSignature,

    #[error("identity token is expired")]
    Expired,

    #[error("unexpected token issuer: {got}")]
    WrongIssuer { got: String },

    #[error("unexpected token audience: {got:?}")]
    WrongAudience { got: Option<String> },

    #[error("nonce does not match")]
    NonceMismatch,

    #[error("failed to decode identity token: {0}")]
    Decode(String),
}

struct JwksCache {
    keys: HashMap<String, ApplePublicKey>,
    fetched_at: Option<Instant>,
}

impl JwksCache {
    fn empty() -> Self {
        Self {
            keys: HashMap::new(),
            fetched_at: None,
        }
    }

    fn is_fresh(&self) -> bool {
        match self.fetched_at {
            Some(t) => t.elapsed() < JWKS_TTL,
            None => false,
        }
    }
}

#[derive(Deserialize)]
struct JwksResponse {
    keys: Vec<ApplePublicKey>,
}

#[derive(Deserialize, Clone)]
struct ApplePublicKey {
    kid: String,
    #[allow(dead_code)]
    kty: String,
    #[allow(dead_code)]
    alg: Option<String>,
    n: String,
    e: String,
}

#[derive(Deserialize)]
struct AppleClaimsRaw {
    sub: String,
    nonce: Option<String>,
    email: Option<String>,
    #[serde(default, deserialize_with = "deserialize_bool_string")]
    is_private_email: bool,
}

/// Apple's `is_private_email` quirk: documented as a string `"true"`/`"false"`,
/// but some flows have shipped it as a real boolean. Accept both.
fn deserialize_bool_string<'de, D>(deserializer: D) -> Result<bool, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de::Error;

    #[derive(Deserialize)]
    #[serde(untagged)]
    enum BoolOrString {
        Bool(bool),
        String(String),
    }

    match Option::<BoolOrString>::deserialize(deserializer)? {
        None => Ok(false),
        Some(BoolOrString::Bool(b)) => Ok(b),
        Some(BoolOrString::String(s)) => match s.as_str() {
            "true" => Ok(true),
            "false" => Ok(false),
            other => Err(D::Error::custom(format!(
                "is_private_email: expected 'true' or 'false', got {other:?}"
            ))),
        },
    }
}

impl AppleVerifier {
    /// Construct once at startup. `audience` should equal the iOS bundle id.
    pub fn new(audience: String) -> Self {
        let http = reqwest::Client::builder()
            .timeout(HTTP_TIMEOUT)
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());

        Self {
            audience,
            http,
            jwks: RwLock::new(JwksCache::empty()),
        }
    }

    /// Verify an Apple identity token plus the original raw nonce, returning
    /// the trusted claims on success. All failure modes are normal user input
    /// errors — callers should map to HTTP 401.
    pub async fn verify(
        &self,
        identity_token: &str,
        raw_nonce: &str,
    ) -> Result<AppleClaims, SiwaError> {
        let header = decode_header(identity_token).map_err(|e| SiwaError::Decode(e.to_string()))?;

        if header.alg != Algorithm::RS256 {
            return Err(SiwaError::Decode(format!(
                "unexpected JWT alg: {:?}",
                header.alg
            )));
        }
        let kid = header.kid.ok_or(SiwaError::MissingKid)?;

        let jwk = self.lookup_key(&kid).await?;

        let decoding_key = DecodingKey::from_rsa_components(&jwk.n, &jwk.e)
            .map_err(|e| SiwaError::Decode(format!("jwk components: {e}")))?;

        let mut validation = Validation::new(Algorithm::RS256);
        validation.set_issuer(&[APPLE_ISSUER]);
        validation.set_audience(std::slice::from_ref(&self.audience));

        let token_data = decode::<AppleClaimsRaw>(identity_token, &decoding_key, &validation)
            .map_err(|e| match e.kind() {
                JwtErrorKind::ExpiredSignature => SiwaError::Expired,
                JwtErrorKind::InvalidIssuer => SiwaError::WrongIssuer {
                    got: peek_unverified_issuer(identity_token).unwrap_or_default(),
                },
                JwtErrorKind::InvalidAudience => SiwaError::WrongAudience {
                    got: peek_unverified_audience(identity_token),
                },
                JwtErrorKind::InvalidSignature | JwtErrorKind::InvalidToken => {
                    SiwaError::InvalidSignature
                }
                _ => SiwaError::Decode(e.to_string()),
            })?;

        let claims = token_data.claims;

        let expected_nonce = hex::encode(Sha256::digest(raw_nonce.as_bytes()));
        let supplied_nonce = claims.nonce.as_deref().unwrap_or("");
        if !constant_time_eq(expected_nonce.as_bytes(), supplied_nonce.as_bytes()) {
            return Err(SiwaError::NonceMismatch);
        }

        Ok(AppleClaims {
            sub: claims.sub,
            email: claims.email,
            is_private_email: claims.is_private_email,
        })
    }

    /// Look up `kid` in the cache. If missing or stale, force-refresh once and
    /// retry. A second miss yields `UnknownKey`.
    async fn lookup_key(&self, kid: &str) -> Result<ApplePublicKey, SiwaError> {
        {
            let cache = self.jwks.read().await;
            if cache.is_fresh() {
                if let Some(k) = cache.keys.get(kid) {
                    return Ok(k.clone());
                }
            }
        }

        tracing::warn!(kid = %kid, "JWKS cache miss or stale; refreshing");
        self.refresh_jwks().await?;

        let cache = self.jwks.read().await;
        match cache.keys.get(kid) {
            Some(k) => Ok(k.clone()),
            None => Err(SiwaError::UnknownKey {
                kid: kid.to_string(),
            }),
        }
    }

    async fn refresh_jwks(&self) -> Result<(), SiwaError> {
        let mut cache = self.jwks.write().await;
        if cache.is_fresh() {
            return Ok(());
        }

        let resp = self
            .http
            .get(JWKS_URL)
            .send()
            .await
            .map_err(|e| SiwaError::JwksFetch(e.to_string()))?
            .error_for_status()
            .map_err(|e| SiwaError::JwksFetch(e.to_string()))?
            .json::<JwksResponse>()
            .await
            .map_err(|e| SiwaError::JwksFetch(e.to_string()))?;

        let key_count = resp.keys.len();
        cache.keys = resp.keys.into_iter().map(|k| (k.kid.clone(), k)).collect();
        cache.fetched_at = Some(Instant::now());

        tracing::info!(keys = key_count, "refreshed Apple JWKS");
        Ok(())
    }
}

/// Constant-time byte compare. The verified nonce is not strictly secret, but
/// avoiding early-out comparison costs us nothing.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff: u8 = 0;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// Decode-only peek at the JWT payload for use in `WrongIssuer { got }`. Never
/// trust the returned value for authorization — it isn't signature-checked.
#[derive(Deserialize)]
struct PayloadPeek {
    iss: Option<String>,
    aud: Option<serde_json::Value>,
}

fn decode_payload_peek(token: &str) -> Option<PayloadPeek> {
    let mut parts = token.split('.');
    let _header = parts.next()?;
    let payload_b64 = parts.next()?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload_b64)
        .ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn peek_unverified_issuer(token: &str) -> Option<String> {
    decode_payload_peek(token).and_then(|p| p.iss)
}

fn peek_unverified_audience(token: &str) -> Option<String> {
    let peek = decode_payload_peek(token)?;
    match peek.aud? {
        serde_json::Value::String(s) => Some(s),
        serde_json::Value::Array(arr) => arr.into_iter().find_map(|v| match v {
            serde_json::Value::String(s) => Some(s),
            _ => None,
        }),
        _ => None,
    }
}
