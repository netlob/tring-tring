# 0002 — Rust + axum for the backend

## Status

Accepted — 2026-05-04.

## Context

The backend's job is small and stable: receive HTTP webhooks, look up a device by secret, enforce a rate limit, and forward an APNs push over a long-lived HTTP/2 connection. Candidates considered:

- **Node.js / TypeScript** — operator's day-job stack; ergonomic; mature APNs libraries. Rejected on grounds of operator preference for a "non-boring" stack and concerns about long-running process resource use vs Rust on a tiny VPS.
- **Go** — fallback if Rust APNs support were inadequate. It is not.
- **Rust** — preferred. Single statically-linked binary; minimal memory footprint; mature async ecosystem; production-grade APNs client (`a2`, used by Reown at millions of pushes/day).

For the HTTP framework: `axum` is the de-facto choice on `hyper`/`tower`, well-documented, and integrates cleanly with the existing async ecosystem.

The operator does not write Rust fluently and intends to vibe-code via Claude Code. This is not a constraint against Rust; LLM tooling handles Rust well, and the decision documents (`CLAUDE.md`, ADRs, conventions) provide the per-session context needed.

## Decision

- **Language**: Rust, edition 2021, latest stable toolchain.
- **HTTP framework**: `axum` 0.7+.
- **Async runtime**: `tokio`.
- **APNs client**: `a2` ([reown-com/a2](https://github.com/reown-com/a2)).
- **Database access**: `sqlx` with compile-time-checked queries.

## Consequences

- **+** Single static binary, ~10–20 MB after release build. Ideal for a small VPS.
- **+** Memory footprint at idle is tens of MB, not hundreds. Headroom on a 4 GB box for the DB cache and Litestream.
- **+** `sqlx`'s compile-time query checking catches schema/code drift before deploy.
- **+** Strong type system reduces a class of bugs; LLM-generated code is easier to verify when the compiler is strict.
- **−** Compile times are slower than TypeScript or Go; less material in CI and not material at all in dev once `cargo` caches warm.
- **−** Operator cannot fluently audit Rust code without LLM assistance. Mitigation: ADRs and CLAUDE.md keep architectural intent legible to humans regardless of language.

## References

- [a2 crate](https://crates.io/crates/a2)
- [axum documentation](https://docs.rs/axum/latest/axum/)
- [sqlx documentation](https://docs.rs/sqlx/latest/sqlx/)
