# 0014 — Notification identifiers and cancel API

## Status

Accepted — 2026-05-05. Extends [ADR-0004](0004-pushcut-compat.md).

## Context

Pushcut's webhook contract allows the caller to assign a free-form `id` (alias `identifier`) to a notification. The identifier serves three purposes that we want to support:

1. **Idempotency** — a caller that retries a webhook (network blip, ambiguous response) can use the same identifier and not produce a duplicate push.
2. **Cancellation** — for scheduled / delayed notifications (see [ADR-0015](0015-scheduled-and-delayed-notifications.md)), the identifier is the only way the caller can refer to a not-yet-sent notification later.
3. **Correlation** — a Home Assistant / Zapier flow that ties an ack-style action callback back to the original notification needs a stable identifier in the user info.

[ADR-0011](0011-notification-name-validation.md) already settled the validation regex for `name` (the URL path label, used as APNs's `apns-collapse-id`). The notification *identifier* is a different thing — it is per-fire, supplied by the caller, and doesn't appear in the URL — so it gets its own validation rule and storage column.

The cancel side has a hard physical constraint: APNs cannot recall a notification once it has been delivered. The endpoint exists for symmetry and for the scheduled case (where cancellation is meaningful pre-dispatch).

## Decision

### Identifier on the webhook

- Webhook accepts `id` or `identifier` (treated as aliases; if both are present, `identifier` wins). Validation: `^[A-Za-z0-9._-]{1,64}$` — same character class as [ADR-0011](0011-notification-name-validation.md), separately enforced.
- Stored in `notifications_log.external_id` for every fired notification, and in `scheduled_notifications.external_id` for any scheduled-but-not-yet-fired row (see [ADR-0015](0015-scheduled-and-delayed-notifications.md)).
- If the caller does not supply one, the backend mints a UUIDv7 and uses that as `external_id`. The minted identifier is included in the response body (`{"identifier":"..."}`) so the caller can reference it later.
- Invalid identifier (regex mismatch) → **HTTP 400** with `{"error":"invalid identifier"}`.

### Idempotency window

- Re-using the same `external_id` for the same `(user_id, name)` within **24 hours** is treated as a duplicate at the application layer: the second call is a no-op, returns **HTTP 200** with the same body the original returned, and does not consume quota or rate-limit budget.
- Outside the 24 h window, the identifier is treated as fresh and a new push fires. Rationale: the dedup table is finite, the identifier is caller-supplied, and "I sent this *again* tomorrow" is rarely the same intent as "I retried within 24 h after a 502".
- Implementation: `idempotency_keys(user_id, external_id, name, response_body, created_at)` with a composite primary key and a sweep task that deletes rows older than 24 h. The 24 h window is wall-clock, not since-last-use.

### Cancel endpoint

```
DELETE /v1/users/{userId}/submittedNotifications/{external_id}
```

- Auth: `Authorization: Bearer <userId>` header (per [ADR-0019](0019-rest-auth-and-listing.md)). The path `userId` and the bearer token must match — mismatch → **HTTP 401**.
- The user-scoped path shape is chosen for consistency with the rest of the `/v1/users/{userId}/...` REST surface introduced in [ADR-0019](0019-rest-auth-and-listing.md). The endpoint is *not* the path-as-secret webhook URL — cancel is a REST operation.
- Behavior:
  - **Already-delivered push** (only `notifications_log` row exists, no `scheduled_notifications` row in `pending`): respond **HTTP 200** with `{"status":"already_delivered"}`. APNs cannot recall a delivered notification; the endpoint exists for symmetry with Pushcut and to give the caller an honest answer.
  - **Scheduled-but-not-yet-fired push** (a `scheduled_notifications` row in status `pending`): `UPDATE scheduled_notifications SET status='cancelled', dispatched_at=NULL WHERE external_id=? AND user_id=? AND status='pending'`. Respond **HTTP 200** with `{"status":"cancelled"}`.
  - **Unknown external_id** for the user: **HTTP 404** with `{"error":"unknown identifier"}`. Includes the case where the identifier exists for a *different* user — we do not leak its existence cross-user.
  - **Already cancelled / already failed**: **HTTP 200** with `{"status":"already_cancelled"}` / `{"status":"already_failed"}`. Idempotent.

### Response shapes

- Immediate webhook with no schedule: existing **HTTP 200** body extended to include the identifier — `{"identifier":"..."}`.
- Scheduled webhook (per [ADR-0015](0015-scheduled-and-delayed-notifications.md)): **HTTP 202 Accepted** with `{"identifier":"...","status":"scheduled","sendAt":<unix>}`.

## Consequences

- **+** Idempotent retries — the most common automation footgun (Zapier double-fire on a 502) becomes a no-op.
- **+** The cancel endpoint is the only safe way to revoke a 6-hour-delayed notification; without it, the scheduler from [ADR-0015](0015-scheduled-and-delayed-notifications.md) would be one-way.
- **+** Caller-supplied or backend-minted, the response always carries an identifier, so callers can build correlation without changing call sites.
- **+** Cross-user opacity: a cancel for someone else's identifier returns **404**, never **403** with a hint that it exists.
- **−** A 24 h dedup window means a row per fired notification in `idempotency_keys`, swept by the existing retention task. At 100 k pushes/month per user, this is ~3 k rows in flight at any moment — trivial for SQLite.
- **−** "Already delivered" cancels return **200**, not **404**, which is a small departure from REST orthodoxy but matches Pushcut and is the operator-friendly answer ("we tried, the cat is out of the bag").
- **−** The dedup is keyed on `(user_id, external_id, name)`. A caller that reuses the same `external_id` across different `name`s within 24 h gets two pushes — by design; same identifier, different intent.

## Operational rules

1. **Identifier validation is shared** with [ADR-0011](0011-notification-name-validation.md)'s name regex. One regex constant, two call sites. If we ever loosen one, the other gets reviewed at the same time.
2. **Cross-user lookups always return 404, never 403.** The cancel handler queries `WHERE external_id=? AND user_id=?` and treats zero rows as 404 regardless of whether the identifier exists for a different user.
3. **The idempotency cache is a SQLite table, not in-memory.** A backend restart must not re-fire a webhook that the previous instance already accepted. The cache outlives process lifetime by definition of the 24 h window.
4. **Cancel is best-effort against the scheduler race.** The scheduler may pick up a pending row in the same tick that cancel is processed. Resolve by `UPDATE ... WHERE status='pending'`; if it returns 0 rows, the scheduler won — respond `{"status":"already_delivered"}`.

## References

- [Pushcut webhook docs — `id`/`identifier`, cancel API](https://www.pushcut.io/support/notifications)
- [APNs delivery semantics — no recall after delivery](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)
- [ADR-0004](0004-pushcut-compat.md) — Pushcut-compatible webhook format. This ADR extends it.
- [ADR-0011](0011-notification-name-validation.md) — name regex, reused for identifiers.
- [ADR-0015](0015-scheduled-and-delayed-notifications.md) — scheduler that this cancel API targets.
- [ADR-0019](0019-rest-auth-and-listing.md) — REST auth model for the cancel endpoint.
