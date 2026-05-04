# 0004 — Pushcut-compatible webhook format

## Status

Accepted — 2026-05-04.

## Context

Existing alternatives (Pushcut, brrr) charge for what is essentially a thin wrapper over APNs. Many users have years of automations (Zapier, n8n, Home Assistant, Shortcuts, GitHub Actions, IoT devices, custom scripts) that POST to Pushcut webhooks. Forcing a different URL shape or payload schema imposes migration cost and reduces the appeal of switching.

Pushcut's webhook contract is well-known and stable enough to copy:

- **URL**: `POST | GET https://api.pushcut.io/{secret}/notifications/{notificationName}`
- **Auth**: the `{secret}` segment in the path (account-wide).
- **Payload (JSON, all optional, unknown keys ignored)**: `title`, `text`, `input`, `image`, `imageData`, `sound`, `devices`, `defaultAction`, `actions`, `threadId`, `isTimeSensitive`, `delay`, `scheduleTimestamp`, `id`/`identifier`.
- **Response**: 200 with empty body on success.

Notable detail: Pushcut uses `text` for the notification body, **not** `body` or `message`. This is the most common foot-gun when wiring something up.

## Decision

The public webhook endpoint is **Pushcut-shape-compatible**:

- URL: `POST | GET /{secret}/notifications/{name}` on the operator's domain.
- The `{secret}` is the per-device webhook secret (different from Pushcut's account-wide secret — see ADR-0005).
- v1 supports these payload fields (others are silently ignored, matching Pushcut's behavior):
  - `title` (string)
  - `text` (string) — body. **Not `body`. Not `message`.**
  - `sound` (string) — Pushcut's named sounds, mapped on the backend.
  - `threadId` (string)
  - `isTimeSensitive` (bool)
  - `defaultAction.url` (string) — the URL to open when the notification is tapped.
  - `input` (string) — passed through to the iOS app as a custom payload field.
- Responses: 200 empty on success; 400 for malformed JSON; 404 for an unknown secret; 429 for rate-limit/quota exceeded.

## Consequences

- **+** Existing Pushcut users migrate by a single search-and-replace on their automation URLs.
- **+** Tooling that already speaks Pushcut (community wrappers, Home Assistant integrations, Shortcuts templates) works against this service.
- **−** We're committed to Pushcut's field names and quirks (especially `text` vs `body`). Changing them breaks compatibility and requires a new ADR.
- **−** Some Pushcut features deliberately deferred: `image`/`imageData` (require a Notification Service Extension on iOS), `actions[]` (interactive notifications), `delay`/`scheduleTimestamp` (require a job queue), `devices[]` (no multi-device-per-account in v1; see ADR-0005). Unknown fields are ignored, not rejected, so payloads that include these features still succeed for the supported subset.

## References

- [Pushcut Notifications docs](https://www.pushcut.io/support/notifications)
- [Pushcut Integrations docs](https://www.pushcut.io/support/integrations)
