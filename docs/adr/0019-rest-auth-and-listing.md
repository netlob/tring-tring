# 0019 — REST auth, listing, and execute endpoint

## Status

Accepted — 2026-05-05. Extends [ADR-0004](0004-pushcut-compat.md).

## Context

Six prior ADRs in this batch ([ADR-0013](0013-rich-content-payloads.md) through [ADR-0018](0018-saved-notification-templates.md)) introduce REST endpoints beyond the webhook URL: cancel, action-run, templates CRUD, and (to be defined here) listing and execute. These all need a coherent auth model, a coherent rate-limit posture, and a coherent listing story for "what notifications has my account fired recently".

Two principles already in play:

- The webhook URL is `/{userId}/notifications/{name}` — path-as-secret, where `userId` is a 32-char base62 capability token ([ADR-0012](0012-sign-in-with-apple.md)).
- The path-as-secret form is appropriate for the webhook because the typical caller is an automation tool that pastes a URL. It is *not* appropriate for the iOS app's REST calls, which can comfortably set headers.

Mixing path-secret and header-bearer in the same call is a footgun (which one is authoritative? what if they disagree?). We pick a clean line: the webhook URL stays path-as-secret; everything else uses header-bearer.

The rate-limit story also needs a decision. The user's per-minute bucket (10/min by default, [ADR-0008](0008-monthly-usage-counter.md)) was designed against APNs throughput. If REST endpoints had their own bucket, a user who hammered the templates API could starve their webhook of slots — or vice versa. We prefer one bucket per user, shared across all endpoints.

Finally, the existing `GET /v1/users/{userId}` returns an embedded `recentLog` (last N notifications). For history beyond a small N, callers want pagination. We add a paginated listing endpoint and deprecate the embedded log without removing it (yet) for backwards compat.

## Decision

### Auth model

- **Webhook endpoint** (`POST | GET /{userId}/notifications/{name}`): keeps **path-as-secret** semantics. No `Authorization` header is checked. Possession of the URL is auth, per [ADR-0012](0012-sign-in-with-apple.md).
- **All other `/v1/*` endpoints** require:
  ```
  Authorization: Bearer <userId>
  ```
  The `userId` IS the bearer token — same secret, same trust model, just in a header instead of a path.
- For endpoints that also have `userId` in the path (e.g. `/v1/users/{userId}/templates`), the path `userId` and the bearer token must **match exactly**. Mismatch → **HTTP 401** with `{"error":"path/header userId mismatch"}`. Rationale: a leaked log line that records both halves of the request shouldn't be ambiguous about which one was authoritative.
- Missing `Authorization` header → **HTTP 401** `{"error":"missing bearer token"}`.
- Malformed (`Authorization: <something other than Bearer ...>`) → **HTTP 401** `{"error":"unsupported authorization scheme"}`.
- Unknown user (bearer token doesn't match any `users.id`) → **HTTP 401** `{"error":"unknown user"}`. Same response as malformed; no oracle for "this user exists but you used the wrong scheme".

### New endpoints

#### Paginated notifications listing

```
GET /v1/users/{userId}/notifications?limit=50&before=<id>
```

- `limit`: default **50**, max **200**. Larger → clamped to 200, no error.
- `before`: cursor — ID of a previously-returned row. Returns the page of rows older than the cursor. Absent → newest page.
- Response:
  ```json
  {
    "notifications": [
      {"id": "<uuid>", "name": "...", "external_id": "...", "status": "sent|failed|...", "created_at": <unix>},
      ...
    ],
    "nextBefore": "<uuid|null>"
  }
  ```
- Replaces the embedded `recentLog` field on `GET /v1/users/{userId}` for any caller that wants history beyond the embedded subset.

#### Server-side execute

```
POST /v1/execute
```

- Auth: `Authorization: Bearer <userId>`. The body has no path `userId` — the bearer token is the full identity.
- Body:
  ```json
  {
    "url": "https://...",
    "urlBackgroundOptions": { /* same shape as ADR-0013/0017 */ },
    "online": true
  }
  ```
- Behavior: runs the outbound request through the **same SSRF guardrails as [ADR-0017](0017-run-on-server-actions.md)** — HTTPS-only, no private/loopback IPs, header sanitization, timeout caps, no automatic redirects, 64 KB response cap, TLS verification on. The implementation is the *same code path* — there is exactly one SSRF-safe outbound HTTP function in the binary, called from both `/actions/run` and `/execute`.
- `online`: when `true`, request is rejected if the iOS device is currently offline — but `online` is an iOS-handler concept that doesn't apply to a server-initiated execute. Here we accept the field for symmetry with [ADR-0016](0016-interactive-actions.md) but treat it as a no-op (logged once at startup as "online flag ignored on /v1/execute"). Documented.
- Response: same shape as `/actions/run` — `{ status, headers, body, truncated }`.
- Use case: cron-style external triggers (`curl -H 'Authorization: Bearer <userId>' …/v1/execute -d '{...}'`) where the caller wants to run an HTTPS request via *our* SSRF-safe egress, rather than implement guardrails themselves. Also used by the iOS app's "run this URL now" affordances that don't go through a notification action.

### Deprecation: embedded `recentLog`

- `GET /v1/users/{userId}` continues to return `recentLog` for backwards compatibility, **limited to the 10 most recent rows** (unchanged).
- The response gains `"recentLogDeprecated": true` and a `"link":"/v1/users/<id>/notifications"` hint pointing to the paginated endpoint.
- Removal of the embedded field is the topic of a future ADR, not this one.

### Rate-limit posture

- All `/v1/*` endpoints (templates, listing, cancel, action-run, execute) **share the same per-user governor bucket** as the webhook. The bucket is keyed on `user_id`, default 10 requests/minute (configurable via `RATE_LIMIT_PER_MINUTE`).
- Rationale: a noisy template editor or a runaway iOS app should not exhaust APNs throughput, and vice versa. One bucket, one fairness story per user. The bucket is governed by the same logic [ADR-0008](0008-monthly-usage-counter.md) defines.
- The webhook continues to count toward this bucket (per [ADR-0012](0012-sign-in-with-apple.md), one webhook = one slot regardless of fan-out width).
- Exceeded → **HTTP 429** with `Retry-After` header (seconds), consistent across all endpoints.

### Monthly quota

- Quota (`monthly_usage`) tracks **only webhook fan-outs that delivered to at least one device** (per [ADR-0012](0012-sign-in-with-apple.md)). It does **not** count REST API calls.
- `/v1/execute` is **not** counted against quota. Quota tracks APNs deliveries, not arbitrary outbound requests. Documented.

## Consequences

- **+** One auth model for the iOS app's REST surface, simple to test and document. The iOS app sets the bearer header once and forgets.
- **+** No `403 vs 401` ambiguity: every auth failure is **401**, every cross-user lookup is **404**.
- **+** One rate-limit bucket per user means fair sharing between APNs delivery and REST chatter without operator tuning.
- **+** The paginated listing endpoint scales beyond 10 rows without growing the response of `GET /v1/users/{userId}`.
- **+** `/v1/execute` reuses the SSRF-safe egress from [ADR-0017](0017-run-on-server-actions.md) — one function, one set of guardrails, one place to find a vulnerability if there ever is one.
- **−** Path-as-secret (webhook) and header-bearer (REST) coexist, which means two parsers and two sets of integration tests. Acceptable; the alternative is forcing automation tools to set headers, which is the actual reason we kept path-as-secret.
- **−** Bucket sharing between webhook and REST means a buggy iOS app could starve webhook delivery. We accept this; a per-user `RATE_LIMIT_PER_MINUTE` is the operator's escape valve.
- **−** Backwards-compat `recentLog` is technical debt with a deprecation marker. Removal needs a follow-up ADR. Acceptable.
- **−** `online` on `/v1/execute` is a no-op by design — discoverability is poor. Documented prominently in the API docs.

## Operational rules

1. **Bearer token comparison is constant-time.** Standard `subtle::ConstantTimeEq` (or `ring::constant_time`) on the byte slice. Never `==`. The bearer token is a 32-char capability secret — timing-safety is required.
2. **Path-and-header `userId` mismatch is rejected, not silently preferred.** Both must agree. This is enforced in middleware before any handler runs.
3. **There is exactly one SSRF-safe outbound HTTP function.** Both `/actions/run` and `/execute` call it. A future endpoint that needs to run user-supplied URLs server-side calls the same function or doesn't ship.
4. **Quota and rate-limit are separate concepts.** Quota is monthly, APNs-delivery-bound, per-user. Rate-limit is per-minute, per-endpoint-class (here: shared), per-user. Conflating them in code or docs is a defect.
5. **The paginated listing query is bounded.** `LIMIT min(requested, 200)` always. There is no "give me all my notifications since 2024" call shape; deep history requires repeated paginated calls.

## References

- [`subtle::ConstantTimeEq`](https://docs.rs/subtle/latest/subtle/trait.ConstantTimeEq.html) — constant-time bearer comparison.
- [RFC 6750 — OAuth 2.0 Bearer Token Usage](https://www.rfc-editor.org/rfc/rfc6750) — `Authorization: Bearer <token>` shape.
- [RFC 7231 — HTTP/1.1 Semantics — `Retry-After`](https://www.rfc-editor.org/rfc/rfc7231#section-7.1.3).
- [ADR-0004](0004-pushcut-compat.md) — Pushcut-compatible webhook format. This ADR extends it.
- [ADR-0008](0008-monthly-usage-counter.md) — rate-limit bucket and monthly quota.
- [ADR-0012](0012-sign-in-with-apple.md) — `userId` as a capability token, used here as bearer.
- [ADR-0014](0014-notification-identifiers-and-cancel.md), [ADR-0017](0017-run-on-server-actions.md), [ADR-0018](0018-saved-notification-templates.md) — REST endpoints whose auth/rate-limit posture this ADR formalizes.
- [ADR-0017](0017-run-on-server-actions.md) — SSRF guardrails reused by `/v1/execute`.
