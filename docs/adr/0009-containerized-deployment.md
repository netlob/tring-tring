# 0009 — Containerized deployment via Docker, persistent volume for state

## Status

Accepted — 2026-05-04. **Supersedes [ADR-0006](0006-hetzner-deployment.md)** (native systemd on Hetzner).

## Context

ADR-0006 selected a native Linux + systemd deployment on a specific Hetzner VPS. The motivation was operational simplicity for a single-host deployment.

In practice, the operator wants:

1. **Portability**: deploy on Hetzner today, fly.io / Railway / a friend's home lab tomorrow, without rewriting the deploy story each time.
2. **Self-hosting friendliness**: this is an open-source project. Most self-hosters expect a Docker image; very few want to learn the operator's specific systemd unit choices.
3. **Coolify compatibility**: the operator uses [Coolify](https://coolify.io) (a self-hosted PaaS that orchestrates Docker containers, including persistent volumes and Let's Encrypt) as their preferred deploy surface.

ADR-0003's "no Docker for state" prohibition was a reaction to a specific anti-pattern: containers with **ephemeral** volumes. That risk does not apply when the container is deployed with an **explicit persistent volume** mounted at the SQLite data path — which is the standard pattern Coolify, fly.io, and any production Docker deployment use for stateful services.

Once data persistence is solved by a properly mounted volume, Docker's downsides (extra layer, slightly more complex local debugging) are outweighed by portability and ecosystem fit for an open-source project.

## Decision

- **Distribution unit**: a single Docker image, multi-arch (`linux/amd64` + `linux/arm64`), published from CI to GitHub Container Registry (`ghcr.io/sjoerdbolten/tring-tring`).
- **Image base**: `debian:bookworm-slim` for the runtime stage (small, glibc-based so we don't fight musl quirks with `rustls`/native TLS). Multi-stage build: `rust:1` for compile, `debian:bookworm-slim` for runtime. Includes `ca-certificates` and `litestream`.
- **Single process per container**: the Rust binary is PID 1 (via `tini` for signal handling). Litestream runs **inside the same image** as a subordinate process supervised by the entrypoint script when configured (see ADR-0010), not as a separate container — this keeps the deployment to "one container with one volume" for any Docker host.
- **Persistent volume**: mount any persistent volume at `/data`. The SQLite DB lives at `/data/db.sqlite`. The image refuses to start if `/data` is not writable.
- **Configuration**: all config via environment variables. No bind-mounted config files except the APNs `.p8` key, which can also be supplied via env (`APNS_KEY_PEM` containing the PEM contents) for platforms that don't support secret files.
- **Reverse proxy + TLS**: out of scope for the image. Coolify (or any host) provides Let's Encrypt termination and proxies HTTPS to container port `8080`. The image listens on `0.0.0.0:8080` HTTP only.
- **Recommended deploy targets**, all equivalent from the image's perspective:
  - **Coolify** on a Hetzner CAX11 (operator's choice).
  - `docker compose up -d` on any Linux host with a named volume.
  - fly.io with a `[mounts]` block.
  - Kubernetes with a `PersistentVolumeClaim`.
- **Local development**: a `docker-compose.yml` at the repo root spins up the app + a named volume, for parity with prod.

## Consequences

- **+** Portable. Anyone can `docker run` this in 30 seconds with one volume mount and the right env vars.
- **+** Coolify users have a one-click deploy story (just point at the image, set env, attach a volume).
- **+** CI publishes images on every tag/main push; rolling forward is `pull && restart`, rolling back is `pull <previous-tag> && restart`.
- **+** Local dev parity: `docker compose up` replicates prod's container topology.
- **−** ~30 MB image instead of a ~15 MB static binary. Acceptable.
- **−** Operator must remember to provision a persistent volume. This is documented prominently in the README and in runbook 0003. Coolify defaults to creating one when you tick "Persistent storage" — not a real footgun on that platform.
- **−** Debugging needs `docker exec` instead of plain shell access. Runbook 0001 (restore drill) and runbook 0004 (rate-limit tuning) are updated to use `docker exec` patterns.
- **−** Multi-arch CI takes a bit longer than single-arch. Negligible for our cadence.

## Operational rules

1. **The volume at `/data` is not optional.** Without it, all data is lost on container restart. The image's entrypoint exits with a clear error if `/data` is not writable.
2. **No bind mounts to host paths in production.** Use Docker named volumes (or PVCs on Kubernetes / Coolify's persistent storage). Bind mounts work but make backups and migration harder.
3. **Don't put the `.p8` in the image.** Mount it as a Docker secret, env var (`APNS_KEY_PEM`), or read it from a file path inside `/data` (not in `/etc` of the image).
4. **Litestream runs in the same container** when enabled. If a future scale story demands a separate Litestream sidecar, write a new ADR.

## References

- [Coolify docs — Persistent storage](https://coolify.io/docs/applications/persistent-storage)
- [Litestream's recommended Docker integration](https://litestream.io/guides/docker/)
- [tini](https://github.com/krallin/tini) — minimal init for containers
