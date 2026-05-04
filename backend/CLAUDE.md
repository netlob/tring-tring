# backend/CLAUDE.md

> Read root [`CLAUDE.md`](../CLAUDE.md) first. This file covers backend-specific context.

## What's here

A single Rust binary (`tring-tring`) that:
1. Receives webhooks at `POST/GET /{secret}/notifications/{name}`.
2. Authenticates them by looking up `webhook_secret` in SQLite.
3. Enforces rate limits + monthly quota.
4. Builds an APNs payload and forwards it via a long-lived HTTP/2 connection.
5. Records the result in `notifications_log` and bumps `monthly_usage`.

## Module map

| Path | Purpose |
|---|---|
| `src/main.rs` | bootstrap, server, graceful shutdown, `AppState` |
| `src/config.rs` | env → `Config` struct, validates required vars at startup |
| `src/db.rs` | `SqlitePool` constructor; sets WAL mode, `synchronous=NORMAL`, FK on; runs migrations |
| `src/error.rs` | `AppError` enum with `IntoResponse`; all handlers return `AppResult<T>` |
| `src/routes/mod.rs` | aggregates route modules |
| `src/routes/health.rs` | `GET /healthz` |
| `migrations/0001_init.sql` | initial schema (see ADR-0008) |

Future modules (added in subsequent build steps):

| Path | Purpose |
|---|---|
| `src/apns.rs` | `a2::Client` wrapper; one persistent client per process |
| `src/rate_limit.rs` | `governor` token-bucket per device + monthly quota check |
| `src/retention.rs` | nightly task: delete log >90d, `wal_checkpoint(TRUNCATE)` |
| `src/routes/devices.rs` | `POST /v1/devices` registration |
| `src/routes/notify.rs` | Pushcut-compatible webhook endpoint |
| `src/models.rs` | DB row types + Serde DTOs |

## Hard constraints (these fail the build / break prod if violated)

1. **`a2::Client` is constructed exactly once at startup.** The JWT-cached HTTP/2 connection is the whole point. Per-request construction triggers `TooManyProviderTokenUpdates` and tanks throughput.
2. **JWT refresh cadence is 20–60 min, target ~45 min.** `a2` handles this internally — don't reimplement.
3. **The webhook handler must wrap the `notifications_log` insert and the `monthly_usage` increment in a single SQLite transaction.** ADR-0008 invariant.
4. **WAL mode is enforced at startup.** `db::connect` checks `PRAGMA journal_mode` and aborts if it's not `wal`.
5. **The `monthly_usage` counter is only incremented on `status='sent'`.** Never on rate-limited or failed pushes.
6. **No `unwrap()` outside tests and program startup.** Use `AppError` everywhere else.
7. **Don't log secrets.** Never log `webhook_secret`, `apns_token`, JWT contents, or `.p8` material.

## Local dev

```bash
cd backend
cp .env.example .env       # fill in APNS_* values; place apns.p8 next to .env

cargo check                # quick error check
cargo run                  # runs against ./data/db.sqlite (sqlite auto-creates)
cargo clippy --all-targets -- -D warnings
```

For prod-parity local dev, use Docker from the repo root:

```bash
docker compose up --build  # http://127.0.0.1:8080, named volume for data
```

## Testing notes

- Integration tests under `tests/` should use a temp-dir SQLite file (`tempfile::tempdir`).
- For APNs, hit the **sandbox** endpoint with a real device token from a Debug iOS build. Don't mock `a2` — the value of these tests is exactly that they exercise the real wire format.
- Tests are deferred for v1 (per agreement). When added, follow the patterns in `docs/CONVENTIONS.md`.

## Dockerfile / entrypoint

- `Dockerfile` is multi-stage: `rust:1-bookworm` builds, `debian:bookworm-slim` runs. Litestream is downloaded as the matching arch `.deb`.
- `entrypoint.sh` performs:
  1. Verify `/data` is writable (refuses to start otherwise — ADR-0009).
  2. Materialize `APNS_KEY_PEM` to a tmpfs path if no `APNS_KEY_PATH` is set.
  3. If `LITESTREAM_REPLICA_URL` is set, render `/etc/litestream.yml` from env, attempt `litestream restore -if-replica-exists`, then `exec litestream replicate -exec tring-tring`.
  4. Otherwise `exec /usr/local/bin/tring-tring`.

## ADR cross-reference

- [ADR-0002](../docs/adr/0002-rust-axum.md) — Rust + axum
- [ADR-0003](../docs/adr/0003-sqlite-litestream.md) — SQLite + WAL
- [ADR-0007](../docs/adr/0007-apns-token-auth.md) — `.p8` JWT
- [ADR-0008](../docs/adr/0008-monthly-usage-counter.md) — counter invariants
- [ADR-0009](../docs/adr/0009-containerized-deployment.md) — Docker + `/data` volume
- [ADR-0010](../docs/adr/0010-litestream-optional.md) — Litestream toggled by env
- [ADR-0011](../docs/adr/0011-notification-name-validation.md) — name regex
