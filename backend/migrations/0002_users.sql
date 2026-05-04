-- 0002 — switch identity from device-keyed to user-keyed (Sign in with Apple)
-- See docs/adr/0012-sign-in-with-apple.md (supersedes ADR-0005, amends ADR-0008).
--
-- Drop-and-recreate is intentional: the device-token URL contract changes
-- entirely, and the user has approved a clean re-register from iOS.

DROP TABLE IF EXISTS rate_limit_buckets;
DROP TABLE IF EXISTS notifications_log;
DROP TABLE IF EXISTS monthly_usage;
DROP TABLE IF EXISTS devices;

CREATE TABLE IF NOT EXISTS users (
    id                TEXT PRIMARY KEY,             -- 32-char base62, CSPRNG
    apple_user_sub    TEXT NOT NULL UNIQUE,         -- 'sub' claim
    email             TEXT,                         -- one-shot from Apple
    is_private_email  INTEGER NOT NULL DEFAULT 0,
    created_at        INTEGER NOT NULL,
    last_seen_at      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_users_apple_sub ON users(apple_user_sub);

CREATE TABLE IF NOT EXISTS devices (
    id              TEXT PRIMARY KEY,
    user_id         TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    apns_token      TEXT NOT NULL UNIQUE,
    apns_env        TEXT NOT NULL CHECK (apns_env IN ('sandbox','production')),
    device_name     TEXT,
    created_at      INTEGER NOT NULL,
    last_seen_at    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_devices_user ON devices(user_id);

CREATE TABLE IF NOT EXISTS monthly_usage (
    user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    month       TEXT NOT NULL,                      -- 'YYYY-MM' UTC
    sent_count  INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, month)
);

CREATE TABLE IF NOT EXISTS notifications_log (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id     TEXT REFERENCES devices(id) ON DELETE SET NULL,
    name          TEXT,
    status        TEXT NOT NULL CHECK (status IN ('sent','failed','rate_limited','no_devices')),
    apns_status   INTEGER,
    apns_reason   TEXT,
    sent_at       INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_log_user_time ON notifications_log(user_id, sent_at DESC);
