# 0007 — APNs token (`.p8` JWT) auth, not certificate

## Status

Accepted — 2026-05-04.

## Context

APNs supports two authentication methods:

1. **Certificate-based** (`.p12`): a per-app TLS client certificate. Expires annually and must be renewed and redeployed before expiry.
2. **Token-based** (`.p8`): a single ECDSA P-256 private key issued in Apple Developer. The app server signs short-lived JWTs (ES256) and presents them as bearer tokens. Keys do not expire. One key serves all apps in the developer's team.

Token-based auth has fewer operational hazards (no expiry-induced outages), simpler dev/prod handling (one key for both environments), and is the path Apple itself promotes.

There is a subtle constraint: APNs returns `TooManyProviderTokenUpdates` if a provider rotates the JWT more than once per ~20 minutes per server. In practice, signing a new JWT every 30–60 minutes and reusing it across all requests is the recommended pattern.

## Decision

- **Auth method**: token-based (`.p8`).
- **Configuration**: `APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`.
- **JWT cadence**: cache the signed JWT in process memory; refresh between **20 and 60 minutes** (target: every 45 minutes). Never sign a new JWT per request.
- **Connection**: one persistent HTTP/2 connection to `api.push.apple.com` (production) or `api.sandbox.push.apple.com` (sandbox), reusing streams. The `a2` crate handles this correctly and exposes a `Client` that should be constructed once at startup.
- **Environment selection**: the device's `apns_env` column (`sandbox` or `production`) determines which APNs host to send to. The iOS app reports its environment based on build configuration (Debug → sandbox, Release/TestFlight → production) and re-registers on launch.

## Consequences

- **+** No annual certificate renewal. The `.p8` key is good for the lifetime of the developer account unless explicitly revoked.
- **+** Single key, single config path, dev and prod.
- **+** Simpler key rotation: see runbook 0002. We can keep two active keys overlapping during rotation.
- **−** A leaked `.p8` is a serious incident — it can send pushes to any app under the team. Mitigations: read-only file permissions for the service user; never commit; rotate immediately on suspected compromise.
- **−** The `Topic` header (i.e., the iOS app bundle ID) must match the registered app exactly. Misconfiguring `APNS_BUNDLE_ID` results in `BadTopic` errors that look generic.

## Operational rules

1. **Never sign a JWT per request.** Always cache and reuse.
2. **Never call `a2::Client::new()` per request.** Construct one client at startup and clone the handle for handlers.
3. **Never commit the `.p8`.** It's in `.gitignore`; CI/CD must source it from a secret manager or a secured file on the VPS.
4. **Rotate on suspicion.** If you think the key may have leaked, rotate immediately following runbook 0002 — Apple Developer lets you have multiple active keys to support a zero-downtime rotation.

## References

- [Establishing a token-based connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)
