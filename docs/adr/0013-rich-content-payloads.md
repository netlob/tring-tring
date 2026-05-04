# 0013 — Rich content payloads (images, sounds, devices filter, defaultAction)

## Status

Accepted — 2026-05-05. Extends [ADR-0004](0004-pushcut-compat.md).

## Context

[ADR-0004](0004-pushcut-compat.md) committed to a Pushcut-compatible webhook contract but explicitly deferred the rich-content fields (`image`, `imageData`, custom `sound` names, `devices[]`, full `defaultAction`) on the grounds that they require an iOS Notification Service Extension, an in-bundle sound asset story, multi-device routing, and a richer payload contract.

Those prerequisites are now in place:

- Sign in with Apple ([ADR-0012](0012-sign-in-with-apple.md)) gives us per-user fan-out and named devices, which makes a `devices[]` filter meaningful.
- The iOS app is signed and entitled, so a Notification Service Extension (NSE) target can be added as a sibling binary.
- APNs's hard payload size limit is 4 KB. Anything that exceeds it is rejected by APNs with `PayloadTooLarge` — we have to enforce the cap *before* we hand the payload off, otherwise we burn an APNs round-trip per oversized request.

Pushcut's documented rich-content surface that we want to honor:

- `image`: HTTPS URL. The iOS NSE downloads it at delivery time and attaches it via `UNNotificationAttachment`.
- `imageData`: base64-encoded image inlined in the payload. Useful for offline-only content and end-to-end private images, but cannot exceed APNs's 4 KB envelope.
- `sound`: a named sound from a fixed set (`vibrateOnly`, `system`, `subtle`, `question`, `jobDone`, `problem`, `loud`, `lasers`). Pushcut bundles `.caf` files in their app for these names.
- `devices`: array of device-name strings. When present, the push is delivered only to devices whose name matches.
- `defaultAction`: the action invoked when the notification is tapped. Pushcut's full shape is `{ url, urlBackgroundOptions: { httpMethod, httpContentType, httpHeader: [{key, value}], httpBody } }`.

## Decision

### Image attachments

- **`image` (string, HTTPS URL)**: backend validates the scheme is `https://` and forwards the URL to APNs as a custom payload field (`tt.image_url`). The iOS NSE downloads the URL on delivery and attaches it via `UNNotificationAttachment`. The backend does not pre-fetch or proxy the image — that would defeat the point of letting the NSE do it on-device.
- **`imageData` (string, base64)**: backend decodes-and-re-encodes once to validate, then forwards as a custom payload field (`tt.image_b64`). Hard cap: **3 KB** of base64-encoded text (≈ 2.25 KB of binary), to leave headroom inside the 4 KB APNs envelope for the rest of the payload (alert, sound, category, action data, custom user info). Anything larger is rejected with **HTTP 413 Payload Too Large** and body `{"error":"imageData exceeds 3KB"}`.
- The backend always sets `mutable-content: 1` on the APNs payload when `image` or `imageData` is present, so the NSE is invoked.
- The NSE is shipped as a separate signed binary inside the iOS app bundle. Tokens, signing, and entitlements are managed at the Apple Developer side; nothing about the NSE crosses our trust boundary.

### Custom sounds

- The backend accepts the eight Pushcut sound names (`vibrateOnly`, `system`, `subtle`, `question`, `jobDone`, `problem`, `loud`, `lasers`) **untranslated**: it forwards the literal name in the APNs payload's `sound` field.
- iOS resolves the name to `<name>.caf` from the app bundle. Unknown sound names fall back to `default` (the system default sound) on the iOS side.
- `vibrateOnly` is a special case: the backend maps it to APNs `sound: null` (silent push that still vibrates per the user's device settings).
- **v1 of this ADR does not bundle the actual `.caf` files** in the repo — sourcing royalty-clean equivalents is out of scope for the architectural change. The wiring works the day a contributor drops `.caf` files matching the eight names into the app bundle. Until then, all eight names fall back to `default` on-device.

### Devices filter

- Webhook payload `devices: string[]`. When present and non-empty, fan-out targets only devices whose `device_name` (set by the iOS client at registration time) matches a string in the list.
- Empty array (`"devices": []`) or absent key → all devices, identical to today's fan-out from [ADR-0012](0012-sign-in-with-apple.md).
- Match is **case-insensitive, whitespace-trimmed** on both sides. Unicode normalization is NFC.
- A `devices` filter that matches zero devices for the user returns **410 Gone** with `{"error":"no devices matched filter"}`. Quota is not consumed (consistent with [ADR-0012](0012-sign-in-with-apple.md)'s "no live targets" semantic).

### `defaultAction`

The backend accepts the full Pushcut shape:

```json
{
  "defaultAction": {
    "url": "https://example.com",
    "urlBackgroundOptions": {
      "httpMethod": "POST",
      "httpContentType": "application/json",
      "httpHeader": [{"key": "X-Foo", "value": "bar"}],
      "httpBody": "..."
    }
  }
}
```

In v1 of this ADR:

- **`defaultAction.url`** drives tap-to-open: forwarded to iOS as a custom payload field (`tt.default_url`). The iOS handler calls `UIApplication.shared.open()` on tap.
- **`defaultAction.urlBackgroundOptions`** is parsed, validated against the same shape, and stored verbatim in the iOS-bound user info (`tt.default_action`). It is **not executed** in this ADR — it is consumed by the run-on-server path in [ADR-0017](0017-run-on-server-actions.md). Storing it now means we don't have to re-version the webhook contract when run-on-server lands.

## Consequences

- **+** Pushcut migrants who use images, sounds, device filters, or default actions get parity for the read-only / tap-to-open subset on day one.
- **+** The 4 KB envelope is enforced at the edge (HTTP 413 instead of an opaque APNs failure), so misconfigured callers see a useful error.
- **+** Per-user device naming from [ADR-0012](0012-sign-in-with-apple.md) becomes load-bearing — the `devices` filter is the first feature to use `devices.device_name` for routing.
- **+** Storing `urlBackgroundOptions` now (without executing) gives [ADR-0017](0017-run-on-server-actions.md) a clean place to plug in.
- **−** The 3 KB `imageData` cap is more restrictive than Pushcut documents. Pushcut also has a 4 KB envelope but does not publish a per-field cap; we make ours explicit. Migrants who rely on inlined images near 3 KB may need to switch to `image` URLs.
- **−** No `.caf` sound files ship with v1. Users get `default` for all named sounds until someone contributes royalty-clean assets. Acceptable: the architectural wiring is what this ADR commits to.
- **−** The NSE adds a second signed binary that has to be kept in lockstep with the main app on every release. We accept this as the cost of any image-attachment story on iOS.

## Operational rules

1. **Image URLs must be `https://`.** The backend rejects `http://` and any non-`https` scheme with **HTTP 400** and `{"error":"image must be HTTPS"}`. The NSE will not fetch over plaintext.
2. **The 4 KB APNs envelope is the hard limit.** The backend computes the final serialized APNs payload size and rejects with **HTTP 413** if it exceeds 4096 bytes, even for combinations that individually pass. This catches the "small `imageData` + huge `defaultAction.urlBackgroundOptions.httpBody`" case.
3. **Unknown sound names fall back to `default`** on iOS, never on the backend. The backend forwards what the caller sent so we keep a single source of truth for the allowed sound set (the iOS bundle).
4. **`devices` filter matching is centralized** in the fan-out path — there is exactly one place that does the case-insensitive, NFC-normalized, trimmed comparison. New routing predicates extend that function rather than re-implement it.

## References

- [APNs documentation — Generating a remote notification payload](https://developer.apple.com/documentation/usernotifications/generating-a-remote-notification)
- [`UNNotificationServiceExtension`](https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension)
- [`UNNotificationAttachment`](https://developer.apple.com/documentation/usernotifications/unnotificationattachment)
- [Pushcut Notifications docs](https://www.pushcut.io/support/notifications) — source contract for `image`, `imageData`, `sound`, `devices`, `defaultAction`.
- [ADR-0004](0004-pushcut-compat.md) — Pushcut-compatible webhook format. This ADR extends it.
- [ADR-0012](0012-sign-in-with-apple.md) — per-user fan-out and `device_name` storage.
- [ADR-0017](0017-run-on-server-actions.md) — consumer of the stored `urlBackgroundOptions`.
