# CLAUDE.md — tring-tring

> Read this file first. It is the single entry point for any Claude Code session in this repo.

## What this is

A self-hosted iOS push notification service: receive a webhook → deliver an APNs push to a registered device. Drop-in compatible with Pushcut's webhook format. Rust backend on a single Hetzner VPS, SwiftUI iOS app. Designed to run a generous free tier (10/min per device, 100k–10M notifications/month) on a few euros of infrastructure.

## Repo map

```
backend/        Rust service (axum + a2 + sqlx/SQLite). See backend/CLAUDE.md.
ios/            SwiftUI app. See ios/CLAUDE.md.
docs/
  CONVENTIONS.md     Code style, error handling, logging, testing.
  adr/INDEX.md       Architecture Decision Records — read before changing architecture.
  runbooks/INDEX.md  Operational procedures (restore, key rotation, deploy, tuning).
```

## Hard rules (read before editing)

1. **ADRs are immutable.** Every architectural choice in this repo has an ADR in `docs/adr/`. Never edit the Decision section of an accepted ADR. To change a decision, write a new ADR that supersedes the old one and update the old one's Status to `Superseded by ADR-XXXX`.
2. **Every architectural change requires an ADR.** Switching frameworks, swapping databases, changing the auth model, altering the public webhook contract — all require a new ADR before code changes land. If you're unsure whether something is "architectural", err on the side of writing an ADR.
3. **Read `docs/adr/INDEX.md` before proposing architectural changes.** Most "obvious improvements" are deliberate decisions documented there. Honor existing ADRs unless you supersede them.
4. **Runbooks must be verified, not theoretical.** When you write a runbook, run it end-to-end and capture the actual commands and observed output. Stub runbooks must be marked `Status: Stub` until verified.
5. **Conventions live in `docs/CONVENTIONS.md`.** Don't inline code-style guidance in this file or in subdirectory CLAUDE.md files — link to CONVENTIONS instead.
6. **No data loss.** SQLite is the source of truth; Litestream replicates continuously to object storage. Never disable WAL mode, never skip the restore drill on deploy, never run the database in a container with an ephemeral volume.

## Quick commands

```bash
# Backend (local, native)
cd backend
cp .env.example .env       # then fill in APNS_* vars
cargo run                  # http://127.0.0.1:8080
cargo check
cargo clippy --all-targets -- -D warnings

# Backend (local, container — matches prod)
docker compose up --build  # http://127.0.0.1:8080, data in named volume

# iOS
open ios/TringTring/TringTring.xcodeproj
# Push notifications require a physical device for real testing.

# Local restore drill (Litestream enabled)
docker compose exec app litestream restore -if-replica-exists -o /tmp/restored.sqlite "$LITESTREAM_REPLICA_URL"
```

### Required environment variables for the backend

| Var | Required? | Purpose |
|---|---|---|
| `APNS_KEY_PATH` | yes (or `APNS_KEY_PEM`) | filesystem path to `.p8` file |
| `APNS_KEY_PEM` | alt to `APNS_KEY_PATH` | full PEM contents of `.p8` (for platforms without secret files) |
| `APNS_KEY_ID` | yes | 10-char Key ID from Apple Developer |
| `APNS_TEAM_ID` | yes | 10-char Team ID |
| `APNS_BUNDLE_ID` | yes | iOS app bundle id: `dev.sjoerd.tringtring` |
| `APNS_ENV` | yes | `sandbox` (Debug builds) or `production` (Release/TestFlight) |
| `DATABASE_URL` | yes | `sqlite:///data/db.sqlite?mode=rwc` (in container) |
| `LISTEN_ADDR` | no | default `0.0.0.0:8080` |
| `PUBLIC_BASE_URL` | yes | e.g. `https://tring-tring.sjoerd.dev` — used to build webhook URLs returned by `POST /v1/devices` |
| `RATE_LIMIT_PER_MINUTE` | no | default `10` |
| `MONTHLY_QUOTA` | no | default `100000` |
| `LITESTREAM_REPLICA_URL` | no | enable replication: `s3://bucket/path` |
| `LITESTREAM_ACCESS_KEY_ID` | only if Litestream enabled | S3 access key |
| `LITESTREAM_SECRET_ACCESS_KEY` | only if Litestream enabled | S3 secret key |
| `LITESTREAM_REPLICA_ENDPOINT` | only if Litestream enabled and not AWS S3 | S3-compatible endpoint URL |

The persistent volume must be mounted at `/data` inside the container. The image refuses to start without it.

## Pointers

- **Architecture**: see [docs/adr/INDEX.md](docs/adr/INDEX.md) for all 8 founding ADRs.
- **Operations**: see [docs/runbooks/INDEX.md](docs/runbooks/INDEX.md).
- **Code style**: see [docs/CONVENTIONS.md](docs/CONVENTIONS.md).
- **Backend specifics**: see [backend/CLAUDE.md](backend/CLAUDE.md).
- **iOS specifics**: see [ios/CLAUDE.md](ios/CLAUDE.md).

## When you (Claude) make changes

- Touched architecture? Add or supersede an ADR. No exceptions.
- Touched ops procedure? Update the relevant runbook and re-verify it.
- Added a recurring constraint that future sessions need to know about? Add it to `docs/CONVENTIONS.md`, not here.
- Don't add to this file unless the addition is genuinely top-level and concerns every session. This file should stay under ~150 lines.
