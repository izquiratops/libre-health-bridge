# Branch feature and change report

**Branch:** `feature/recurrent-background-sync`  
**Compared:** working tree at `18bf9ca` against that commit; the current `main` is three commits ahead of the common base (`18bf9ca`).  
**Worktree:** contains uncommitted implementation changes and new files. This report describes those changes as present in the checkout, not as committed or release-ready.

## Executive summary

This work adds an optional, one-time-purchase Premium feature for best-effort automatic LibreLinkUp-to-Apple Health syncing in the background. Manual sync remains free. The implementation uses StoreKit 2 for purchase/ownership and iOS BackgroundTasks for scheduling, with user-visible timing and locked-device caveats. It shares the existing import path and completion timestamp rather than introducing a separate importer or sync history.

The same worktree also includes safeguards and integration tests for health setup, account/profile consent, background eligibility, retry/backoff, and simulator-only testing. Actual background execution is controlled by iOS; the selected 15/30/60-minute interval is an earliest requested delay, not a guarantee.

## User-facing features

- **Premium purchase and restore:** StoreKit 2 non-consumable product ID `com.jordi.librehealthbridge.premium`, localized StoreKit price, purchase/restore actions, verified current-entitlement checks, and transaction-update observation. Purchase does not automatically enable sync.
- **Automatic-sync settings:** a new Home-screen entry opens a dedicated settings page. Premium owners can opt in and select **15, 30, or 60 minutes** (default 30). Free users retain manual sync and see purchase and restore options.
- **Transparent limitations:** English and Spanish copy discloses that iOS chooses when background work runs, locked phones can defer imports (including overnight), force quit/settings can prevent attempts, the app is unofficial, and it is not an alarm or treatment-monitoring service.
- **Status and setup gating:** UI status covers off, enabled, deferred, unavailable Background App Refresh, and attention/setup cases. Enabling requires verified ownership and an eligible, confirmed health-sync setup.

## How the implementation works

- `LibreHealthBridge/AutomaticSync.swift` contains StoreKit ownership/purchase behavior, the BackgroundTasks scheduler adapter, task registration and completion coordination, and automatic-sync orchestration.
- `AppModel` receives injectable premium, scheduler, clock, and device-state dependencies. This gives tests seams for system-owned behavior and time.
- A scheduled background attempt reloads saved state if needed, then rechecks entitlement, protected-data availability, selected/verified profile, consent, Health access, pause state, and the requested earliest time. It uses the existing fresh cloud fetch, normalization/planning, and Health-write path.
- Manual and automatic sync share the same operation guard and `lastSync` completion state. Manual success pushes the next background opportunity out by the selected interval. Rate limiting can honor the server's `Retry-After` date; other failures use a conservative delay.
- Opt-in, interval, next eligible time, backoff, and attention/deferred flags are persisted with the existing session. Automatic sync is default-off for existing sessions. Logout, profile changes, and stop/setup transitions clear automatic consent and reconcile pending work.
- Cold background launch is wired separately from the foreground preview restore. A background callback delivered while the app is active does not import.

## Supporting changes

- `BridgeCore/CloudClient.swift` now parses both numeric and HTTP-date `Retry-After` values on rate-limit responses and exposes a dated rate-limit error.
- Session/model/health-sync changes coordinate automatic eligibility with existing profile verification, pause/setup state, Health authorization, and the common sync operation.
- `LibreHealthBridge/Info.plist` and the Xcode project add background-task configuration and StoreKit configuration references.
- `LibreHealthBridge/SimulatorScenarios.swift` adds premium/background-refresh/attention scenarios through injected adapters, rather than changing production entitlement behavior.
- English and Spanish localization files contain purchase, settings, status, safety, and limitation text.
- `ios/README.md` is updated for the new behavior.
- `docs/specs/recurrent-background-sync.md` documents the product contract, safety rules, acceptance checklist, and release/device limitations.

## Test and verification status

- Ran `swift test --package-path BridgeCore --scratch-path "${TMPDIR:-/tmp}/lhb-report-core-tests"` successfully.
- Swift Testing reported **27 tests passed** (including parameterized cases); the XCTest summary printed **0 tests** because this package suite uses Swift Testing. No failures were reported.
- This run validates the BridgeCore package only. It does **not** verify the iOS app build, app-model tests, UI tests, StoreKit purchase flows, or real iOS background scheduling. Those were not run for this report.
- No claim is made that App Store Connect product setup or live purchase/review has occurred.

## Limitations and follow-up checks

1. iOS may delay or omit background refresh. Real scheduling cadence cannot be proven by a simulator callback or requested interval.
2. Locked-device data protection can defer work. The feature does not promise overnight syncing or automatic foreground catch-up.
3. Verify the product identifier, price, availability, and review setup in App Store Connect before release; the local StoreKit configuration is for testing, not proof of a live product.
4. Run bounded iOS simulator build/model/UI test suites, then validate StoreKit restore/revocation in Apple's supported test environment.
5. Perform dedicated on-device checks for cold background launch, locked-phone deferral, Background App Refresh disabled, force quit, and interrupted Health saves.
6. The implementation changes are uncommitted in the inspected checkout. Also reconcile the branch with the three commits currently on `main` after confirming intended project state.

## Key files

- `LibreHealthBridge/AutomaticSync.swift` — purchase, ownership, scheduler, and background attempt behavior
- `LibreHealthBridge/Views/AutomaticSyncView.swift` — purchase/settings/status UI
- `LibreHealthBridge/Models/AppModel.swift`, `AppModel+Session.swift`, `AppModel+HealthSync.swift` — model integration and sync eligibility
- `LibreHealthBridge/KeychainStore.swift` — persisted automatic-sync preferences
- `BridgeCore/Sources/BridgeCore/CloudClient.swift` — server retry delay handling
- `LibreHealthBridge/LibreHealthBridgeApp.swift`, `Info.plist`, `LibreHealthBridge.xcodeproj/project.pbxproj` — lifecycle and platform configuration
- `docs/specs/recurrent-background-sync.md` — detailed feature specification and acceptance requirements
