# tring tring

Self-hosted iOS push notifications. Webhook in → push out. Drop-in compatible with [Pushcut](https://www.pushcut.io/)'s webhook format so existing automations migrate by changing only the URL.

- **iOS app**: native SwiftUI. Register on first launch, get your personal webhook URL.
- **Backend**: Rust (axum + SQLite + Litestream), deploys to a ~€3.29/mo Hetzner VPS.
- **Free tier**: 10 notifications/min per device, generous monthly quota — funded by the operator's coffee budget, not yours.

## Project status

🚧 Pre-v1. Architecture frozen ([docs/adr](docs/adr/INDEX.md)), implementation in progress.

## Repo layout

```
backend/   Rust service
ios/       SwiftUI app (Xcode project)
docs/      Architecture decisions and operational runbooks
```

## For developers and AI agents

Start with [`CLAUDE.md`](CLAUDE.md). It is the canonical entry point and the contract for how this repo evolves.

## Deploy

The backend ships as a multi-arch Docker image (`linux/amd64` + `linux/arm64`) published to GitHub Container Registry on every push to `main` and on every `v*` tag. See [docs/runbooks/0003-deploy-coolify.md](docs/runbooks/0003-deploy-coolify.md) for the full deploy guide (Coolify path + portable `docker compose` fallback) and [ADR-0009](docs/adr/0009-containerized-deployment.md) for the deployment contract.

Quick start (any Docker host with a persistent volume mounted at `/data`):

```bash
docker run -d --name tring-tring \
  -p 8080:8080 \
  -v tring-data:/data \
  --env-file .env \
  ghcr.io/netlob/tring-tring:latest
```

## License

TBD.
