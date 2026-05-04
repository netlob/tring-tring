# 0015 — Scheduled and delayed notifications

## Status

Accepted — 2026-05-05. Extends [ADR-0004](0004-pushcut-compat.md).

## Context

Pushcut's webhook contract supports two ways to defer dispatch:

- `delay`: a duration string (`"5s"`, `"1h 5m 10s"`) — fire that long from now.
- `scheduleTimestamp`: a Unix milliseconds timestamp — fire at that wall-clock moment.

[ADR-0004](0004-pushcut-compat.md) deferred this on the grounds that it requires a job queue. The job queue can now be implemented cheaply: SQLite is the source of truth ([ADR-0003](0003-sqlite-litestream.md)), Litestream replicates it ([ADR-0010](0010-litestream-optional.md)), and a single Tokio task polling at 1 Hz is sufficient throughput for a service whose rate limit is 10 / minute / device.

Two design choices worth being explicit about:

1. **In-process scheduler vs. external queue.** A separate queue (Redis, RabbitMQ, etc.) would add an operational dependency and another piece to back up. SQLite already has the durability and replication we need. The scheduler is just a polling loop.
2. **Crash recovery.** Because SQLite is the source of truth and the scheduler reads it on every tick, a backend crash + restart simply resumes from where the table says — no in-memory state to reconcile. Missed-window pushes fire on the next tick (best-effort catchup).

The hardest call is the maximum delay. APNs allows arbitrary scheduling on our side (it's a client-side concept — APNs only sees the push when we send it), but the longer we hold a push, the more likely the device token has rotated, the user has uninstalled, or the operator has rebuilt the database. We pick **7 days** as the cap.

## Decision

### Webhook contract

- Webhook accepts `delay` (string, e.g. `"5s"`, `"1h 5m 10s"`, max parts: hours, minutes, seconds) **or** `scheduleTimestamp` (number, Unix milliseconds). Both is an error → **HTTP 400** `{"error":"specify delay OR scheduleTimestamp, not both"}`.
- `delay` parsing: whitespace-tolerant, case-insensitive. Accepts `Nh`, `Nm`, `Ns` parts in any order. Rejects unknown unit suffixes.
- The computed dispatch time is clamped to the **future**: `scheduleTimestamp` in the past → **HTTP 400** `{"error":"scheduleTimestamp is in the past"}`. (`delay` of `"0s"` or absent → immediate path, unchanged.)
- The computed dispatch time may be **at most 7 days from now**. Beyond that → **HTTP 400** `{"error":"schedule exceeds 7-day cap"}`.
- A scheduled webhook returns **HTTP 202 Accepted** with body `{"identifier":"<external_id>","status":"scheduled","sendAt":<unix-seconds>}`. The immediate path (no `delay`, no `scheduleTimestamp`) returns **HTTP 200** unchanged.

### Storage

New table:

```sql
CREATE TABLE scheduled_notifications (
  id            BLOB PRIMARY KEY,                -- UUIDv7
  user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,                   -- the notification name (URL label, ADR-0011)
  external_id   TEXT NOT NULL,                   -- caller-supplied or minted (ADR-0014)
  payload_json  TEXT NOT NULL,                   -- the full webhook payload, verbatim
  send_at       INTEGER NOT NULL,                -- Unix seconds, dispatch target
  status        TEXT NOT NULL,                   -- 'pending' | 'dispatched' | 'cancelled' | 'failed'
  created_at    INTEGER NOT NULL,
  dispatched_at INTEGER                          -- NULL until status leaves 'pending'
);

CREATE INDEX scheduled_notifications_due
  ON scheduled_notifications(send_at, status)
  WHERE status = 'pending';
```

The partial index keeps the polling query cheap as `dispatched`/`cancelled`/`failed` rows accumulate.

### Scheduler

- A single Tokio task ticks every **1 second**:
  ```sql
  SELECT id, user_id, name, external_id, payload_json
    FROM scheduled_notifications
   WHERE status = 'pending' AND send_at <= ?
   ORDER BY send_at ASC
   LIMIT 100;
  ```
- For each row: dispatch via the existing fan-out path (the same code path the immediate webhook uses), then transition status:
  - All-device delivery had at least one success → `status='dispatched', dispatched_at=NOW`.
  - Every device failed → `status='failed', dispatched_at=NOW`.
  - Anywhere a transient error escaped (e.g. APNs 5xx for all devices) → leave `status='pending'`, log a warning, retry on next tick (the row stays due).
- The 100-row LIMIT bounds the work-per-tick. At 1 Hz this is 360 k pushes/hour throughput ceiling — well above the user-facing rate limit.

### Restart safety

- The scheduler is **replay-safe by construction**: it reads from SQLite on every tick, holds no in-memory state.
- On startup, due rows fire immediately (best-effort missed-window catchup). Documented user-visible drift: tens of seconds at most, longer if the backend was down through a scheduled fire time.
- Litestream restore (per [runbook 0001](../runbooks/INDEX.md)) brings back pending rows; they fire as soon as the restored backend ticks.

### Quota and rate-limit accounting

- Quota is consumed at **dispatch** time, not schedule time. A scheduled push that gets cancelled before firing does not count against `monthly_usage` ([ADR-0008](0008-monthly-usage-counter.md), as amended by [ADR-0012](0012-sign-in-with-apple.md)).
- Rate-limit (10 / min / user, [ADR-0008](0008-monthly-usage-counter.md)) is checked at **schedule** time, against the user's bucket at that moment. Rationale: a caller that schedules 100 pushes for 09:00 tomorrow should hit the rate limit *now*, not 09:00 tomorrow when they're not watching. Otherwise scheduling becomes a rate-limit-bypass tool.

## Consequences

- **+** No new operational dependency. The scheduler is a Tokio task in the same binary, against the same SQLite file Litestream is already replicating.
- **+** Replay-safe restart. The "missed-window catchup" is the natural consequence of a polling design — no state-machine code to write.
- **+** Quota fairness: cancellation refunds quota; scheduling does not bypass rate limits.
- **+** The 7-day cap is a sensible upper bound. Beyond it, device tokens are likely stale and the deliverability story degrades anyway.
- **−** Worst-case dispatch latency is 1 second + one fan-out duration. For a webhook-forwarder this is fine; for a precise alarm-clock product, it would not be.
- **−** A long backend outage straddling a scheduled fire time produces a "best-effort late" delivery on restart. This may or may not be the operator's intent; document it.
- **−** `payload_json` stores the full webhook body verbatim, including any large `imageData`. With a 4 KB envelope cap from [ADR-0013](0013-rich-content-payloads.md) and a 7-day cap, the worst case is ~28 MB per user (7 days × 100 k/month × 4 KB amortized) — well within SQLite's comfort zone.
- **−** The 1 Hz tick is wasted CPU when the queue is empty. Acceptable: `SELECT … LIMIT 100` against the partial index is microseconds. We do not optimize this further until measurement says otherwise.

## Operational rules

1. **The scheduler is a single Tokio task, not a thread pool.** Concurrency on dispatch comes from the existing fan-out (`futures::future::join_all`), not from running many scheduler ticks in parallel. Multiple schedulers fighting over the same `pending` rows would need row-level locking we don't have on SQLite.
2. **Cancellation is idempotent and racey-by-design.** A cancel that lands during the same tick the scheduler picks up the row may lose the race. Cancel handler resolves this by `UPDATE … WHERE status='pending'` and reports `already_delivered` if 0 rows updated (see [ADR-0014](0014-notification-identifiers-and-cancel.md)).
3. **Quota refund on cancel** is *not* a thing. Quota is only consumed on dispatch — scheduling reserves a rate-limit slot but not a quota slot.
4. **`payload_json` is opaque to the scheduler.** All validation (regex, sizes, etc.) happens at schedule time. The dispatcher only deserializes and fan-outs; it does not re-validate. This keeps the dispatch path fast and means a schema change to webhook validation does not break already-scheduled rows.

## References

- [Pushcut webhook docs — `delay`, `scheduleTimestamp`](https://www.pushcut.io/support/notifications)
- [Tokio task scheduling](https://tokio.rs/tokio/tutorial/spawning)
- [SQLite partial indexes](https://www.sqlite.org/partialindex.html)
- [ADR-0004](0004-pushcut-compat.md) — Pushcut-compatible webhook format. This ADR extends it.
- [ADR-0008](0008-monthly-usage-counter.md) — quota counter.
- [ADR-0012](0012-sign-in-with-apple.md) — fan-out path the dispatcher reuses.
- [ADR-0014](0014-notification-identifiers-and-cancel.md) — `external_id` and the cancel API that targets pending rows.
