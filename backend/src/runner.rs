//! Run-on-server URL execution with SSRF guards (ADR-0017).
//!
//! Executes an arbitrary outbound HTTPS request on behalf of an action tap.
//! The whole point of this module is the *guardrail set* — see ADR-0017's
//! "SSRF guardrails" section. None of the rules in this file are toggleable;
//! they are enforced unconditionally for every call.
//!
//! Public entry point: [`execute`].

use std::net::IpAddr;
use std::time::{Duration, Instant};

use reqwest::header::{HeaderMap, HeaderName, HeaderValue, CONTENT_TYPE};
use reqwest::redirect;
use reqwest::Method;
use thiserror::Error;
use tokio::net::lookup_host;
use url::Url;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_RESPONSE_BYTES: u64 = 64 * 1024;

/// Caller-supplied HTTP options for the outbound request.
#[derive(Debug, Clone, Default)]
pub struct UrlBackgroundOptions {
    /// Defaults to `"GET"` if `None`.
    pub http_method: Option<String>,
    /// If set, overrides any caller-supplied `Content-Type` header.
    pub http_content_type: Option<String>,
    /// User-supplied request headers; sanitized before send.
    pub http_header: Vec<HttpHeader>,
    /// Optional string body (Pushcut convention: bodies are strings).
    pub http_body: Option<String>,
}

/// One key/value entry in [`UrlBackgroundOptions::http_header`].
#[derive(Debug, Clone)]
pub struct HttpHeader {
    pub key: String,
    pub value: String,
}

/// What [`execute`] returns on a request that completed end-to-end.
///
/// `bytes_read` is capped at 64 KiB; anything beyond is discarded silently.
#[derive(Debug)]
#[allow(dead_code)] // bytes_read currently used only in tracing
pub struct ExecutionOutcome {
    pub status: u16,
    pub bytes_read: u64,
    pub elapsed_ms: u64,
}

/// Errors surfaced by [`execute`].
#[derive(Debug, Error)]
pub enum RunnerError {
    #[error("only https:// URLs are allowed")]
    NotHttps,
    #[error("URL parse failed: {0}")]
    ParseUrl(String),
    #[error("hostname resolved to a blocked IP")]
    BlockedIp,
    #[error("DNS resolution failed")]
    DnsFailed,
    #[error("connect timeout")]
    ConnectTimeout,
    #[error("request timed out")]
    Timeout,
    #[error("transport error: {0}")]
    Transport(String),
    #[error("upstream returned non-2xx: {status}")]
    NonSuccess { status: u16 },
}

/// Run a single outbound HTTPS request with SSRF guardrails.
///
/// Behavior summary (see ADR-0017 for the full list):
/// 1. URL must parse and use the `https` scheme.
/// 2. Host is resolved via the system resolver; **every** resolved IP is
///    checked, and any blocked IP causes the whole call to fail.
/// 3. A fresh `reqwest::Client` is built per call (no pooling — pooling can
///    let a future request reuse a connection that bypassed our DNS check).
/// 4. Redirects are disabled (a 3xx Location can re-target a blocked IP).
/// 5. Response body is read up to 64 KiB then dropped.
#[tracing::instrument(skip(url, options), fields(url_host = tracing::field::Empty))]
pub async fn execute(
    url: &str,
    options: &UrlBackgroundOptions,
) -> Result<ExecutionOutcome, RunnerError> {
    // 1. Parse + scheme check.
    let parsed = Url::parse(url).map_err(|e| RunnerError::ParseUrl(e.to_string()))?;
    if parsed.scheme() != "https" {
        return Err(RunnerError::NotHttps);
    }

    // 2. Host check — IP literal goes straight to the blocklist; named host
    //    must resolve, and *every* resolved IP must pass.
    let host = parsed
        .host_str()
        .ok_or_else(|| RunnerError::ParseUrl("URL has no host".into()))?
        .to_string();

    tracing::Span::current().record("url_host", tracing::field::display(&host));

    if let Ok(ip) = host.parse::<IpAddr>() {
        if is_ip_blocked(ip) {
            return Err(RunnerError::BlockedIp);
        }
    } else {
        let iter = match lookup_host(format!("{host}:443")).await {
            Ok(it) => it,
            Err(_) => return Err(RunnerError::DnsFailed),
        };
        let mut any = false;
        for sa in iter {
            any = true;
            if is_ip_blocked(sa.ip()) {
                return Err(RunnerError::BlockedIp);
            }
        }
        if !any {
            return Err(RunnerError::DnsFailed);
        }
    }

    // 3. Method allowlist.
    let raw_method = options.http_method.as_deref().unwrap_or("GET");
    let method = match raw_method.to_ascii_uppercase().as_str() {
        "GET" => Method::GET,
        "POST" => Method::POST,
        "PUT" => Method::PUT,
        "PATCH" => Method::PATCH,
        "DELETE" => Method::DELETE,
        "HEAD" => Method::HEAD,
        _ => return Err(RunnerError::Transport("unsupported method".into())),
    };

    // 4. Build a fresh client per call.
    let client = reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .timeout(REQUEST_TIMEOUT)
        .redirect(redirect::Policy::limited(0))
        .use_rustls_tls()
        .build()
        .map_err(|e| RunnerError::Transport(format!("client build: {e}")))?;

    // 5. Build the request.
    let mut headers = HeaderMap::new();
    for h in &options.http_header {
        if is_blocked_header_key(&h.key) {
            continue;
        }
        let name = match HeaderName::try_from(h.key.as_str()) {
            Ok(n) => n,
            Err(_) => continue, // skip junk header names rather than failing the whole call
        };
        let value = match HeaderValue::try_from(h.value.as_str()) {
            Ok(v) => v,
            Err(_) => continue,
        };
        headers.append(name, value);
    }

    if let Some(ct) = options.http_content_type.as_deref() {
        match HeaderValue::try_from(ct) {
            Ok(v) => {
                headers.insert(CONTENT_TYPE, v);
            }
            Err(_) => return Err(RunnerError::Transport("invalid content_type".into())),
        }
    }

    let mut req = client.request(method, parsed.clone()).headers(headers);
    if let Some(body) = options.http_body.clone() {
        req = req.body(body);
    }

    // 6. Execute + bounded body read.
    let started = Instant::now();
    let resp = match req.send().await {
        Ok(r) => r,
        Err(e) => {
            return Err(if e.is_timeout() {
                RunnerError::Timeout
            } else if e.is_connect() {
                RunnerError::ConnectTimeout
            } else {
                RunnerError::Transport(format!("send: {e}"))
            });
        }
    };

    let status = resp.status().as_u16();

    let mut bytes_read: u64 = 0;
    let mut response = resp;
    loop {
        match response.chunk().await {
            Ok(Some(chunk)) => {
                let remaining = MAX_RESPONSE_BYTES.saturating_sub(bytes_read);
                if remaining == 0 {
                    // Body cap reached; drop the rest and stop reading.
                    break;
                }
                let take = (chunk.len() as u64).min(remaining);
                bytes_read = bytes_read.saturating_add(take);
                if (chunk.len() as u64) > remaining {
                    break;
                }
            }
            Ok(None) => break,
            Err(e) => {
                if e.is_timeout() {
                    return Err(RunnerError::Timeout);
                }
                return Err(RunnerError::Transport(format!("read body: {e}")));
            }
        }
    }
    let elapsed_ms = started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64;

    tracing::info!(
        url_host = %host,
        status = status,
        elapsed_ms = elapsed_ms,
        bytes_read = bytes_read,
        "runner: outbound https request completed"
    );

    if !(200..300).contains(&status) {
        return Err(RunnerError::NonSuccess { status });
    }

    Ok(ExecutionOutcome {
        status,
        bytes_read,
        elapsed_ms,
    })
}

/// Is this IP in any of the SSRF blocklists?
///
/// The categories below mirror ADR-0017's non-negotiable list. IPv4-mapped
/// IPv6 (`::ffff:a.b.c.d`) is unmapped first so the v4 ranges apply to
/// "v4-in-v6" addresses uniformly.
pub fn is_ip_blocked(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_v4_blocked(v4),
        IpAddr::V6(v6) => {
            if let Some(mapped) = v6.to_ipv4_mapped() {
                return is_v4_blocked(mapped);
            }
            is_v6_blocked(v6)
        }
    }
}

fn is_v4_blocked(v4: std::net::Ipv4Addr) -> bool {
    let o = v4.octets();
    // 0.0.0.0/8 — unspecified / "this network"
    if o[0] == 0 {
        return true;
    }
    // 127.0.0.0/8 — loopback
    if o[0] == 127 {
        return true;
    }
    // 10.0.0.0/8 — RFC 1918
    if o[0] == 10 {
        return true;
    }
    // 172.16.0.0/12 — RFC 1918
    if o[0] == 172 && (16..=31).contains(&o[1]) {
        return true;
    }
    // 192.168.0.0/16 — RFC 1918
    if o[0] == 192 && o[1] == 168 {
        return true;
    }
    // 169.254.0.0/16 — link-local
    if o[0] == 169 && o[1] == 254 {
        return true;
    }
    // 100.64.0.0/10 — CGNAT
    if o[0] == 100 && (64..=127).contains(&o[1]) {
        return true;
    }
    // 224.0.0.0/4 — multicast
    if (224..=239).contains(&o[0]) {
        return true;
    }
    // 255.255.255.255 — broadcast
    if v4 == std::net::Ipv4Addr::BROADCAST {
        return true;
    }
    false
}

fn is_v6_blocked(v6: std::net::Ipv6Addr) -> bool {
    // ::1 — loopback
    if v6.is_loopback() {
        return true;
    }
    // :: — unspecified
    if v6.is_unspecified() {
        return true;
    }
    // ff00::/8 — multicast
    if v6.is_multicast() {
        return true;
    }
    let segs = v6.segments();
    // fe80::/10 — link-local
    if (segs[0] & 0xffc0) == 0xfe80 {
        return true;
    }
    // fc00::/7 — IPv6 unique-local
    if (segs[0] & 0xfe00) == 0xfc00 {
        return true;
    }
    false
}

/// Header keys we strip on outbound. Lowercased, post-trim.
fn is_blocked_header_key(key: &str) -> bool {
    let k = key.trim().to_ascii_lowercase();
    if k == "host" || k == "authorization" || k == "content-length" || k == "cookie" {
        return true;
    }
    if k.starts_with("cf-") || k.starts_with("x-forwarded-") {
        return true;
    }
    false
}
