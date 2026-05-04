//! APNs delivery wrapper around the `a2` crate.
//!
//! Owns a single long-lived `a2::Client` per process (token-based JWT auth);
//! see ADR-0007. Construct once in `main` and clone the [`ApnsClient`] handle
//! into `AppState`.

use std::fs::File;
use std::sync::Arc;

use a2::{
    Client, ClientConfig, CollapseId, DefaultNotificationBuilder, Endpoint, Error as A2Error,
    ErrorReason, NotificationBuilder, NotificationOptions, Priority, PushType,
};
use serde::Serialize;
use serde_json::{Map, Value};
use thiserror::Error;

use crate::config::{ApnsConfig, ApnsEnv};

/// Cloneable handle to the shared APNs client.
#[derive(Clone)]
pub struct ApnsClient {
    inner: Arc<Inner>,
}

struct Inner {
    client: Client,
    bundle_id: String,
}

/// Per-action data spliced into the APNs `userInfo` under `actions[]`.
/// See ADR-0016. The `pending_action_id` field is set only when the action's
/// `runOnServer` flag was true and the dispatcher persisted a row in
/// `pending_actions` keyed on this UUID.
#[derive(Debug, Clone, Serialize)]
pub struct ApnsActionInfo {
    pub identifier: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input: Option<String>,
    #[serde(rename = "keepNotification")]
    pub keep_notification: bool,
    #[serde(rename = "runOnServer")]
    pub run_on_server: bool,
    #[serde(rename = "pendingActionId", skip_serializing_if = "Option::is_none")]
    pub pending_action_id: Option<String>,
}

/// User-facing payload assembled from a webhook request.
#[derive(Debug, Clone)]
pub struct ApnsPayload {
    /// Notification name — used as `apns-collapse-id` and likely echoed to the
    /// iOS app via `aps.thread-id` if `thread_id` is `None`.
    pub name: String,
    pub title: Option<String>,
    pub body: Option<String>,
    /// Pushcut sound name passed through verbatim. `None` means silent (the
    /// `vibrateOnly` case is mapped to `None` by the caller). iOS resolves
    /// `<name>.caf` from the bundle on its side; unknown names fall back to
    /// the system default sound (ADR-0013).
    pub sound: Option<String>,
    pub thread_id: Option<String>,
    pub time_sensitive: bool,
    pub default_url: Option<String>,
    pub input: Option<String>,
    pub image_url: Option<String>,
    pub image_data: Option<String>,
    pub category: Option<String>,
    pub actions: Option<Vec<ApnsActionInfo>>,
    pub extra_user_info: Option<Map<String, Value>>,
}

/// Outcome of a single send attempt that reached APNs (success or rejection).
#[derive(Debug, Clone)]
pub struct ApnsSendOutcome {
    pub apns_status: u16,
    pub apns_reason: Option<String>,
}

/// Errors emitted by [`ApnsClient::send`].
#[derive(Debug, Error)]
pub enum ApnsError {
    /// The device token is no longer valid — the caller should delete the
    /// device row. Maps APNs `Unregistered` (HTTP 410) and `BadDeviceToken`.
    #[error("device token rejected by APNs: {reason} (status {status})")]
    DeviceGone { status: u16, reason: String },

    /// Other client-side (4xx) failure — operator misconfiguration or bad
    /// payload. Not retryable without a code/config change.
    #[error("APNs client error {status}: {reason}")]
    ClientError { status: u16, reason: String },

    /// Apple returned a 5xx — transient; the caller may retry later.
    #[error("APNs server error {status}: {reason}")]
    ServerError { status: u16, reason: String },

    /// Network / TLS / signing problem before or instead of an HTTP response.
    #[error("APNs transport error: {0}")]
    Transport(String),

    /// The collapse id (notification name) was rejected as invalid.
    #[error("invalid notification name: {0}")]
    InvalidName(String),
}

impl ApnsClient {
    /// Construct the single per-process client. Opens a long-lived HTTP/2
    /// connection lazily on first send.
    pub fn new(cfg: &ApnsConfig) -> Result<Self, ApnsError> {
        let endpoint = match cfg.env {
            ApnsEnv::Sandbox => Endpoint::Sandbox,
            ApnsEnv::Production => Endpoint::Production,
        };

        let mut key_file = File::open(&cfg.key_path)
            .map_err(|e| ApnsError::Transport(format!("open APNs key: {e}")))?;

        let client = Client::token(
            &mut key_file,
            cfg.key_id.clone(),
            cfg.team_id.clone(),
            ClientConfig::new(endpoint),
        )
        .map_err(map_init_error)?;

        Ok(Self {
            inner: Arc::new(Inner {
                client,
                bundle_id: cfg.bundle_id.clone(),
            }),
        })
    }

    /// Send one notification. Bundle id, priority, and push type are fixed by
    /// this wrapper; everything else comes from `payload`.
    #[tracing::instrument(skip(self, payload), fields(name = %payload.name))]
    pub async fn send(
        &self,
        device_token: &str,
        payload: ApnsPayload,
    ) -> Result<ApnsSendOutcome, ApnsError> {
        let collapse = CollapseId::new(payload.name.as_str())
            .map_err(|e| ApnsError::InvalidName(e.to_string()))?;

        let options = NotificationOptions {
            apns_priority: Some(Priority::High),
            apns_topic: Some(self.inner.bundle_id.as_str()),
            apns_push_type: Some(PushType::Alert),
            apns_collapse_id: Some(collapse),
            ..Default::default()
        };

        let needs_mutable = payload.image_url.is_some() || payload.image_data.is_some();

        let mut builder = DefaultNotificationBuilder::new();
        if needs_mutable {
            builder = builder.set_mutable_content();
        }
        if let Some(title) = payload.title.as_deref() {
            builder = builder.set_title(title);
        }
        if let Some(body) = payload.body.as_deref() {
            builder = builder.set_body(body);
        }
        if let Some(sound) = payload.sound.as_deref() {
            builder = builder.set_sound(sound);
        }
        if let Some(cat) = payload.category.as_deref() {
            builder = builder.set_category(cat);
        }

        let base = builder.build(device_token, options);

        // a2's public `APS` struct does not expose `interruption-level`,
        // `thread-id`, or `mutable-content` toggling at runtime; wrap the
        // built payload in our own type that adds those plus arbitrary
        // user-info keys at the root.
        let envelope = OurPayload {
            inner: base,
            interruption_level: payload.time_sensitive.then_some("time-sensitive"),
            thread_id: payload.thread_id.as_deref(),
            url: payload.default_url.as_deref(),
            input: payload.input.as_deref(),
            image_url: payload.image_url.as_deref(),
            image_data: payload.image_data.as_deref(),
            actions: payload.actions.as_deref(),
            extra_user_info: payload.extra_user_info.as_ref(),
        };

        match self.inner.client.send(envelope).await {
            Ok(resp) => {
                tracing::info!(
                    apns_status = resp.code,
                    apns_id = resp.apns_id.as_deref().unwrap_or(""),
                    "apns delivered"
                );
                Ok(ApnsSendOutcome {
                    apns_status: resp.code,
                    apns_reason: None,
                })
            }
            Err(e) => Err(map_send_error(e)),
        }
    }
}

/// Wraps an `a2::Payload` and serialises additional fields alongside it.
/// `interruption-level` and `thread-id` belong inside `aps`, so we re-emit
/// `aps` from scratch via a custom serializer that merges the two.
#[derive(Debug)]
struct OurPayload<'a> {
    inner: a2::request::payload::Payload<'a>,
    interruption_level: Option<&'static str>,
    thread_id: Option<&'a str>,
    url: Option<&'a str>,
    input: Option<&'a str>,
    image_url: Option<&'a str>,
    image_data: Option<&'a str>,
    actions: Option<&'a [ApnsActionInfo]>,
    extra_user_info: Option<&'a Map<String, Value>>,
}

impl<'a> serde::Serialize for OurPayload<'a> {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;

        // Re-serialize the inner aps as a Value so we can splice extra keys in.
        let mut aps_value =
            serde_json::to_value(&self.inner.aps).map_err(serde::ser::Error::custom)?;
        if let Value::Object(ref mut map) = aps_value {
            if let Some(level) = self.interruption_level {
                map.insert("interruption-level".into(), Value::String(level.into()));
            }
            if let Some(tid) = self.thread_id {
                map.insert("thread-id".into(), Value::String(tid.into()));
            }
        }

        let mut extra_keys = 0;
        if self.url.is_some() {
            extra_keys += 1;
        }
        if self.input.is_some() {
            extra_keys += 1;
        }
        if self.image_url.is_some() {
            extra_keys += 1;
        }
        if self.image_data.is_some() {
            extra_keys += 1;
        }
        if self.actions.is_some() {
            extra_keys += 1;
        }
        if let Some(extra) = self.extra_user_info {
            extra_keys += extra.len();
        }

        let mut map = serializer.serialize_map(Some(1 + self.inner.data.len() + extra_keys))?;
        map.serialize_entry("aps", &aps_value)?;
        for (k, v) in self.inner.data.iter() {
            map.serialize_entry(k, v)?;
        }
        if let Some(url) = self.url {
            map.serialize_entry("url", url)?;
        }
        if let Some(input) = self.input {
            map.serialize_entry("input", input)?;
        }
        if let Some(image_url) = self.image_url {
            map.serialize_entry("image-url", image_url)?;
        }
        if let Some(image_data) = self.image_data {
            map.serialize_entry("image-data", image_data)?;
        }
        if let Some(actions) = self.actions {
            map.serialize_entry("actions", actions)?;
        }
        if let Some(extra) = self.extra_user_info {
            for (k, v) in extra.iter() {
                map.serialize_entry(k, v)?;
            }
        }
        map.end()
    }
}

impl<'a> a2::request::payload::PayloadLike for OurPayload<'a> {
    fn get_device_token(&self) -> &str {
        self.inner.get_device_token()
    }

    fn get_options(&self) -> &NotificationOptions<'_> {
        self.inner.get_options()
    }
}

fn map_init_error(e: A2Error) -> ApnsError {
    // Initialisation only fails on bad key material / IO — treat as transport.
    ApnsError::Transport(format!("apns client init: {e}"))
}

fn map_send_error(e: A2Error) -> ApnsError {
    match e {
        A2Error::ResponseError(resp) => {
            let status = resp.code;
            let (reason_str, reason_enum) = match resp.error {
                Some(body) => (format!("{:?}", body.reason), Some(body.reason)),
                None => (format!("HTTP {status}"), None),
            };

            let is_device_gone = matches!(
                reason_enum,
                Some(ErrorReason::Unregistered) | Some(ErrorReason::BadDeviceToken)
            );

            if is_device_gone {
                ApnsError::DeviceGone {
                    status,
                    reason: reason_str,
                }
            } else if (500..600).contains(&status) {
                ApnsError::ServerError {
                    status,
                    reason: reason_str,
                }
            } else {
                ApnsError::ClientError {
                    status,
                    reason: reason_str,
                }
            }
        }
        A2Error::ConnectionError(e) => ApnsError::Transport(e.to_string()),
        A2Error::ClientError(e) => ApnsError::Transport(e.to_string()),
        A2Error::RequestTimeout(s) => ApnsError::Transport(format!("timeout after {s}s")),
        A2Error::SerializeError(e) => ApnsError::Transport(format!("serialize: {e}")),
        A2Error::SignerError(e) => ApnsError::Transport(format!("signer: {e}")),
        A2Error::BuildRequestError(e) => ApnsError::Transport(format!("build request: {e}")),
        other => ApnsError::Transport(other.to_string()),
    }
}

impl ApnsSendOutcome {
    /// Convenience for callers that want a single string for the
    /// `notifications_log.apns_reason` column.
    pub fn reason_or_ok(&self) -> &str {
        self.apns_reason.as_deref().unwrap_or("OK")
    }
}
