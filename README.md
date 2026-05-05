# tring tring

Self-hosted iOS push notifications. Webhook in → push out. Drop-in compatible with [Pushcut](https://www.pushcut.io/)'s webhook format so existing automations migrate by changing only the URL.

- **iOS app**: native SwiftUI. Register on first launch, get your personal webhook URL.
- **Backend**: Rust (axum + SQLite + Litestream), deploys to a ~€3.29/mo Hetzner VPS.
- **100% free**: No paid features and a generous quota of 10 notifications/min per device, over 500k per month per device.

## Project status

Pre-v1. Architecture frozen ([docs/adr](docs/adr/INDEX.md)), implementation in progress.

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

## iOS app

The iOS half lives under `ios/` as an Xcode 16 project. The app targets iOS 26.0 only so it can lean fully into Liquid Glass — `.glassEffect()`, `GlassEffectContainer`, `.buttonStyle(.glass)`, the floating tab bar, sheet `.presentationBackground(.glass)`. An iOS 17 backport is a future option, gated by community demand.

### One-time Xcode setup

1. **Open the project** from the repo root:

   ```bash
   open "ios/Tring Tring.xcodeproj"
   ```

2. **Confirm the deployment target is iOS 26.0** on both the `Tring Tring` app target and the `NotificationServiceExtension` target.

3. **Notification Service Extension target** is already in the project (`NotificationServiceExtension`, bundle id `dev.sjoerd.tringtring.NotificationServiceExtension`). If you ever recreate it from scratch, the steps are: File → New → Target → "Notification Service Extension"; bundle id `dev.sjoerd.tringtring.NotificationServiceExtension`; embed in `Tring Tring`; deployment target iOS 26.0; do NOT activate the new scheme. Verify under Signing & Capabilities that the team is `FCB4S3W235` and signing is automatic. If automatic provisioning fails ("Failed to register bundle identifier"), pre-register `dev.sjoerd.tringtring.NotificationServiceExtension` in https://developer.apple.com/account → Identifiers with Push Notifications enabled, then click "Try Again" in Xcode.

4. **Capabilities**: Push Notifications and Sign in with Apple are enabled on the main app target. The `aps-environment` entitlement is `development` for Debug builds; Xcode auto-promotes to `production` for Release archives.

### Architecture quick reference

The Swift sources live under `ios/Tring Tring/`, organised by feature scope:

- `App/` — entry point, AppRouter, AppDelegate (push lifecycle).
- `Auth/` — DeviceState, KeychainStore, Sign in with Apple view.
- `Net/` — BackendClient, Codable models, typed APIError, base URL config.
- `Push/` — UNNotificationCategory registration, action routing, userInfo envelope, self-test sender.
- `Design/` — Theme tokens, Liquid Glass components (BrandedCard, StatusPill, WebhookURLBlock, etc.).
- `Features/{Activity,Templates,Settings,Home}/` — feature-scoped views and view models.
- `Onboarding/` — 3-step post-SIWA onboarding.
- `Sounds/` — read-only catalog of the 8 named sounds (ADR-0013).
- `ContentView.swift` — thin `AppRouter()` wrapper.
- The `NotificationServiceExtension/` directory at the repo's `ios/` root is the NSE target — a separate signed binary that downloads notification image attachments at delivery time.

The whole `ios/Tring Tring/` tree is an Xcode 16 `PBXFileSystemSynchronizedRootGroup` — new files dropped under it are auto-included in the build with zero `project.pbxproj` edits. Only the NSE target needs explicit pbxproj membership.

### Build, run, test

```bash
# Simulator build (no signing)
xcodebuild -project "ios/Tring Tring.xcodeproj" \
  -scheme "Tring Tring" \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build CODE_SIGNING_ALLOWED=NO

# List schemes / targets
xcodebuild -list -project "ios/Tring Tring.xcodeproj"

# Boot a simulator and install (after building)
xcrun simctl boot 'iPhone 17 Pro' 2>/dev/null || true
xcrun simctl install booted ~/Library/Developer/Xcode/DerivedData/Tring_Tring-*/Build/Products/Debug-iphonesimulator/'Tring Tring'.app
xcrun simctl launch booted dev.sjoerd.tringtring

# Real-device build (for push delivery testing)
xcodebuild -project "ios/Tring Tring.xcodeproj" \
  -scheme "Tring Tring" \
  -configuration Debug \
  -destination 'generic/platform=iOS' build
```

### Physical-device verification sequence

Push delivery cannot be tested in the simulator. After installing a Debug build on a real device, run this sequence:

1. Open the app → onboarding step 3 → tap "Send a test" → expect a push within ~1 second; tapping it returns you to the app.
2. From a separate machine, `curl` the user's webhook URL with the payloads below (substitute `$URL` for the user's webhook URL).

   ```bash
   # Plain push
   curl -X POST "$URL" -H 'Content-Type: application/json' -d '{"title":"Hello","text":"Plain push"}'

   # Image
   curl -X POST "$URL" -H 'Content-Type: application/json' -d '{"title":"Image","text":"NSE attachment","image":"https://images.unsplash.com/photo-1494256997604-768d1f608cac?w=1200"}'

   # Single-action open URL
   curl -X POST "$URL" -H 'Content-Type: application/json' -d '{"title":"With action","text":"Has a button","actions":[{"name":"Open Apple","url":"https://apple.com"}]}'

   # Run-on-server action
   curl -X POST "$URL" -H 'Content-Type: application/json' -d '{"title":"Server action","text":"Tap to run on server","actions":[{"name":"Run","url":"https://httpbin.org/get","runOnServer":true}]}'

   # Scheduled (delayed) — then cancel from the Activity tab
   curl -X POST "$URL" -H 'Content-Type: application/json' -d '{"title":"Scheduled","text":"Will fire in 30s","delay":"30s","identifier":"test-cancel"}'

   # defaultAction body tap
   curl -X POST "$URL" -H 'Content-Type: application/json' -d '{"title":"Body tap","text":"Tap me to open Apple","defaultAction":{"url":"https://apple.com"}}'
   ```

3. Each push case verifies a different ADR (0013 image, 0016 actions, 0017 runOnServer, 0015 scheduled / 0014 cancel, 0013 defaultAction).

## License

TBD.
