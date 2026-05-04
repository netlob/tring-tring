-- 0001 — initial schema
-- See docs/adr/0003-sqlite-litestream.md for the storage architecture
-- and docs/adr/0008-monthly-usage-counter.md for why monthly_usage exists.

CREATE TABLE devices (
    id              TEXT PRIMARY KEY,             -- app-generated UUIDv4
    webhook_secret  TEXT NOT NULL UNIQUE,         -- 32-byte URL-safe base64
    apns_token      TEXT NOT NULL UNIQUE,         -- raw hex token from iOS
    apns_env        TEXT NOT NULL CHECK (apns_env IN ('sandbox', 'production')),
    device_name     TEXT,
    created_at      INTEGER NOT NULL,
    last_seen_at    INTEGER NOT NULL
);
CREATE INDEX idx_devices_secret ON devices(webhook_secret);

CREATE TABLE notifications_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id       TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    name            TEXT,
    status          TEXT NOT NULL CHECK (status IN ('sent', 'failed', 'rate_limited')),
    apns_status     INTEGER,
    apns_reason     TEXT,
    sent_at         INTEGER NOT NULL
);
CREATE INDEX idx_log_device_time ON notifications_log(device_id, sent_at DESC);

CREATE TABLE monthly_usage (
    device_id       TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    month           TEXT NOT NULL,                -- 'YYYY-MM' UTC
    sent_count      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (device_id, month)
);

CREATE TABLE rate_limit_buckets (
    device_id       TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
    tokens          REAL NOT NULL,
    last_refill_at  INTEGER NOT NULL              -- unix milliseconds
);
