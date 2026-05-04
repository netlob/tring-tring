# 0010 — Litestream replication is optional, controlled by env

## Status

Accepted — 2026-05-04. **Amends [ADR-0003](0003-sqlite-litestream.md)**: the SQLite + WAL choice stands; what changes is that Litestream replication is no longer mandatory.

## Context

ADR-0003 made Litestream a load-bearing part of the data-safety story (RPO ~1s via continuous WAL replication to object storage). For a single-operator-hosted production deployment, that's the right default.

But:

1. **Self-hosters** running this image may not want to provision an S3-compatible bucket on day one. Forcing them to is a deploy-time blocker for a single command (`docker run`-style trial).
2. **Local development** doesn't need replication at all — a Docker volume is plenty.
3. **Some platforms** (fly.io with their volume snapshots, Coolify with its built-in backup story, Hetzner with volume snapshots) provide their own backup mechanism that may overlap or replace Litestream.

The data-safety guarantees of ADR-0003 are preserved when Litestream is enabled. The decision here is purely about whether the application *requires* Litestream to be configured to start.

## Decision

- **Litestream is optional, controlled at runtime by environment variables.**
- The application starts and runs identically whether or not Litestream is configured.
- The container's entrypoint script enables Litestream **if and only if** all of the following env vars are set:
  - `LITESTREAM_REPLICA_URL` (e.g., `s3://bucket/path`)
  - `LITESTREAM_ACCESS_KEY_ID`
  - `LITESTREAM_SECRET_ACCESS_KEY`
  - `LITESTREAM_REPLICA_ENDPOINT` (the S3-compatible endpoint URL; can be omitted for AWS S3)
- When Litestream is enabled, the entrypoint runs `litestream restore -if-replica-exists` against `/data/db.sqlite` *before* starting the app, then exec's `litestream replicate ... -- /usr/local/bin/tring-tring` so the app and Litestream share a process group and Litestream cleanly tails the WAL.
- When Litestream is **not** enabled, the entrypoint exec's the app directly. Logs make it explicit: `litestream: disabled (set LITESTREAM_REPLICA_URL to enable)`.
- The image's `/healthz` endpoint reports replication status (enabled/disabled, last successful replication timestamp when available) so operators can see whether they're protected.

## Consequences

- **+** Trivial to evaluate the project: `docker run -v tring-data:/data -e APNS_*... ghcr.io/.../tring-tring` works without a bucket.
- **+** Self-hosters who *do* configure Litestream get full ADR-0003 guarantees (RPO ~1s, point-in-time restore).
- **+** Local dev and CI can omit object storage entirely.
- **−** Operators who deploy to production without setting Litestream env vars get **no off-host backup**. Their data is only as safe as their volume / host snapshots. The `/healthz` endpoint and startup log warn about this, but operators can still ignore the warning.
- **−** The README and runbook 0001 must clearly distinguish "with Litestream" vs "without Litestream" backup paths. Without Litestream, the recovery story is "whatever your host platform's volume backup provides."
- **−** Tests cover both modes (mode selection logic) but not actual S3 traffic.

## Mitigation for the "no backup" footgun

- The README explicitly recommends configuring Litestream for any deployment that holds non-throwaway data, with one-line copy-paste config for Hetzner Object Storage and AWS S3.
- The `/healthz` JSON includes `replication: "disabled"` so external monitoring can alert on it.
- A future ADR could make Litestream "warn-only" → "required for production env" by adding an `ENVIRONMENT=production` flag that gates startup. Out of scope for v1.

## References

- See ADR-0003 for the storage architecture this amends.
- See ADR-0009 for the containerized deploy that motivates this option.
