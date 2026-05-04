# Runbook 0001 — Restore the SQLite database from Litestream

**Status**: Stub. Verify during deploy (build step 10) and replace this notice with a `Status: Verified <date>` line.

## When to run this

- Disaster recovery on a fresh VPS.
- Restoring to a point-in-time after data corruption or accidental deletion.
- Pre-deploy drill: confirm backups actually work.

## Prerequisites

- An S3-compatible bucket with at least one Litestream replication snapshot in it (i.e., the `LITESTREAM_*` env vars were set on the original deploy).
- Access to the deploy host (Coolify dashboard, or SSH for `docker compose` deploys).
- The image tag and env vars used by the existing deployment.

## Procedure (Coolify)

### 1. Stop the application

In the Coolify UI: **Application → Stop**.

### 2. Run a one-off restore container against the same volume

Coolify → **Terminal** on the host (or SSH directly). Find the volume name:

```bash
docker volume ls | grep tring
```

Run a temporary container with `litestream` and the same env vars to perform the restore:

```bash
docker run --rm \
  -v <volume-name>:/data \
  -e LITESTREAM_REPLICA_URL=<same as deploy> \
  -e LITESTREAM_ACCESS_KEY_ID=<same> \
  -e LITESTREAM_SECRET_ACCESS_KEY=<same> \
  -e LITESTREAM_REPLICA_ENDPOINT=<same> \
  ghcr.io/netlob/tring-tring:latest \
  /usr/local/bin/litestream restore \
    -if-replica-exists \
    -o /data/db.sqlite.restored \
    "$LITESTREAM_REPLICA_URL"
```

For a point-in-time restore, add `-timestamp 2026-05-04T12:34:56Z` before the URL.

### 3. Swap the restored file in

```bash
docker run --rm -v <volume-name>:/data ghcr.io/netlob/tring-tring:latest \
  sh -c '
    test -s /data/db.sqlite.restored || { echo "no restored file"; exit 1; }
    mv /data/db.sqlite /data/db.sqlite.bak.$(date -u +%Y%m%dT%H%M%SZ) 2>/dev/null || true
    rm -f /data/db.sqlite-shm /data/db.sqlite-wal
    mv /data/db.sqlite.restored /data/db.sqlite
  '
```

We move rather than delete so a failed restore can be reversed.

### 4. Restart and verify

Start the application from the Coolify UI. Watch logs for clean startup. Then:

```bash
docker exec <container-id> sqlite3 /data/db.sqlite \
  "SELECT COUNT(*) AS devices FROM devices; SELECT MAX(sent_at) AS last_log_unix FROM notifications_log;"
curl -fsS https://tring-tring.sjoerd.dev/healthz
```

Both DB numbers should be plausible (non-zero, recent).

### 5. Clean up

After confirming health and successful delivery of at least one new push, remove `/data/db.sqlite.bak.*` via another `docker run --rm`.

## Procedure (docker compose)

Same idea, simpler commands. The volume is already declared in `compose.yml`.

```bash
docker compose stop app
docker compose run --rm app /usr/local/bin/litestream restore \
  -if-replica-exists \
  -o /data/db.sqlite.restored \
  "$LITESTREAM_REPLICA_URL"

docker compose run --rm app sh -c '
  mv /data/db.sqlite /data/db.sqlite.bak.$(date -u +%Y%m%dT%H%M%SZ) 2>/dev/null || true
  rm -f /data/db.sqlite-shm /data/db.sqlite-wal
  mv /data/db.sqlite.restored /data/db.sqlite
'

docker compose up -d
docker compose exec app sqlite3 /data/db.sqlite "SELECT COUNT(*) FROM devices"
```

## Failure modes

- **`litestream restore: replica not found`**: the bucket is empty or `litestream.yml` points at the wrong path. Check that `litestream replicate` has been running successfully (`journalctl -u litestream`).
- **Restore succeeds but the service crashes on startup**: most likely a schema mismatch (DB was restored from a snapshot taken before the latest migration). Check `journalctl -u tring-tring`. Resolve by either rolling forward (`sqlx migrate run` against the restored DB) or restoring an earlier snapshot.
- **Restore takes longer than expected**: at our DB size, a full restore is seconds. Multi-minute restores indicate either a very large WAL chain (compaction overdue) or object storage throttling.

## Verified

| Date | By | Notes |
|---|---|---|
| _pending_ | | First end-to-end verification: build step 10. |
