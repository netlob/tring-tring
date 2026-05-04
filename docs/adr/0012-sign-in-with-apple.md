# 0012 — Sign in with Apple as the identity layer; per-user webhook URLs

## Status

Accepted — 2026-05-04. **Supersedes [ADR-0005](0005-device-token-auth.md)** and amends [ADR-0008](0008-monthly-usage-counter.md).

## Context

v1 shipped device-token-only auth (per [ADR-0005](0005-device-token-auth.md)): each device generated a unique webhook URL keyed on a per-device secret. That model has reached its limits. It cannot express:

- One person, multiple devices ringing on the same webhook URL.
- A per-user quota / rate limit (today's counters are per-device).
- Anything that needs a stable identity later — paid tiers, settings sync, support, account deletion.

The end-to-end happy path is now confirmed working on the user's phone + VPS, so we have the leeway to introduce a real identity layer before the surface area grows further.

The smallest change that unlocks all of the above is **Sign in with Apple** (SIWA): the iOS app already targets Apple devices exclusively (per [ADR-0001](0001-direct-apns.md)), so the user's Apple ID is the natural identity. SIWA is HIG-mandated for iOS apps that offer any third-party sign-in, and Apple verifies the identity for us via a signed JWT — we never see a password, and we don't need to build session/reset/lockout machinery.

Mechanically, SIWA hands the iOS client an **identity token**: a JWT signed RS256 with one of Apple's published keys, carrying a `sub` claim that is stable per-Apple-ID per-Team. The server is expected to verify the signature against Apple's published JWKS and check `iss`, `aud`, `exp`, and the app-supplied nonce. See [Sign in with Apple REST API — Verifying a User](https://developer.apple.com/documentation/sign_in_with_apple/sign_in_with_apple_rest_api/authenticating_users_with_sign_in_with_apple) and [`AuthenticationServices`](https://developer.apple.com/documentation/authenticationservices) for the Apple-side contract.

## Decision

**Sign in with Apple is the identity layer for tring-tring v1.1.** Devices are owned by users; webhook URLs are scoped to users.

### Identity model

- Each user gets a server-issued **32-character base62 user ID** (CSPRNG-generated, rejection-sampled to avoid modulo bias). This is the public identifier in URLs and is treated as a capability token (possession = auth, same trust model as Pushcut and as the v1 device secret).
- The Apple `sub` claim is the **stable Apple-Team-scoped identifier** for the human; it is stored as `users.apple_user_sub` (UNIQUE) and is the upsert key on registration. The same Apple ID signing into a second device returns the same `sub` and therefore the same `userId`.
- One user → many devices. Devices are joined to users via `devices.user_id` with `ON DELETE CASCADE`.

### URL contract change

The webhook URL becomes:

```
POST/GET https://<host>/{userId}/notifications/{name}
```

This **replaces** the v1 form `https://<host>/{secret}/notifications/{name}` from [ADR-0005](0005-device-token-auth.md). Old URLs do not work after the migration; the migration drops and recreates the affected tables (acceptable: clean re-register from the iOS app).

### Fan-out and quota counting

- A single incoming webhook **fans out in parallel** to every device row joined to that `user_id`. Implementation: `futures::future::join_all` over `state.apns.send` per device. APNs results are recorded per-device in `notifications_log`.
- The monthly quota counter (`monthly_usage.sent_count`) increments **once per webhook**, not once per device delivery. This is the operator-fair semantic: one webhook fired = one count consumed, regardless of how many devices the user happens to own. The increment fires only if at least one device delivery succeeded; full-failure webhooks do not consume quota.
- Per-device APNs failures (`Unregistered`, `BadDeviceToken`) still drive per-device cleanup (DELETE the device row + log a `failed` row), unchanged from v1 semantics.
- If the user has zero registered devices, the route returns **410 Gone** with `{"error":"no devices registered"}` (operator feedback that the URL has no live targets) and writes a single log row with `status='no_devices'`. No quota increment.

### Apple identity-token verification contract

The server verifies the Apple identity token on every `POST /v1/devices` call:

1. Decode the JWT header to read `kid` and `alg`. Reject anything that isn't RS256.
2. Look up the matching JWK in the local cache. Cache at `https://appleid.apple.com/auth/keys` for **24 hours**; on a `kid` cache miss, force one refresh attempt then error.
3. Build `Validation::new(Algorithm::RS256)` (never `Validation::default()` — that accepts HS256 and is a known confusion attack on naive setups). Set `validation.set_issuer(&["https://appleid.apple.com"])` and `validation.set_audience(&[bundle_id])` (= `APNS_BUNDLE_ID`, e.g. `dev.sjoerd.tringtring`). The library checks `iss`, `aud`, and `exp`.
4. After decode succeeds, **manually** verify `claims.nonce == sha256_hex(raw_nonce_from_client)`. The `jsonwebtoken` crate doesn't know about Apple's nonce contract — this check is mandatory and on us. The iOS client passes the SHA-256 hex of `rawNonce` to Apple as `request.nonce` and sends `rawNonce` (the pre-image) to our server alongside the identity token; the server hashes the pre-image and compares.
5. The `sub` claim from the verified token is trusted as the user's stable identity → upsert into `users` on `apple_user_sub`.

#### One-shot fields

`email`, `is_private_email`, and `fullName` only arrive on the **first** successful authorization for a given Apple ID + app pair. On re-authorization, Apple omits them. The server **must persist `email` and `is_private_email` immediately on the first registration**; otherwise they are lost forever. On subsequent authorizations the upsert leaves these columns alone.

`fullName` is consumed by the iOS client only (we don't need it server-side); the server-side path stores `email` + `is_private_email` and discards the rest.

### Why not exchange `authorizationCode` server-side (v1)

The Apple REST API exposes a separate `authorizationCode` exchange that returns refresh tokens and enables server-to-server revocation handling (account deletion notifications). We **skip** this in v1 because:

- We only need to log the user in; possession of a valid identity token is sufficient.
- We don't need long-lived refresh tokens — the iOS client re-authenticates with `getCredentialState(forUserID:)` and a fresh SIWA flow when needed.
- Revocation handling (Apple ID removal of our app) can be triggered client-side via `credentialState`, which is enough for v1's UX.

This is a deliberate scope choice. The "When to supersede" section below names the triggers for revisiting it.

## Consequences

- **+** One webhook URL per user works on iPhone + iPad + future Apple Watch / macOS targets simultaneously.
- **+** Per-user quotas + rate limits become natural (counters key on `user_id`).
- **+** Real account identity unlocks paid tiers, account deletion, and a future web dashboard without further URL contract changes.
- **+** Zero password / session / reset machinery to build or maintain — Apple does the auth.
- **+** No PII beyond what the user explicitly grants (`email` and `is_private_email`); `fullName` is iOS-local.
- **−** v1 webhook URLs (`/{secret}/notifications/...`) stop working after the migration. Mitigation: the user is the only registered device; clean re-register from the app is a one-time cost.
- **−** Adds a runtime dependency on Apple's JWKS endpoint. Mitigation: 24-hour cache, refresh-on-kid-miss; outage at registration time only (after registration the device sends pushes via the user's URL with no Apple round-trip).
- **−** SIWA is iOS-only. If we ever ship a web dashboard or non-Apple client, those audiences need their own identity flow. Acceptable for the iOS-only product target.
- **−** [ADR-0008](0008-monthly-usage-counter.md)'s "log row + counter increment in one transaction" invariant is **relaxed**: with fan-out, log rows and counter updates are decoupled (per-device log inserts commit immediately; the counter increments at most once per webhook, only if any device succeeded). The user-level invariant is preserved (`status='sent'` is still the only thing that drives the counter), but they're no longer co-transactional. ADR-0008's Status is updated to reflect this amendment.

## Operational rules (non-negotiable)

These are reasserted in `backend/CLAUDE.md` and enforced in code review:

1. **`AppleVerifier` is constructed exactly once at startup**, held in `AppState` as `Arc<AppleVerifier>`. The JWKS cache is shared across all requests. Per-request construction defeats the cache and adds an Apple round-trip on every registration.
2. **`Validation::new(Algorithm::RS256)` is mandatory.** `Validation::default()` accepts HS256 and turns a leaked symmetric secret (or none at all) into a forge-anything tool. Always set `set_issuer(&["https://appleid.apple.com"])` and `set_audience(&[bundle_id])` explicitly.
3. **Nonce verification is mandatory.** After the JWT decode succeeds, verify `claims.nonce == sha256_hex(raw_nonce)`. A token without this check is replayable.
4. **Never log the identity token, the raw nonce, or `apple_user_sub` in full.** Truncate to the first 8 characters maximum in any log line. The identity token in particular is a bearer credential for Apple's signing scope until `exp`.

## Schema migration summary

The migration (`backend/migrations/0002_users.sql`) drops the v1 device-keyed tables and recreates them keyed on `user_id`:

- New `users(id, apple_user_sub, email, is_private_email, created_at, last_seen_at)`.
- `devices` gets a `user_id` foreign key with `ON DELETE CASCADE`.
- `monthly_usage` re-keyed on `(user_id, month)`.
- `notifications_log` re-keyed on `user_id` (with optional `device_id` for the per-device row).
- `rate_limit_buckets` is dropped (already unused; in-memory `governor` per [ADR-0008](0008-monthly-usage-counter.md)).

## When to supersede

Write a new ADR when any of these become true:

- **Web sign-in.** A browser dashboard signing users in via SIWA-on-the-web has a different audience (the Services ID, not the iOS bundle ID), so the verifier needs to accept multiple audiences or be split.
- **Server-to-server revocation handling.** When we want to react to account-deletion notifications from Apple, we need to perform the `authorizationCode` exchange to obtain a refresh token and run Apple's notification endpoint subscription. That changes the registration flow shape.
- **Multi-tenant deploys.** If the service is ever operated for someone else's bundle ID (white-labeled), the verifier needs per-tenant audience configuration and the URL space needs a tenant prefix.

## References

- [Sign in with Apple REST API — Authenticating users with Sign in with Apple](https://developer.apple.com/documentation/sign_in_with_apple/sign_in_with_apple_rest_api/authenticating_users_with_sign_in_with_apple)
- [Sign in with Apple REST API — Fetch Apple's public key for verifying token signature](https://developer.apple.com/documentation/sign_in_with_apple/fetch_apple_s_public_key_for_verifying_token_signature)
- [`AuthenticationServices` framework documentation](https://developer.apple.com/documentation/authenticationservices)
- [`ASAuthorizationAppleIDProvider.getCredentialState(forUserID:)`](https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidprovider/3175423-getcredentialstate)
- [Apple HIG — Sign in with Apple](https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple)
- [RFC 7517 — JSON Web Key (JWK)](https://www.rfc-editor.org/rfc/rfc7517)
- [ADR-0005](0005-device-token-auth.md) — superseded by this ADR.
- [ADR-0008](0008-monthly-usage-counter.md) — amended by this ADR (counter is now per-user, once-per-webhook).
- [ADR-0001](0001-direct-apns.md) — APNs delivery is unchanged.
- [ADR-0011](0011-notification-name-validation.md) — notification name regex is unchanged.
