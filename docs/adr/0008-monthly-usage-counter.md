# 0008 — Authoritative `monthly_usage` counter, not `COUNT(*)` over the log

## Status

Accepted — 2026-05-04. **Amended by [ADR-0012](0012-sign-in-with-apple.md)** (2026-05-04): the counter is now keyed on `user_id` (not `device_id`) and increments **once per webhook**, not per device fan-out. The original invariants (only on `status='sent'`, transactional with the log row) are preserved at the user level.

## Context

The free-tier business rule is "no more than N pushes per device per calendar month." Two implementations were considered:

1. **Compute on read**: `SELECT COUNT(*) FROM notifications_log WHERE device_id = $1 AND sent_at >= <month_start> AND status = 'sent'`. Simple. Correct by construction (the log *is* the truth).
2. **Authoritative counter**: a separate `monthly_usage(device_id, month, sent_count)` table, incremented in the same transaction as the log insert.

The log is also retention-bounded: rows older than 90 days are deleted nightly (so the DB doesn't grow unboundedly at 10M rows/month). If the quota window ever exceeds the retention window — or if log retention were ever shortened — option (1) would silently undercount.

At the upper end of projected scale (~40 writes/sec, ~10M rows/month), `COUNT(*)` over the current month's log is still cheap with the right index, but it's a scan that runs on every webhook — adding latency proportional to monthly push volume.

## Decision

Use a `monthly_usage` table:

```sql
CREATE TABLE monthly_usage (
  device_id   TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  month       TEXT NOT NULL,    -- 'YYYY-MM' in UTC
  sent_count  INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device_id, month)
);
```

- The webhook handler increments `sent_count` in the same transaction that inserts the log row, **only when the push is actually sent** (not for rate-limited or failed pushes).
- The quota check is a single primary-key lookup: O(1) regardless of monthly volume.
- The "month" key is `YYYY-MM` in **UTC**. We do not localize the month boundary per device.

## Consequences

- **+** Quota check is O(1), not a scan. Decoupled from log retention policy.
- **+** Log retention can be shortened (e.g., to 30 days) without affecting quota correctness.
- **+** The schema makes the monthly counter a first-class concept; analytics and dashboards have a clean read source.
- **−** The counter and the log can diverge if a bug causes one to update without the other. Mitigation: both updates happen in a single SQLite transaction; integration tests assert they remain consistent.
- **−** Resetting a quota for a single device requires touching `monthly_usage` directly (see runbook 0004), not just deleting log rows.
- **−** Calendar-month boundaries in UTC mean a device near the antimeridian sees their quota reset at a non-local time. Acceptable; documenting this transparently is sufficient.

## Invariants enforced

1. The webhook handler **must** wrap the log insert and the `monthly_usage` increment in a single transaction. Tests assert this.
2. Failed APNs sends do **not** increment the counter (status `failed` in the log; counter unchanged).
3. Rate-limited requests do **not** increment the counter (no log row, no increment).

## References

- See ADR-0003 for the database choice and retention rules.
