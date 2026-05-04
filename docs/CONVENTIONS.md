# Conventions

Project-wide code style, error handling, logging, and testing patterns. Per-language details live in `backend/CLAUDE.md` and `ios/CLAUDE.md`; this file captures cross-cutting rules.

## General

- **Comments**: write none by default. Add a one-liner only when the *why* is non-obvious (subtle invariant, hidden constraint, workaround for a specific bug, behavior that would surprise a reader). Never document the *what* — names should already convey that.
- **No premature abstraction.** Three similar lines is better than a configurable helper. Don't design for hypothetical future requirements.
- **No defensive code at internal boundaries.** Validate at system edges (HTTP requests, DB rows from disk). Trust internal callers; trust framework guarantees.
- **No dead code.** If a function/branch isn't reachable, delete it.
- **Errors are values, not surprises.** Explicit `Result` / `throws` at boundaries. Never swallow errors silently — log with context or propagate.

## Rust (`backend/`)

- **Edition**: 2021. MSRV: latest stable.
- **Async runtime**: `tokio` only. No `async-std`, no `smol`.
- **HTTP**: `axum` 0.7+. Handlers return `Result<impl IntoResponse, AppError>`.
- **DB**: `sqlx` with the macro form (`sqlx::query!`, `sqlx::query_as!`) so queries are type-checked at compile time against the live schema.
- **Errors**: one app-wide `AppError` enum implementing `IntoResponse`. Per-module errors are converted at module boundaries with `From` impls. Don't `unwrap()` outside of tests and `main()` startup.
- **Logging**: `tracing`. Structured fields, not interpolated strings: `tracing::info!(device_id = %id, "registered")`. Use `tracing::instrument` on handlers.
- **Time**: `time` crate. Store as Unix seconds (`i64`) in SQLite; convert at the application boundary.
- **IDs**: `uuid::Uuid::new_v4()` rendered as hyphenated lowercase strings. Webhook secrets: 32 bytes from `rand::rngs::OsRng`, URL-safe base64, no padding.
- **Config**: read once into a `Config` struct at startup via `envy` or hand-rolled `std::env`. Pass `Arc<Config>` through state. No `std::env::var` calls outside `config.rs`.

## SwiftUI (`ios/`)

- **Min iOS**: 17.0.
- **Architecture**: SwiftUI + `@Observable` view models. No UIKit unless absolutely required (e.g., `UIApplication.registerForRemoteNotifications`).
- **Networking**: `URLSession` with `async/await`. Centralize in `BackendClient`.
- **Persistence**: `UserDefaults` is fine for the device row (`webhookSecret`, `webhookUrl`); no Core Data.
- **Errors**: typed errors propagate to view models; views render error states explicitly.

## Testing

- **Backend**: `cargo test`. Unit tests inline (`#[cfg(test)] mod tests`); integration tests in `backend/tests/`. Integration tests hit a real SQLite file in a temp dir — never mock `sqlx`. APNs tests use the sandbox endpoint with a real device token from a Debug build.
- **iOS**: XCTest. Unit-test the `BackendClient` against a stub `URLProtocol`. Don't try to unit-test push delivery — that requires a physical device.
- **Pre-merge**: `cargo test` and `cargo clippy --all-targets -- -D warnings` must pass.

## Logging

- One log line per request at the boundary, with: device_id (if known), endpoint, status, duration_ms.
- Log APNs failures with the APNs reason string verbatim — Apple's reason codes are the most useful debugging signal.
- Don't log webhook payloads (may contain user data); log only metadata (size, name).
- Don't log secrets — never log `webhook_secret`, `apns_token`, or the contents of the `.p8` key.

## Git

- Conventional commits aren't enforced, but commit messages should describe the *why*, not the *what*.
- One logical change per commit.
- Don't commit `.env`, `*.p8`, `*.sqlite*`, or anything in `target/`.
