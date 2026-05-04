# 0016 — Interactive notification actions

## Status

Accepted — 2026-05-05. Extends [ADR-0004](0004-pushcut-compat.md).

## Context

Pushcut's webhook contract supports an `actions: ActionObject[]` field — buttons that appear under the notification on iOS. Each action can open a URL, run a server-side request, run a Shortcut, or trigger a HomeKit scene. [ADR-0004](0004-pushcut-compat.md) deferred these because they require iOS-side category registration and a richer payload contract.

iOS's interactive notifications mechanism (`UNNotificationCategory` / `UNNotificationAction`) imposes a constraint that shapes the design: **categories must be registered at app startup**, before any notification arrives. The category id in the APNs payload tells iOS which pre-registered set of action *slots* to render. The labels on those slots can be overridden per-notification via user info, but the *number and identifiers* of slots are fixed at registration time.

A reasonable Pushcut-shape compromise:

- Cap actions at **3** per push. iOS's UI gets cluttered beyond that, and 3 keeps us under APNs's 4 KB envelope when combined with images and a body. Pushcut documents up to 4; we trade one slot for headroom.
- Pre-register three generic categories: `tt-1`, `tt-2`, `tt-3` (one for each possible action count). The backend picks the right category based on `actions.len()`.
- Carry the actual action data (name, url, options) in the user info under `tt.actions`. The iOS handler reads it on tap and acts accordingly.

This ADR scopes only the simple cases: open-URL actions, with the `keepNotification` flag controlling foreground vs destructive activation. `runOnServer` is delegated to [ADR-0017](0017-run-on-server-actions.md). `shortcut` and `homekit` are out of scope.

## Decision

### Webhook contract

- `actions: ActionObject[]`, **maximum 3** entries. Anything longer → **HTTP 400** `{"error":"max 3 actions per notification"}`.
- Each `ActionObject`:
  ```json
  {
    "name": "string (required)",
    "url": "string (optional)",
    "input": "string (optional)",
    "keepNotification": false,
    "runOnServer": false,
    "online": false,
    "urlBackgroundOptions": { /* same shape as defaultAction.urlBackgroundOptions */ },
    "shortcut": "string (optional, ignored in v1)",
    "homekit": { /* object, ignored in v1 */ }
  }
  ```
- `name` is required and must match `^[A-Za-z0-9._\- ]{1,32}$` (looser than [ADR-0011](0011-notification-name-validation.md) — spaces are allowed because this is a user-visible button label, not a URL segment).
- Duplicate `name` within an actions array → **HTTP 400** `{"error":"duplicate action name"}`. Each name must be unique within a single notification (it's the lookup key in user info on tap).

### Category registration on iOS

- The iOS app registers exactly three categories at startup:
  - `tt-1` with one action slot (`tt-action-0`).
  - `tt-2` with two action slots (`tt-action-0`, `tt-action-1`).
  - `tt-3` with three action slots (`tt-action-0`, `tt-action-1`, `tt-action-2`).
- The slot titles registered at startup are placeholder strings (`"Action 1"`, `"Action 2"`, `"Action 3"`); iOS displays these only if the per-notification override fails. Per-notification overrides come from `userInfo["tt"]["actions"][i]["name"]`, applied via the [`UNNotificationCategory.intentIdentifiers` + dynamic title APIs documented by Apple](https://developer.apple.com/documentation/usernotifications/declaring_your_actionable_notification_types).

### Backend payload assembly

- For a webhook with `actions.len() == N` (where `1 <= N <= 3`), the backend sets the APNs `category` field to `tt-N`.
- The backend sets `userInfo["tt"]["actions"]` to the literal `actions` array from the webhook (validated, with `shortcut`/`homekit` stripped — see below).
- Activation modes are derived per-action and stored alongside in `tt.actions[i].activationMode`:
  - `keepNotification == true` → `"foreground"` (notification stays visible).
  - `keepNotification == false || absent` → `"default"` (notification dismisses on tap).
- Any `runOnServer` flag is preserved verbatim in user info. iOS's behavior on tap depends on the flag — see "Action handling on iOS" below and [ADR-0017](0017-run-on-server-actions.md).

### Action handling on iOS

The iOS notification handler, on tap of action slot `i`, looks up `userInfo["tt"]["actions"][i]` and dispatches:

- `runOnServer == true` AND `urlBackgroundOptions` set → POST to backend's run-on-server endpoint (see [ADR-0017](0017-run-on-server-actions.md)). **Out of scope for this ADR.**
- `url` set, `runOnServer != true` → `UIApplication.shared.open(url)`. The notification is dismissed unless `keepNotification == true`.
- `shortcut` set → **logged and ignored** in v1. Out of scope.
- `homekit` set → **logged and ignored** in v1. Out of scope.
- Nothing actionable → **logged**, notification is dismissed per the activation mode. Should not happen if backend validation is correct (the backend rejects an action that has neither a `url` nor `runOnServer+urlBackgroundOptions`).

### Validation

- An action with neither `url` nor `runOnServer == true` (with `urlBackgroundOptions`) is malformed → **HTTP 400** `{"error":"action must have url or runOnServer"}`.
- An action with `url` set must have `https://` scheme. `http://` and other schemes → **HTTP 400** `{"error":"action url must be HTTPS"}`. (Same posture as the image URL check in [ADR-0013](0013-rich-content-payloads.md).)
- The total APNs payload size after serialization stays under 4 KB. Same edge-enforced check as [ADR-0013](0013-rich-content-payloads.md).
- Unknown fields inside `ActionObject` are silently dropped (Pushcut-compatible).

## Consequences

- **+** Pushcut migrants who use simple URL-action notifications get parity. The most common automation pattern ("open this link / acknowledge this alert with a button") works on day one.
- **+** Pre-registering three generic categories means we never need to mutate `UNUserNotificationCenter.setNotificationCategories` at runtime. The set is fixed at app launch.
- **+** Per-notification labels override the placeholders, so users see meaningful button text without dynamic category registration.
- **+** The 3-action cap leaves headroom in the 4 KB envelope and keeps the iOS UI readable.
- **−** 3 actions instead of Pushcut's 4. Migrants with 4-button notifications see a 400 and have to drop one. Documented.
- **−** `shortcut` and `homekit` are accepted-and-ignored in v1, which is a footgun: a user who sets `shortcut` and expects it to work gets silent no-action. We log a one-line "ignored shortcut field" warning to make this debuggable but do not reject.
- **−** Action category storage is bound to *count*, not to *behavior*. If we later need different category-level traits (e.g. one with `customDismissAction = true`), we add new categories and the backend's category-id mapping gets richer. Acceptable for v1.
- **−** Action `name` regex (`[A-Za-z0-9._\- ]{1,32}`) diverges from the more restrictive notification-name regex of [ADR-0011](0011-notification-name-validation.md). Two regexes are now in play; documented as a deliberate split because action names are user-visible labels, not URL segments.

## Operational rules

1. **Categories are registered at app startup, exactly once.** Re-registration on every notification arrival defeats the contract. The iOS app's `application(_:didFinishLaunchingWithOptions:)` calls `setNotificationCategories` with all three category objects.
2. **Backend never invents category ids.** The category id is `tt-<actions.len()>`, deterministic from the request. Adding a new category requires both an iOS-app change and a new ADR (the count→category mapping is part of the public contract).
3. **`runOnServer` and `keepNotification` are independent.** A notification that runs on server can keep the notification (`keepNotification: true, runOnServer: true`) or dismiss it (`keepNotification: false, runOnServer: true`). The backend stores both flags in user info.
4. **Action data is per-fire, not stored on the server.** Once the APNs push has been sent, the backend forgets the action config — except where [ADR-0017](0017-run-on-server-actions.md) explicitly persists it for the run-on-server callback path.

## References

- [`UNNotificationCategory`](https://developer.apple.com/documentation/usernotifications/unnotificationcategory) and [`UNNotificationAction`](https://developer.apple.com/documentation/usernotifications/unnotificationaction)
- [Declaring your actionable notification types](https://developer.apple.com/documentation/usernotifications/declaring_your_actionable_notification_types)
- [Pushcut Notifications docs — `actions[]`](https://www.pushcut.io/support/notifications)
- [ADR-0004](0004-pushcut-compat.md) — Pushcut-compatible webhook format. This ADR extends it.
- [ADR-0011](0011-notification-name-validation.md) — name regex (notification names; this ADR uses a different regex for action names).
- [ADR-0013](0013-rich-content-payloads.md) — payload-size and HTTPS-URL guardrails reused here.
- [ADR-0017](0017-run-on-server-actions.md) — run-on-server execution; consumes `runOnServer`/`urlBackgroundOptions` from this ADR.
