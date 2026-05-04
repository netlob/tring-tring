# 0005 — Device-token-only auth (no accounts) for v1

## Status

**Superseded by [ADR-0012](0012-sign-in-with-apple.md)** (2026-05-04). v1 went without accounts; v1.1 adopted Sign in with Apple as the identity layer. The webhook URL contract changed from `/{secret}/notifications/{name}` to `/{userId}/notifications/{name}`. Read this ADR for historical context only.

## Context

Two identity models were considered:

1. **Account-based** — users sign up with an email/password (or Sign in with Apple), can register multiple devices under one account, and manage their devices through a dashboard. Familiar UX, but requires building auth, sessions, password reset flows, account deletion, and a multi-device-aware notification model.
2. **Device-token-only** — each device generates a unique webhook URL on first launch. No signup, no email, no password. The device is the identity. Each webhook URL maps to exactly one device.

The v1 goal is to ship a working alternative quickly with the smallest possible operational surface. Account-based auth is itself a feature that takes meaningful time to build and a meaningful obligation to maintain (security, password resets, GDPR deletion flows).

## Decision

**v1 uses device-token-only auth.** No user accounts.

- On first launch, the iOS app obtains an APNs device token, calls `POST /v1/devices`, and receives a unique `webhookSecret`.
- The webhook URL is `https://<host>/{webhookSecret}/notifications/{name}`.
- One secret = one device. To use a second device, the user installs the app there and gets a separate webhook URL.
- The `POST /v1/devices` endpoint is idempotent on `apnsToken`: calling it again with the same APNs token returns the same `webhookSecret`. This handles app reinstalls cleanly when iOS reissues the same token.

## Consequences

- **+** Zero auth surface to build or attack: no passwords, no sessions, no password resets, no account-takeover.
- **+** No PII stored: the service knows an APNs token (opaque), a webhook secret, and a device name (user-provided string). No email, no phone, no name.
- **+** Onboarding is "open app, copy URL." Lower friction than any competitor.
- **−** No "sync across my devices." Users with iPhone + iPad get two webhook URLs and call both if they want both to ring. Mitigation: a future feature can introduce account-based grouping without breaking existing device tokens (the account becomes a layer above devices).
- **−** Losing access to a device means losing its webhook URL with no recovery flow. Accepted: webhook URLs are not catastrophic to regenerate (re-install the app, update the automation source).
- **−** No web dashboard to manage devices. The app itself is the management surface. Acceptable for v1.

## When to supersede

If/when any of these become true, write a new ADR:
- Multiple devices need to ring from the same webhook.
- A web dashboard is required for managing devices/quotas.
- Operator wants to charge for paid tiers (which need account identity for billing).
