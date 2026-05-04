# 0018 — Saved notification templates

## Status

Accepted — 2026-05-05. Extends [ADR-0004](0004-pushcut-compat.md).

## Context

Pushcut's mental model is that the `name` in a webhook URL refers to a notification *configured in the iOS app* — given a sound, a default title, default actions, etc. The webhook then *overrides* a subset of those at fire time. [ADR-0011](0011-notification-name-validation.md) explicitly punted on this: in our v1, the `name` is just a free-form label with no associated config.

Now that [ADR-0013](0013-rich-content-payloads.md), [ADR-0016](0016-interactive-actions.md), and [ADR-0017](0017-run-on-server-actions.md) define a meaningful set of payload knobs, the "configure in the app, override per-fire" pattern becomes useful:

- A user defines a template `door-bell` with `sound: "lasers"`, `actions: [{name: "Open door", url: "https://...", runOnServer: true, ...}]`, and `defaultAction.url`.
- A simple GET webhook against `…/notifications/door-bell` with no body now produces a fully-configured notification.
- A more elaborate POST against the same URL can override `text` or add an `image`, while inheriting everything else.

This is the v1 of the iOS-app's notification configuration UI, and it is also the migration path for Pushcut users whose mental model already matches this shape.

The merge semantics matter. Pushcut's docs are vague on what happens when a webhook collides with a configured notification — we pick a deliberate rule and stick with it.

## Decision

### Storage

```sql
CREATE TABLE notification_templates (
  user_id         TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name            TEXT NOT NULL,
  default_payload TEXT NOT NULL,        -- JSON, same shape as a webhook body
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  PRIMARY KEY (user_id, name)
);
```

- `name` follows [ADR-0011](0011-notification-name-validation.md)'s regex (`[A-Za-z0-9._-]{1,64}`). The same regex enforced everywhere a name appears.
- `default_payload` is a JSON object: any subset of the supported webhook fields. Validation is identical to a webhook body — same field types, same size caps, same URL HTTPS rules. A template that contains an invalid field is rejected at PUT time.
- `(user_id, name)` is the primary key; PUT replaces an existing row.

### Webhook lookup

When a webhook arrives at `/{userId}/notifications/{name}`:

1. Look up `notification_templates` for `(user_id, name)`.
2. If a row exists, **merge** the template's `default_payload` with the request payload using these rules:
   - **Top-level field, present in request**: request wins. (`text`, `title`, `sound`, `image`, `imageData`, `delay`, `scheduleTimestamp`, `id`/`identifier`, `threadId`, `isTimeSensitive`, `defaultAction`, `actions`, `devices`.)
   - **Top-level field, absent in request, present in template**: template's value used.
   - **Top-level field, absent in both**: absent in result (default behavior).
3. **No deep merge.** Specifically:
   - `actions`: template's array is fully replaced by the request's array if the request supplies one (even an empty array). Mixing template-supplied and request-supplied actions in the same fire is **not** supported.
   - `defaultAction`: same rule — replaced as a whole, not field-by-field. Setting `defaultAction: {}` in the request *clears* the template's default action (rather than reverting to template).
   - `defaultAction.urlBackgroundOptions.httpHeader[]`: subsumed by the no-deep-merge rule on `defaultAction`.
   - `devices[]`: replaced as a whole. An empty array means "all devices" per [ADR-0013](0013-rich-content-payloads.md), regardless of the template's `devices` value.

3. The merged payload runs through the same validation as a direct webhook (size caps, regex checks, etc.). A merge result that fails validation returns the same **HTTP 4xx** the direct webhook would have, but blames the merge: `{"error":"merged payload exceeds 4KB envelope","template":"door-bell"}`.

If no template exists for the `(user_id, name)` pair, the webhook proceeds with the request payload as-is. Templates are opt-in per name.

### REST API

All under the `/v1/users/{userId}/...` namespace, all auth via `Authorization: Bearer <userId>` header (per [ADR-0019](0019-rest-auth-and-listing.md)).

- **`GET /v1/users/{userId}/templates`** — list templates for the user. Response: `{"templates":[{"name":"...","updated_at":<unix>},...]}`. Names only by default; payloads are returned by the per-name endpoint to keep the list cheap.
- **`GET /v1/users/{userId}/templates/{name}`** — fetch one template's full payload. **404** if not found.
- **`PUT /v1/users/{userId}/templates/{name}`** — create or replace. Body: the full `default_payload` JSON. **200** on success with `{"name":"...","updated_at":<unix>}`. Validation failures return the same **400** the webhook would, with the message phrased as "invalid template field".
- **`DELETE /v1/users/{userId}/templates/{name}`** — remove. **200** with `{"deleted":true}` if the row existed; **200** with `{"deleted":false}` if it didn't (idempotent).

### iOS UI

The iOS app gets a list / create / edit / delete UI for templates. Editing is a structured form (toggles, sound picker, action editor) that produces the JSON body for `PUT`. Free-form JSON editing is a "show advanced" affordance for power users.

### Recursion

Templates **cannot reference other templates**. The merge happens once, at webhook time, against a single `default_payload`. There is no `extends: "other-template"` field. This is deliberate — it makes loop-detection unnecessary and keeps the merge order trivial.

## Consequences

- **+** Closes the loop on Pushcut's mental model. Migrants whose Pushcut config is "named notifications, lightly overridden" get a direct port.
- **+** A user can move complex configuration (long action arrays, large `defaultAction.urlBackgroundOptions.httpBody`) out of the URL caller's responsibility and into a server-side template. The webhook caller stays simple.
- **+** Per-user, no global namespace collisions. Two users can both have a template called `door-bell`.
- **+** No template loop guards needed (templates can't recurse), so the merge has predictable performance: O(1) lookup, O(n) shallow merge over a fixed set of top-level keys.
- **−** "No deep merge" surprises some users who expect `actions[]` overrides to merge by `name`. We take the simpler rule and document it. The motivating case ("override one action's URL while keeping the others from the template") becomes "duplicate the array in the request payload" — explicit and unambiguous, even if more verbose.
- **−** Templates can hold large `defaultAction` payloads that would push a per-fire merge over the 4 KB APNs envelope when combined with a request `image`. Validation catches it at fire time, not at template PUT time. Documented.
- **−** Template storage is unbounded per user (we don't cap template count). At 1 KB each that's negligible, but a future quota may want to cap it. Out of scope for v1.
- **−** Because templates are looked up per webhook, a user who deletes a template mid-flight changes the behavior of in-flight scheduled webhooks ([ADR-0015](0015-scheduled-and-delayed-notifications.md)). [ADR-0015](0015-scheduled-and-delayed-notifications.md) stores the *full request payload* at schedule time, but the merge happens at *dispatch* time — see "Operational rules" below.

## Operational rules

1. **Merge happens at dispatch time, not at schedule time.** A scheduled notification ([ADR-0015](0015-scheduled-and-delayed-notifications.md)) stores the original request body verbatim. When the scheduler picks it up, it re-runs the template lookup. Editing a template before its scheduled fire **does** affect the dispatch — this is intentional ("the user changed their mind about the door-bell sound, the queued 6 PM ring uses the new sound"). If we ever want frozen-at-schedule semantics, that's a new ADR.
2. **No deep merge means no surprises.** The merge function is ~30 lines of code over a fixed key set. New top-level fields added to the webhook contract are explicitly added to the merge function — there is no `serde_json::Value::merge` general-purpose call.
3. **Template validation is identical to webhook validation.** PUT runs the same validation pass. We do not allow "templates that would never validate as a webhook"; that would create a class of bugs where the template is fine in isolation but breaks every webhook that uses it.
4. **Names follow [ADR-0011](0011-notification-name-validation.md)'s regex.** Same regex constant, three call sites now (URL parser, identifier validator [ADR-0014](0014-notification-identifiers-and-cancel.md), template name validator).

## References

- [Pushcut Notifications docs — pre-configured notifications](https://www.pushcut.io/support/notifications)
- [ADR-0004](0004-pushcut-compat.md) — Pushcut-compatible webhook format. This ADR extends it.
- [ADR-0011](0011-notification-name-validation.md) — name regex, reused for template names.
- [ADR-0013](0013-rich-content-payloads.md) — `image`, `imageData`, `defaultAction`, `devices` fields the template can carry.
- [ADR-0015](0015-scheduled-and-delayed-notifications.md) — scheduling interaction with template edits.
- [ADR-0016](0016-interactive-actions.md) — `actions[]` field the template can carry.
- [ADR-0017](0017-run-on-server-actions.md) — `runOnServer` action config a template can carry.
- [ADR-0019](0019-rest-auth-and-listing.md) — REST auth and rate-limit posture for the template endpoints.
