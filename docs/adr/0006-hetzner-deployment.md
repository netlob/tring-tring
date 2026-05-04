# 0006 — Hetzner CAX11 + Caddy + systemd as deployment target

## Status

**Superseded by [ADR-0009](0009-containerized-deployment.md)** (2026-05-04). Deployment topology is now containerized (Docker image, deployable via Coolify or any Docker host). The Hetzner CAX11 sizing recommendation in this ADR is still useful as a reference; the native systemd + Caddy + apt-installed Litestream specifics are obsolete. Read this ADR for historical context only.

## Context

The financial model is "operator absorbs infrastructure cost in exchange for a generous free tier." This puts a hard ceiling on hosting cost: it must be small enough that the operator does not feel pressure to introduce paid tiers prematurely.

Estimated peak workload: ~40 webhook requests/sec, each issuing one APNs push over a long-lived HTTP/2 connection. CPU is dominated by TLS termination and JSON parsing. Memory is dominated by SQLite page cache and `sqlx` connection pool. Disk is dominated by the SQLite DB plus Litestream's WAL shadow files.

Options considered:

- **Hetzner CAX11** (ARM, 2 vCPU, 4 GB RAM, 40 GB NVMe, 20 TB egress) — ~€3.29/mo. Way more capacity than projected peak.
- **Hetzner CX22** (x86, 2 vCPU, 4 GB RAM) — ~€3.79/mo. Same generation, slightly more expensive for marginally higher x86 single-thread perf.
- **Smaller VPS providers** (Vultr, Linode, DigitalOcean cheapest tiers) — comparable in price; Hetzner has the cheapest egress in this class.
- **Managed PaaS (Fly.io, Railway, etc.)** — easier ops but free tiers don't accommodate this workload reliably and paid tiers exceed budget at ~10M/mo.

For TLS and reverse proxying: **Caddy** auto-provisions Let's Encrypt certs and reloads on config change with zero ceremony. Nginx and Traefik are alternatives but neither is simpler than Caddy for this use case.

For process supervision: **systemd** is already on every modern Linux distro and integrates cleanly with `journalctl`, `ExecStartPre`, restart policies, and resource limits. No additional tool needed.

## Decision

- **Compute**: Hetzner CAX11 (ARM Ampere, 2 vCPU, 4 GB RAM). Ubuntu LTS.
- **TLS**: Caddy as reverse proxy on `:443`, terminating TLS, proxying HTTP to `127.0.0.1:8080`.
- **Process management**: systemd units for the Rust app and Litestream. No Docker.
- **Object storage for backups**: Hetzner Object Storage (S3-compatible), separate region from the VPS where practical.
- **Domain**: operator-supplied. DNS A record points to the VPS IPv4; AAAA points to its IPv6.

## Consequences

- **+** Total infrastructure cost target: under €5/mo for compute + object storage. Optional Hetzner volume snapshots (€0.50/mo) add a second backup path.
- **+** ARM works fine for our stack: `axum`, `sqlx`, `a2`, `litestream` all build cleanly for `aarch64-unknown-linux-gnu`.
- **+** No vendor lock-in. The whole deployment is "Linux + systemd + a SQLite file"; moving to any other Linux VPS is a copy of the file plus systemd units.
- **−** Single-region, single-host. No HA story. Acceptable for v1; the failure mode is "service down for the duration of a Hetzner incident, restored from object storage on a fresh VPS."
- **−** ARM means cross-compilation in CI when build hosts are x86. Mitigation: build on the VPS itself, or use `cross`.
- **−** No autoscaling. If usage truly outgrows the box, the next ADR will introduce a horizontal story (likely with implications for ADR-0003 since SQLite is single-writer).

## When to supersede

Write a new ADR if any of these change:
- Cost ceiling changes (paid tiers, sponsorships, etc.).
- HA / multi-region becomes a requirement.
- Workload grows past what a single CAX11 can serve.
