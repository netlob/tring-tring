# 0001 — Use APNs directly, not FCM

## Status

Accepted — 2026-05-04.

## Context

The service delivers push notifications to a custom iOS app. Two viable transports exist:

1. **APNs (Apple Push Notification service)** — Apple's native transport. Free. HTTP/2 with token-based JWT auth (`.p8` key) or certificate auth.
2. **FCM (Firebase Cloud Messaging)** — Google's cross-platform abstraction. For iOS delivery, FCM forwards through APNs internally.

For an iOS-only target, FCM offers cross-platform reach (Android, web) at the cost of an additional network hop and a third-party dependency.

Measured median latency (Knock benchmark, 2025): APNs ~59ms, FCM-to-iOS ~79ms. FCM also imposes its own quotas in addition to APNs's, and adds a Google account dependency that complicates self-hosting.

## Decision

**Send directly to APNs.** Do not route iOS notifications through FCM.

## Consequences

- **+** Lowest possible latency: ~20ms saved vs FCM proxy hop.
- **+** No third-party dependencies in the critical path. The service depends only on Apple infrastructure (which the iOS app already requires).
- **+** Cleaner error semantics: APNs's `Unregistered` / `BadDeviceToken` reasons drive token cleanup directly without translation.
- **+** No Google/Firebase account, project, or service-account JSON to manage on the VPS.
- **−** Adding Android later means introducing a separate transport (FCM or HMS) and a decision point about whether to consolidate. We accept this; the iOS-only v1 is the explicit scope.
- **−** APNs stores at most 1 pending notification per offline device (FCM stores 100). For a webhook-forwarder workload this is rarely material.

## References

- [APNs documentation](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)
- [Knock latency benchmarks](https://knock.app/push-api-benchmarks/compare/apns-vs-fcm)
