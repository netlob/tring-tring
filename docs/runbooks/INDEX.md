# Runbooks

Operational procedures. Each is self-contained — start at step 1, follow it through, never skip steps. Runbooks must be **verified**: write the steps, run them end-to-end on a real (or staging) system, and update the runbook with the actual commands and observed output. Stub runbooks are marked `Status: Stub`.

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-restore-from-litestream.md) | Restore the SQLite database from Litestream | Stub — verify during deploy (build step 10) |
| [0002](0002-rotate-apns-key.md) | Rotate the APNs `.p8` key | Stub — verify during first key rotation |
| [0003](0003-deploy-coolify.md) | Deploy via Coolify (or any Docker host) | Stub — verify during deploy (build step 9) |
| [0004](0004-tune-rate-limits.md) | Tune rate limits / quota for a specific device | Stub — verify on first incident |

## Conventions

- Always include the **exact** commands (with placeholders clearly marked `<like-this>`).
- Include expected output where it confirms success.
- If a step can fail, document the failure mode and recovery.
- Mark commands that touch production with **⚠ PROD**.
- Update the runbook as part of any change that alters the procedure. A stale runbook is worse than no runbook.
