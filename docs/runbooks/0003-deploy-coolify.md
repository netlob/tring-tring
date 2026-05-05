# Runbook 0003 — Deploy via Coolify (or any Docker host)

**Status**: Stub. Verify during build step 9. Replace placeholder commands with actual ones used during the first successful deploy.

Per [ADR-0009](../adr/0009-containerized-deployment.md), the deployment unit is a Docker image with a persistent volume mounted at `/data`. This runbook documents the Coolify path (the operator's choice) and gives a portable `docker compose` fallback.

## When to run this

- First-time deployment of tring-tring to production.
- Deploying a new instance (staging, replica region, friend's box).

## Prerequisites

- A host running Coolify (typical: Hetzner CAX11 with Coolify installed) **or** any Linux host with Docker + Docker Compose v2.
- A domain (e.g., `tring-tring.sjoerd.dev`) with DNS pointing at the host.
- The APNs `.p8` key and metadata (Key ID, Team ID, Bundle ID).
- A multi-arch image published to `ghcr.io/netlob/tring-tring:<tag>` (CI does this on every push to `main`).
- Optional but recommended for production: an S3-compatible object storage bucket and credentials for Litestream (Hetzner Object Storage, Backblaze B2, AWS S3, etc.).

## Path A: Coolify

### 1. Create a new Application

- Coolify → **+ New → Application**.
- Source: **Public Image**.
- Image: `ghcr.io/netlob/tring-tring:latest` (or pin a tag).
- Network: HTTP, container port `8080`.
- Domain: `tring-tring.sjoerd.dev` (Coolify will auto-issue Let's Encrypt).

### 2. Mount a persistent volume

- Storage tab → **+ Volume**.
- Source: named volume (Coolify-managed).
- Destination: `/data`.

### 3. Set environment variables

In the Environment Variables tab, set the values from `[CLAUDE.md](../../CLAUDE.md#required-environment-variables-for-the-backend)`. Mark the secrets (`APNS_KEY_PEM`, `LITESTREAM_SECRET_ACCESS_KEY`) as protected.

For the APNs key on Coolify, set `APNS_KEY_PEM` to the **full text** of the `.p8` file (including `-----BEGIN PRIVATE KEY-----` lines). Leave `APNS_KEY_PATH` unset — the entrypoint prefers `APNS_KEY_PEM` when present.

### 4. Deploy

Click **Deploy**. Watch logs:

```
[entrypoint] /data writable: ok
[entrypoint] litestream: <enabled|disabled>
[tring-tring] migrations applied (0001_init)
[tring-tring] APNs client ready (env=production, bundle=dev.sjoerd.tringtring)
[tring-tring] listening on 0.0.0.0:8080
```

### 5. Smoke test

```bash
curl -fsS https://tring-tring.sjoerd.dev/healthz
# expect: {"status":"ok","replication":"<enabled|disabled>",...}
```

Then run the iOS app, register a device, and send a test notification (see `docs/CONVENTIONS.md` testing section).

### 6. Schedule the restore drill

If Litestream is enabled, run runbook 0001 against this deployment within the first week to verify backups actually restore.

## Path B: docker compose (any Linux host)

Useful for testing, friend hosting your tring-tring, or non-Coolify deployments.

### 1. Set up the host

```bash
# As root or via sudo
apt update && apt install -y docker.io docker-compose-plugin
systemctl enable --now docker
```

### 2. Place files

```
~/tring-tring/
├── compose.yml
├── .env             # secrets — chmod 0600
└── apns.p8          # the APNs key — chmod 0600
```

### 3. `compose.yml`

```yaml
services:
  app:
    image: ghcr.io/netlob/tring-tring:latest
    restart: unless-stopped
    ports:
      - "80:8080"
    volumes:
      - tring-data:/data
      - ./apns.p8:/run/secrets/apns.p8:ro
    env_file: .env
    environment:
      APNS_KEY_PATH: /run/secrets/apns.p8

volumes:
  tring-data:
```

### 4. `.env`

```
APNS_KEY_ID=<10-char>
APNS_TEAM_ID=<10-char>
APNS_BUNDLE_ID=dev.sjoerd.tringtring
APNS_ENV=production
DATABASE_URL=sqlite:///data/db.sqlite?mode=rwc
PUBLIC_BASE_URL=https://tring-tring.sjoerd.dev
RATE_LIMIT_PER_MINUTE=10
MONTHLY_QUOTA=100000

# Optional Litestream replication
LITESTREAM_REPLICA_URL=s3://my-bucket/tring-tring
LITESTREAM_ACCESS_KEY_ID=...
LITESTREAM_SECRET_ACCESS_KEY=...
LITESTREAM_REPLICA_ENDPOINT=https://<region>.your-objectstorage.com
```

### 5. Reverse proxy + TLS

Put Caddy, Traefik, nginx + certbot, or Cloudflare Tunnel in front of `127.0.0.1:8080`. Out of scope for this runbook; pick whatever you already use.

### 6. Start it

```bash
docker compose up -d
docker compose logs -f
curl -fsS http://127.0.0.1:8080/healthz
```

## Failure modes

- `**/data not writable, refusing to start**`: the volume isn't mounted, or it's mounted with the wrong permissions. On Coolify: confirm a volume is attached at `/data`. On `docker compose`: confirm the volume name in the `volumes:` block matches and the named volume isn't shadowed by a stale container.
- `**APNS_BUNDLE_ID` mismatch errors at first push**: bundle id in the app server doesn't match the iOS app's actual bundle id. They must be identical.
- **Litestream errors but app keeps running**: per ADR-0010 this is by design. Check `journalctl` / `docker logs` for the specific S3 error (typically endpoint or bucket misconfig).

## Verified


| Date      | By  | Notes                                  |
| --------- | --- | -------------------------------------- |
| *pending* |     | First production deploy: build step 9. |


