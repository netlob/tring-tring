# 0003 — SQLite (WAL) + Litestream, no Postgres, no Docker for state

## Status

Accepted — 2026-05-04. **Amended by [ADR-0010](0010-litestream-optional.md)** (2026-05-04): Litestream replication is now optional at runtime, controlled by environment variables. The SQLite + WAL choice and all data-safety guarantees of this ADR remain in effect when Litestream is enabled.

## Context

The service needs durable storage for: registered devices (~thousands at most), a notification log (capped at ~90 days retention), and a per-device monthly usage counter. Projected write volume:

- **Launch**: ~100k notifications/month → ~2.3 writes/sec average.
- **Growth target**: 10M notifications/month → ~3.9 writes/sec average, ~40 writes/sec peak.

All writes funnel through a single Rust process. The workload is **single-writer** by construction.

The operator has prior bad experiences with Postgres operations under Docker (volume management, version upgrades, backup verification, recovery from crashes) and prioritizes "no data loss with minimum babysitting."

Three storage options were considered:

1. **Postgres in Docker** — operator's pain point. Stateful services in containers introduce volume mount complexity, complicate backups, and add little value for a single-host deployment.
2. **Postgres native (apt + systemd)** — reliable, but every Postgres deploy carries a tax: PG version upgrades, vacuum tuning, WAL archiving setup, restore drills against `pg_basebackup` archives.
3. **SQLite (WAL mode) + Litestream** — single file on disk, crash-safe with `synchronous=NORMAL`, continuous WAL replication to S3-compatible object storage. RPO ~1s, restore is one command. Genuinely fits the workload: SQLite handles 50k+ inserts/sec on commodity hardware in WAL mode, dwarfing the projected peak.

## Decision

- **Database**: SQLite, single file at `/var/lib/tring-tring/db.sqlite`.
- **Mode**: WAL journal, `synchronous=NORMAL`, `foreign_keys=ON`, `busy_timeout=5000ms`.
- **Replication**: [Litestream](https://litestream.io) running as its own systemd unit, replicating continuously to **Hetzner Object Storage** (S3-compatible).
- **Restore on fresh boot**: app's systemd unit declares `ExecStartPre=/usr/bin/litestream restore -if-replica-exists ...` so a destroyed VPS recovers automatically.
- **No Docker** for the application or the database. Both run as plain systemd units against the host filesystem.

## Consequences

- **+** Single-file backup story. The whole DB is one file; the WAL is small and replicated continuously.
- **+** Crash-safe by construction. `synchronous=NORMAL` + WAL guarantees durability up to the last fsync; the WAL is never half-written.
- **+** No DB server to babysit. No vacuum, no version upgrades, no connection pooling tuning beyond `sqlx`'s defaults.
- **+** Litestream is a single Go binary; configuration is one YAML file.
- **+** Hetzner Object Storage is S3-compatible and inexpensive (~€1/mo at our volume).
- **+** Migration to Postgres later is mechanical if needed: `sqlx`'s query API is portable and `monthly_usage` pre-computes what would otherwise be a `COUNT(*)` scan (see ADR-0008).
- **−** Single-writer constraint is permanent unless we adopt LiteFS or a different storage. We accept this; horizontal scaling is not in scope, and any VPS bottleneck will be APNs latency or TLS, not write contention.
- **−** Data lives on the VPS local disk. Mitigation: Litestream + Hetzner volume snapshots (€0.50/mo) provide two independent backup paths.
- **−** Litestream's Hetzner integration uses the generic S3 driver; if Hetzner Object Storage has an outage Litestream pauses replication (it does *not* block writes — local WAL grows until replication resumes). This is acceptable risk.

## Operational rules

1. **Never disable WAL mode.** Without WAL, `synchronous=NORMAL` is unsafe and concurrent reads block writers.
2. **The restore drill (runbook 0001) must pass on every fresh deploy.** Untested backups are not backups.
3. **Database file lives on a persistent volume.** Whether that volume is the host filesystem (native install) or a Docker named volume / Kubernetes PVC (containerized — see ADR-0009) is a deployment detail, but the volume must outlive any individual process or container. Ephemeral volumes are forbidden.
4. **Don't run multiple writers.** If horizontal scaling is ever needed, write a new ADR superseding this one (likely involving LiteFS or migrating to Postgres).

## References

- [SQLite WAL mode](https://www.sqlite.org/wal.html)
- [Litestream](https://litestream.io)
- [Hetzner Object Storage](https://www.hetzner.com/storage/object-storage/)
