# Architecture Decision Records

Read before proposing architectural changes. ADRs are immutable once accepted — supersede with a new ADR rather than editing.

## Format

[Michael Nygard format](https://github.com/joelparkerhenderson/architecture-decision-record/blob/main/locales/en/templates/decision-record-template-by-michael-nygard/index.md): Title, Status, Context, Decision, Consequences. One file per decision, numbered sequentially.

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-direct-apns.md) | Use APNs directly, not FCM | Accepted |
| [0002](0002-rust-axum.md) | Rust + axum for the backend | Accepted |
| [0003](0003-sqlite-litestream.md) | SQLite (WAL) + Litestream for replication | Accepted (amended by 0010) |
| [0004](0004-pushcut-compat.md) | Pushcut-compatible webhook format | Accepted |
| [0005](0005-device-token-auth.md) | Device-token-only auth (no accounts) for v1 | Superseded by 0012 |
| [0006](0006-hetzner-deployment.md) | Hetzner CAX11 + Caddy + systemd as deployment target | Superseded by 0009 |
| [0007](0007-apns-token-auth.md) | APNs token (`.p8` JWT) auth, not certificate | Accepted |
| [0008](0008-monthly-usage-counter.md) | Authoritative `monthly_usage` counter, not `COUNT(*)` over the log | Accepted (amended by 0012) |
| [0009](0009-containerized-deployment.md) | Containerized deployment via Docker, persistent volume for state | Accepted |
| [0010](0010-litestream-optional.md) | Litestream replication is optional, controlled by env | Accepted |
| [0011](0011-notification-name-validation.md) | Notification name in URL: free-form label, regex `[A-Za-z0-9._-]{1,64}` | Accepted |
| [0012](0012-sign-in-with-apple.md) | Sign in with Apple as the identity layer; per-user webhook URLs | Accepted (supersedes 0005, amends 0008) |

## When to write a new ADR

- Switching a framework, runtime, or language
- Adding or removing a primary dependency that defines the architecture (the DB, the HTTP framework, the push provider)
- Changing the public API contract (URL shape, payload field semantics)
- Changing the auth/identity model
- Changing the deployment topology
- Changing a load-bearing data invariant (a table's primary key meaning, the source-of-truth for a counter)

If you're unsure: write the ADR. They're cheap; arguing about whether to write one is not.
