# Runbook 0004 — Tune rate limits / quota for a specific device

**Status**: Stub. Verify on first incident.

## When to run this

- A specific user is hitting the global rate limit legitimately (e.g., heavy automation use) and you want to grant them a higher per-device limit.
- A device appears to be abusing the service and you want to lock it down or cap its monthly quota lower.
- A user reports their quota is reset incorrectly, or a one-off needs to be reset for support reasons.

## Background

Default limits are global, set via env vars:

- `RATE_LIMIT_PER_MINUTE=10` — token-bucket capacity per device per minute.
- `MONTHLY_QUOTA=100000` — sent pushes per device per UTC calendar month.

There is intentionally **no per-device override table** in the v1 schema. If/when you add one, write a new ADR (this is an architectural change). Until then, all of the procedures below operate on the existing schema.

## Procedure

All SQL operations below assume you can `docker exec` into the running app container. Replace `<container>` with the container name (Coolify shows it; with `docker compose` it's the compose service name).

### Find the device

```bash
docker exec -it <container> sqlite3 /data/db.sqlite <<'SQL'
.mode column
.headers on
SELECT id, device_name, apns_env, datetime(created_at, 'unixepoch') AS created_at
FROM devices
WHERE webhook_secret = '<secret>';
SQL
```

(Or look up by `device_name`, `apns_token`, etc. as needed.)

### Reset this device's monthly counter

```bash
docker exec -it <container> sqlite3 /data/db.sqlite <<SQL
UPDATE monthly_usage
SET sent_count = 0
WHERE device_id = '<device-id>'
  AND month = strftime('%Y-%m', 'now');
SQL
```

### Block this device

⚠ **PROD** — this prevents the device from sending pushes until reversed.

The cleanest "block" without schema changes: rotate the device's `webhook_secret` to a value the user does not know. The user must re-register the app to get a new URL.

```bash
docker exec -it <container> sqlite3 /data/db.sqlite <<SQL
UPDATE devices
SET webhook_secret = 'BLOCKED-' || hex(randomblob(16))
WHERE id = '<device-id>';
SQL
```

To unblock: contact the user, ask them to re-register, then optionally delete the blocked row:

```bash
docker exec -it <container> sqlite3 /data/db.sqlite \
  "DELETE FROM devices WHERE id = '<device-id>'"
```

### Bump the global limits

If many users hit the limit and the operator decides limits are too tight:

- **Coolify**: Application → Environment Variables → adjust `RATE_LIMIT_PER_MINUTE` / `MONTHLY_QUOTA` → **Restart**.
- **docker compose**: edit `.env`, then `docker compose up -d`.

This affects **all** devices on next request.

## Failure modes

- **`UPDATE` succeeds but the device is still rate-limited**: the in-memory `governor` bucket is independent of the DB and only resets on process restart. If a 429 from `governor` is the issue, restart the service. (For monthly quota updates, no restart is needed.)
- **Block didn't take effect immediately**: webhook lookups by secret are not cached; the next request will see the new value.

## Verified

| Date | By | Notes |
|---|---|---|
| _pending_ | | First operational use. |
