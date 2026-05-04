-- 0003 — full Pushcut spec scaffold (ADR-0013 .. 0019).
--
-- Adds:
--   - notifications_log.external_id (ADR-0014)
--   - scheduled_notifications (ADR-0015)
--   - notification_templates (ADR-0018)
--   - pending_actions (ADR-0017)
--
-- All additive; no DROP. Migration 0002's tables remain untouched.

ALTER TABLE notifications_log ADD COLUMN external_id TEXT;
CREATE INDEX idx_log_external_id ON notifications_log(user_id, external_id);

CREATE TABLE scheduled_notifications (
    id              TEXT PRIMARY KEY,
    user_id         TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    external_id     TEXT,
    payload_json    TEXT NOT NULL,
    send_at         INTEGER NOT NULL,            -- unix seconds
    status          TEXT NOT NULL CHECK (status IN ('pending', 'dispatched', 'cancelled', 'failed')),
    created_at      INTEGER NOT NULL,
    dispatched_at   INTEGER,
    failed_reason   TEXT
);
CREATE INDEX idx_scheduled_due ON scheduled_notifications(status, send_at);
CREATE INDEX idx_scheduled_user ON scheduled_notifications(user_id, status);
CREATE INDEX idx_scheduled_external_id ON scheduled_notifications(user_id, external_id);

CREATE TABLE notification_templates (
    user_id         TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    default_payload TEXT NOT NULL,                -- raw JSON object
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL,
    PRIMARY KEY (user_id, name)
);

CREATE TABLE pending_actions (
    id                  TEXT PRIMARY KEY,        -- UUID
    user_id             TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    notification_log_id INTEGER REFERENCES notifications_log(id) ON DELETE SET NULL,
    action_name         TEXT NOT NULL,
    payload_json        TEXT NOT NULL,            -- the action object (url, urlBackgroundOptions, etc.)
    created_at          INTEGER NOT NULL,
    expires_at          INTEGER NOT NULL          -- unix seconds, retention task sweeps after this
);
CREATE INDEX idx_pending_actions_user ON pending_actions(user_id, action_name);
CREATE INDEX idx_pending_actions_expiry ON pending_actions(expires_at);
