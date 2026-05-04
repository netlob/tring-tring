# 0017 — Run-on-server action execution

## Status

Accepted — 2026-05-05. Extends [ADR-0004](0004-pushcut-compat.md).

## Context

[ADR-0016](0016-interactive-actions.md) defines the action contract — including `runOnServer: true`, which Pushcut uses to mean "when the user taps this action, *the server* executes the URL request, not the device". This is useful for two reasons:

1. **Background-friendly**: the iOS device can fire-and-forget the callback to our backend (cheap, near-instant) and the actual outbound request happens server-side without iOS background-execution constraints.
2. **Targeted-by-credential**: the action URL might be inside the operator's home network — a self-hosted endpoint, an internal API. The operator's *server* has the right credentials/network position; their *phone*, when away from home, doesn't.

The second reason is also where the *security* problem lives. We are running an arbitrary HTTPS request server-side, on behalf of whoever sent the notification. If we don't lock this down, we have built a Server-Side Request Forgery (SSRF) tool: anyone holding a webhook URL can ask our backend to GET `http://169.254.169.254/latest/meta-data/iam/security-credentials/` (cloud metadata service), or `http://10.0.0.1/admin`, or any number of internal services that trust requests from "inside the perimeter".

The guardrails are not optional. They are the entire reason this ADR is separate from [ADR-0016](0016-interactive-actions.md): the action contract is small; the SSRF defense is significant and worth its own decision record.

The flow:

1. The webhook arrives with an action that has `runOnServer: true` and `urlBackgroundOptions`.
2. Backend stores the action config keyed on `(notification_log_id, action_name)` with a 24 h TTL.
3. Backend dispatches the push via the existing fan-out path.
4. User taps the action on their device.
5. iOS POSTs to the backend's run endpoint with `(notification_log_id, action_name, idempotency_key)`.
6. Backend looks up the persisted config, runs the SSRF-safe outbound request, returns the result to iOS.

## Decision

### Endpoint

```
POST /v1/users/{userId}/actions/run
```

- Auth: `Authorization: Bearer <userId>` header (per [ADR-0019](0019-rest-auth-and-listing.md)). Path `userId` and bearer token must match.
- Body:
  ```json
  {
    "notificationLogId": "uuid-from-userInfo",
    "actionName": "string (matches an action.name from the original push)",
    "idempotencyKey": "client-supplied UUID"
  }
  ```
- Behavior:
  - Look up `pending_actions(notification_log_id, action_name)` for `user_id`. Not found → **HTTP 404**.
  - Expired (TTL elapsed) → **HTTP 410 Gone**, row deleted.
  - Idempotent: if the same `idempotencyKey` was used in the last 1 h, return the prior response (cached `(status, body_truncated)`).
  - Otherwise, execute the outbound request per the SSRF guardrails below and return:
    ```json
    {
      "status": <upstream-http-status>,
      "headers": { /* whitelist of response headers */ },
      "body": "<truncated to 64 KB, base64 if not utf-8>"
    }
    ```

### Storage

```sql
CREATE TABLE pending_actions (
  notification_log_id BLOB NOT NULL,
  action_name         TEXT NOT NULL,
  user_id             TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  payload_json        TEXT NOT NULL,            -- the full ActionObject from the original push
  expires_at          INTEGER NOT NULL,         -- Unix seconds, 24 h after the original push
  PRIMARY KEY (notification_log_id, action_name)
);
CREATE INDEX pending_actions_expires_at ON pending_actions(expires_at);
```

- Row written when the original webhook is dispatched, not when the action is tapped.
- Swept by the existing retention task that already runs against `notifications_log`.

### SSRF guardrails (non-negotiable)

These rules are **load-bearing for security** and must all be enforced. None are toggleable by configuration.

1. **HTTPS only.** `url.scheme` must be exactly `"https"`. `http://`, `file://`, `gopher://`, etc. → **HTTP 400** `{"error":"https only"}`.
2. **Hostname resolved at request time.** Resolve via standard DNS at the moment of execution (not cached). For each resolved IP:
   - **Reject** loopback (`127.0.0.0/8`, `::1/128`).
   - **Reject** RFC 1918 (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`).
   - **Reject** link-local (`169.254.0.0/16`, `fe80::/10`).
   - **Reject** CGNAT (`100.64.0.0/10`).
   - **Reject** IPv6 unique-local (`fc00::/7`) and IPv6 link-local (`fe80::/10`).
   - **Reject** IPv4-mapped IPv6 of any of the above.
   - On rejection: **HTTP 400** `{"error":"resolved address not permitted"}`. Do not include the resolved IP in the error.
3. **Resolve once, connect to the resolved IP.** After the resolve-and-check passes, the HTTP client connects directly to the resolved IP and sets the `Host` header to the original hostname. This defeats DNS-rebinding (the attacker can't return a public IP for the check and a private IP for the connect — the resolve is what we connected to).
4. **Header sanitization on the outbound request.** User-supplied headers via `urlBackgroundOptions.httpHeader[]` are stripped of:
   - `host` (we set it).
   - `authorization` (this is *our* APNs JWT scope or any operator credential — we never forward).
   - Any header starting with `cf-`, `x-forwarded-`, `x-real-`, `x-original-`. These are reserved for trusted proxies; passing user-controlled values for them lets a caller spoof origin to backend services.
   - `cookie` (no piggybacking on the operator's session).
5. **Method allowlist.** `httpMethod` ∈ `{GET, POST, PUT, PATCH, DELETE}`. Anything else → **HTTP 400** `{"error":"method not permitted"}`.
6. **Body size cap.** `httpBody` ≤ 64 KB on the request side. Larger → **HTTP 413** at the *original webhook* (not at the run endpoint, where we'd already have committed to dispatch).
7. **Timeouts.**
   - Connect timeout: **5 seconds**.
   - Total request timeout (DNS + connect + TLS + send + receive): **30 seconds**.
   - On timeout: **HTTP 504** to the iOS caller.
8. **Response body cap: 64 KB.** Anything larger is truncated with a `truncated: true` field in the response.
9. **No automatic redirects.** `Location` from the upstream is returned verbatim to the iOS caller as part of the response, but we do not follow it. Following redirects is a re-entry point for SSRF (the upstream could redirect to an internal address); the caller must explicitly issue a second request if they want it.
10. **TLS verification on.** Standard `rustls`/`reqwest` defaults. No `danger_accept_invalid_certs`, no `accept_invalid_hostnames`, ever. Self-signed internal endpoints are *not* a supported target.

### Concurrency and rate limit

- The run-on-server endpoint shares the user's per-user governor bucket (10/min, [ADR-0008](0008-monthly-usage-counter.md)) per [ADR-0019](0019-rest-auth-and-listing.md). Tapping action buttons faster than the rate limit returns **HTTP 429**.
- Concurrent run requests for the same `(notification_log_id, action_name, idempotencyKey)` collapse via a per-key mutex: the first request executes, the rest wait and return the cached response.

## Consequences

- **+** Pushcut-style "tap to fire a webhook from my server" works.
- **+** SSRF defense is hardened end-to-end. None of the cloud-metadata, internal-IP, header-spoofing, DNS-rebinding, or auth-piggybacking attacks land.
- **+** Idempotency at the action level: a flaky network on iOS that retries the same action three times executes the upstream once.
- **+** 24 h action TTL bounds storage growth. With [ADR-0014](0014-notification-identifiers-and-cancel.md)'s 24 h dedup window and [ADR-0015](0015-scheduled-and-delayed-notifications.md)'s 7-day scheduling cap, "things we hold for the user" all share a single retention sweep task.
- **−** Self-hosted internal endpoints (e.g. a home-network Home Assistant on `192.168.1.10`) are explicitly **not reachable**. This is a feature, not a bug — but it differs from how Pushcut behaves when the user's iOS device is on the same LAN. Documented prominently.
- **−** No-redirect-following will surprise some integrations. Documented, with a workaround (set `online: true` to handle redirects on-device — though that side of `online` is iOS-handler logic, not this ADR).
- **−** TLS-verification-always means self-signed internal services fail. Acceptable; the alternative is a per-user "trust this CA" knob, which is a much larger ADR than this one.
- **−** A tightly-coordinated DNS attacker could still cause a slow-loris-style timeout. The 30-second total timeout caps the damage; we accept it.

## Operational rules

1. **The SSRF guardrails are tested with adversarial fixtures, not just sunny-day URLs.** Test cases include `http://localhost:25/`, `https://[::1]/`, `https://169.254.169.254/`, `https://10.0.0.1.nip.io/` (hostname that resolves to a private IP), and a DNS-rebinding fixture (TTL=0, alternating responses).
2. **The header denylist is checked in lowercase, post-trim.** Case-folding bypass (`Authorization` vs `authorization`) and prefix-padding (`X-Authorization`) are both tested.
3. **The `Host` header is *set* by us, not appended.** A caller-supplied `Host: foo` is dropped, then we add `Host: <hostname-from-url>`. There is exactly one `Host` header on every outbound request.
4. **No operator-configured allowlist for "trusted internal addresses".** Adding one would be a breach of the SSRF guarantee and requires a new ADR with an explicit threat model.
5. **DNS resolution uses the system resolver, not a custom one.** A custom resolver to "tighten" SSRF defenses has been the source of multiple real-world bypasses (see references). Standard tooling, audited guardrails on top.

## References

- [OWASP — Server-Side Request Forgery Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html)
- [Cloud metadata SSRF — Capital One breach analysis](https://krebsonsecurity.com/2019/08/what-we-can-learn-from-the-capital-one-hack/)
- [Pushcut webhook docs — `runOnServer`, `urlBackgroundOptions`](https://www.pushcut.io/support/notifications)
- [`reqwest` client configuration](https://docs.rs/reqwest/latest/reqwest/struct.ClientBuilder.html)
- [ADR-0004](0004-pushcut-compat.md) — Pushcut-compatible webhook format. This ADR extends it.
- [ADR-0008](0008-monthly-usage-counter.md) — rate limit bucket reused here.
- [ADR-0013](0013-rich-content-payloads.md) — `defaultAction.urlBackgroundOptions` is the analogous shape, also stored.
- [ADR-0016](0016-interactive-actions.md) — action contract; this ADR is the runtime for `runOnServer == true`.
- [ADR-0019](0019-rest-auth-and-listing.md) — REST auth model and per-user rate-limit bucket.
