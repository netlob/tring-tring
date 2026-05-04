# 0011 — Notification name in URL: free-form label, validated regex

## Status

Accepted — 2026-05-04.

## Context

The Pushcut-compatible URL shape is `/{secret}/notifications/{name}`. Pushcut's `{name}` refers to a notification *pre-configured in their iOS app* (giving it sounds, actions, default behavior). We do not have an in-app notification configuration UI in v1 (see ADR-0005 for the minimal feature scope), so the name in our URL serves a different purpose:

- It's a label the operator/user picks to identify what the webhook is for (`build-failed`, `door-bell`, `morning-coffee`).
- It maps to APNs's `apns-collapse-id` so multiple pushes of the same event coalesce on the device.
- It's stored in `notifications_log.name` for retrospective debugging.

We need to define what constitutes a valid name to:

- Prevent injection / path traversal (URL is a path segment).
- Set a sensible upper bound for the log column.
- Not be needlessly restrictive about characters users want to use (Pushcut allows quite a lot).

## Decision

Names match `^[A-Za-z0-9._-]{1,64}$`.

- Allowed: ASCII letters, digits, dot, underscore, hyphen.
- Length: 1 to 64 characters.
- No URL-encoding required for any allowed character.
- No pre-registration: any name matching the pattern is accepted on first use.

Invalid names return **400 Bad Request** with body `{"error":"invalid notification name"}`.

The name is mapped to APNs as `apns-collapse-id` (which has its own 64-byte limit — our regex stays comfortably inside it).

## Consequences

- **+** Path traversal is impossible (no `/` or `..` allowed).
- **+** Names round-trip through URLs and JSON without escaping.
- **+** The 64-char cap matches APNs's collapse-id limit, avoiding a separate truncation step.
- **+** Any name a user picks "just works" on first send — no setup step — matching the device-token-only philosophy of ADR-0005.
- **−** Spaces, slashes, Unicode, and emoji are not allowed in names. If a user wants `"build failed"` they use `build-failed` or `build_failed`. Acceptable trade-off for v1.
- **−** Pushcut allows broader names; users migrating may need to adjust a small subset. The README will note this caveat.

## When to supersede

Write a new ADR if:

- We add a Notification Service Extension on iOS that needs richer name semantics.
- We let users register named notification configurations (sounds, actions, default URLs) in-app — at that point the name becomes a key into a config table, with different validation needs.
