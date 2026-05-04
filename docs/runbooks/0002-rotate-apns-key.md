# Runbook 0002 — Rotate the APNs `.p8` key

**Status**: Stub. Verify on first key rotation and update.

## When to run this

- Suspected compromise of the existing `.p8` key.
- Periodic rotation (recommended: at least annually, even though Apple does not require it).
- After an operator with key access leaves the team.

## Background

Apple Developer allows multiple active APNs auth keys per team. We exploit this for zero-downtime rotation: create the new key, deploy it, then revoke the old one once we've confirmed traffic is flowing through the new one.

## Procedure

### 1. Apple Developer: create a new key

1. Sign in to https://developer.apple.com/account/resources/authkeys/list.
2. Click **+** to register a new key.
3. Name: `tring-tring-<YYYYMMDD>`.
4. Enable **Apple Push Notifications service (APNs)**.
5. Click **Continue → Register → Download**. The `.p8` file is downloadable **once**. Save it offline.
6. Note the **Key ID** (10 chars). The Team ID stays the same.

### 2. Stage the new key

⚠ **PROD**

**On Coolify**: Application → Environment Variables. Update:

- `APNS_KEY_PEM` to the contents of the new `.p8` file (full text, including BEGIN/END lines).
- `APNS_KEY_ID` to the new Key ID.

(`APNS_TEAM_ID` and `APNS_BUNDLE_ID` stay the same.)

**On `docker compose`**: copy the new `.p8` next to the existing one, edit `.env`:

```bash
scp <new-key>.p8 deploy-host:/srv/tring-tring/apns-NEW.p8
ssh deploy-host 'chmod 0600 /srv/tring-tring/apns-NEW.p8'
$EDITOR /srv/tring-tring/.env
# APNS_KEY_PATH=/run/secrets/apns-NEW.p8   # adjust mount path to match
# APNS_KEY_ID=<new-key-id>
```

Update `compose.yml` to mount the new file at the path you set in `.env`.

### 3. Roll the deployment

**Coolify**: Click **Restart**.

**docker compose**: `docker compose up -d` (Compose recreates the container with new env).

```bash
docker logs --tail 50 <container>
```

The log should show the service starting and successfully signing JWTs.

### 5. Verify with a real push

Send a test push to a known device:

```bash
curl -fsS -X POST "https://<host>/<known-secret>/notifications/rotate-test" \
  -H 'Content-Type: application/json' \
  -d '{"title":"key rotated","text":"test"}'
```

Confirm the notification arrives. If it does, the new key is working.

### 6. Apple Developer: revoke the old key

After at least 1 hour of stable traffic on the new key:

1. Back to the Keys page.
2. Click the old key → **Revoke**.

### 7. Remove the old key from the host

**Coolify**: clear the old `APNS_KEY_PEM` value from your password manager / secrets store.

**docker compose**: shred the old file.

```bash
ssh deploy-host 'shred -u /srv/tring-tring/apns-OLD.p8'
```

## Failure modes

- **`Forbidden` / `InvalidProviderToken` from APNs after restart**: Key ID mismatch. Re-check `APNS_KEY_ID` in the env file matches the new key.
- **Pushes succeed but tap-to-open URL fails**: unrelated to key rotation; check `defaultAction.url` handling on the iOS side.
- **Multiple instances of the service running**: rare in our deployment, but if both old and new are running with different keys you may briefly see `TooManyProviderTokenUpdates`. Resolve by stopping old instances.

## Verified

| Date | By | Notes |
|---|---|---|
| _pending_ | | First rotation. |
