# Premium automatic background sync — implementation spec

## Status and handoff

**Product decisions approved by the user. Implementation not started.** This document is the implementation handoff, not a claim that the feature exists or has been tested.

Work in `/Users/jordi/Repositories/libre-health-bridge-recurrent-background-sync`, branch `feature/recurrent-background-sync`. The inspected baseline is `18bf9ca`; inspect the current worktree before changing it and preserve unrelated changes. Paths below are relative to that worktree. The product is the existing iOS LibreLinkUp-to-Apple Health importer.

The user wants a small one-time paid feature to help cover Apple Developer Program costs. Premium unlocks **automatic background sync only**. Manual sync stays free. Timing is best-effort, and locked-phone imports are explicitly deferred in v1.

## 1. Product contract

### Purchase and ownership

- Implement a real StoreKit 2 **non-consumable, one-time** Premium purchase, restoration, verified entitlement checking, and transaction-update handling.
- Proposed product identifier: `com.jordi.librehealthbridge.premium`. Centralize it so it can be reconciled with App Store Connect before release.
- Display StoreKit's localized price; the actual price is a release decision, not a hardcoded UI value.
- Payment is a feature purchase that supports the project, not a donation or subscription.
- Purchase alone never enables automatic sync. No account with this developer and no payment backend are required.
- Use verified StoreKit ownership, not an ordinary persisted `isPremium` flag as proof of payment. Previously verified ownership may support offline operation; an App Store network request is not required before every sync.
- Distinguish owned, not owned, and temporarily unknown/unavailable entitlement states. When ownership cannot be established, defer automatic sync and keep manual sync usable. Transient errors are not evidence of a refund.
- Detect refunded/revoked ownership, stop authorizing automatic imports, and reconcile pending background work. Ownership is attached to the Apple purchase, not the LibreLinkUp login.
- Handle pending, cancelled, failed, and unverified purchases without granting Premium. Include a user-initiated Restore Purchases action.

Before purchase, disclose:

1. A one-time purchase helps cover distribution/development costs and unlocks automatic sync; there is no subscription.
2. iOS controls execution. The selected interval is approximate, and background work may be substantially delayed or unavailable.
3. Locked-phone data protection can delay imports, including overnight. Opening the app does not automatically catch up.
4. This app is unofficial and unaffiliated with Abbott. Continued functionality depends on LibreLinkUp access, which may change or disappear for all users.
5. This is not a glucose alarm or treatment-monitoring service; keep the official app for readings and alarms.

Avoid promises of lifetime service or exemption from refunds. Users can request refunds through Apple; eligibility and applicable consumer rights are not overridden by this disclosure. The user's expectation that an API shutdown would be understood is not a no-refunds requirement.

### Controls and presentation

- Add an **Automatic sync** entry to the app's existing main screen (`HomeView`), opening a dedicated settings screen. This has **nothing to do with Apple Home or HomeKit**.
- Non-Premium users see the explanation, limitations, purchase action, and restore action.
- Premium users see an enable toggle and interval dropdown: **15, 30, 60 minutes**, default **30**. These choices provide control over request frequency; do not promise particular battery savings.
- Automatic sync defaults off, including when no setting exists in an older saved session. Require Premium, login, confirmed own profile, Health write permission, and completed/unpaused Health setup before enabling.
- Keep **one shared “Last update” timestamp in the existing manual-sync completion location**. Manual and automatic imports update the same completion state. Do not add a separate automatic-sync completion timestamp or history.
- A completed import, including a successful no-change import, can advance that timestamp. Preview downloads, scheduler submissions, deferrals, and failed imports cannot.
- Show concise automatic-sync status: off, enabled with timing managed by iOS, temporarily unavailable/deferred, or needs attention. A latest-attempt outcome is sufficient; no detailed activity log is required.
- Disclose locked-phone limitations both before purchase and near the setting. Explain disabled Background App Refresh when observable. Do not display a requested earliest date as a guaranteed next execution time.
- Provide English and Spanish strings and accessible controls consistent with the existing UI.
- No notifications in v1.

### Scheduling

Use Apple's background task scheduler, with background app refresh as the intended mechanism. This is not a permanent background service. Validate the relevant Apple APIs and lifecycle requirements during implementation.

- Register the task early enough for cold background launches; configure the permitted identifier and required background mode.
- Enabling automatic sync requests the first attempt **no earlier than one selected interval later**. Enabling does not import immediately.
- A successful manual sync moves the next eligible background attempt to at least one selected interval after that completion. This reduces redundant cloud requests.
- After a background attempt, request a later opportunity no earlier than the selected interval later, subject to longer rate-limit/backoff delays.
- Changing the interval replaces/reconciles the pending request. Maintain at most one pending refresh request for this feature.
- Treat these as earliest requested delays. iOS may delay or omit execution; force-quitting, system settings, and power conditions affect availability.
- **No automatic foreground sync:** no timer while open, no import at app launch, and no catch-up on returning to the foreground. Foreground lifecycle events may refresh entitlement/status and reconcile scheduling without importing. If a scheduled callback arrives while active, preserve the foreground-manual-only policy.
- Only one sync/import operation may run at a time. Coordinate manual and background work, including foreground transitions during an already-running background import. Do not start a duplicate operation or cancel a Health save and assume it was rolled back.
- A background wake must recheck eligibility, not trust the state that existed when scheduling occurred.
- Handle task expiration, cancellation, resubmission, and task completion exactly once. Distinguish no-work/deferred cases from completed imports; never falsely advance “Last update.”
- Preserve enough non-glucose scheduling state across process death to avoid a cold launch ignoring a recent manual sync or a server backoff.

## 2. Safety and failure policy

### Protected data and import correctness

The baseline stores the session with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. `HealthWriter` queries this app's existing Health samples before planning writes, including correction versions. These are deliberate safeguards.

- Preserve current credential protection. V1 defers when credentials or required Health data are unavailable due to device protection; do not weaken Keychain access or introduce a glucose cache to simulate locked-phone support.
- Device protection may change during an operation. Handle query/load/save failure safely even after a successful initial availability check.
- Temporary Keychain inaccessibility is not logout, bad credentials, absent ownership, or erased consent.
- Reuse fresh cloud fetching, selected/verified patient checks, normalization, duplicate prevention, and correction handling for manual and background paths.
- Never import an old preview after a cloud failure or fall back to another profile.
- Preserve the existing invariant that an interrupted Health save may have completed; subsequent retries must safely deduplicate it.
- Retain truthful behavior when Health import succeeds but persisting local completion state fails. Preserve the existing storage-warning distinction rather than treating it as a clean persisted success.
- Persist only necessary settings, scheduling metadata, and redacted outcome categories. Credentials remain in device-only Keychain; readings and API tokens retain their existing in-memory behavior. Avoid sensitive logging.

### Failure and consent transitions

| Event | Required behavior |
| --- | --- |
| Locked/protected data unavailable | Defer, retain opt-in, later scheduled opportunity; no automatic foreground catch-up. |
| Offline or temporary server failure | Retain opt-in; conservative later retry, no rapid retry loop. |
| Rate limit | Back off; respect a valid server retry delay when supplied, even if longer than the selected interval. |
| Invalid credentials or new LibreLinkUp terms | Needs attention; block automatic attempts that require user intervention until resolved. Do not bypass the official terms flow. |
| Missing profile or revoked Health permission | Needs attention; require explicit profile/Health setup confirmation before automatic imports resume. |
| Background App Refresh unavailable | Explain the system limitation; retain the user's preference but do not claim execution is assured. |
| Entitlement temporarily cannot be established | Defer automatic sync; preserve manual access and distinguish from known revocation. |
| Refund/revocation detected | Disable automatic sync and reconcile pending work; leave free manual sync intact. |
| Logout, profile switch, withdrawal of preview confirmation, or Stop synchronization | Turn automatic sync off, cancel pending work, and require renewed explicit opt-in. A new login/profile must not inherit enabled automatic imports. |

Temporary connectivity and lock failures do not clear consent. Explicit account/profile/stop actions do. Persist consent changes safely: a failed save/delete must not make the UI claim a durable stop or successful logout that did not occur. Recheck eligibility before importing when state changes race an in-flight fetch; acknowledge that a Health write already submitted may complete.

## 3. Implementation map and suggested work order

These are recommended boundaries, not mandated class names. Keep the change focused and preserve manual-sync behavior.

### Read first

- `LibreHealthBridge/LibreHealthBridgeApp.swift`: launch and scene lifecycle.
- `LibreHealthBridge/Models/AppModel.swift`, `AppModel+Session.swift`, `AppModel+HealthSync.swift`: state, restore, selection, confirmation, manual import, serialization of operations.
- `LibreHealthBridge/KeychainStore.swift`: saved session and persistence failures.
- `LibreHealthBridge/HealthWriter.swift`, `BridgeCore/Sources/BridgeCore/ImportPlanner.swift`: Health store seam, deduplication, correction versions, cancellation.
- `BridgeCore/Sources/BridgeCore/CloudClient.swift`: transport, authentication retry, and error classification.
- `LibreHealthBridge/Views/HomeView.swift`, `HealthSetupView.swift`, `InformationView.swift`: UI and existing manual-only explanatory text.
- `LibreHealthBridge/SimulatorScenarios.swift` and existing tests: safe DEBUG simulator-only fixtures.

### Work packages

1. **Policy and state:** Define deterministic eligibility, scheduling, consent reset, and failure transitions with an injectable clock and tests. Model opt-in separately from ownership and temporary execution blockers. Completion: policy cases in section 4 pass without StoreKit, real cloud, or Health data.
2. **Entitlements:** Add a small StoreKit adapter and injectable ownership/purchase interface, local StoreKit configuration, and verified transaction handling. Completion: purchase/restore/revocation/unknown-state behavior is covered; production has no fixture bypass.
3. **Sync coordination and scheduler:** Reuse or extract the existing import operation; wire cold-launch scheduling, protected-data deferral, cancellation, and persistent reconciliation. Completion: manual/background contention and task lifecycle tests pass without changing free manual behavior.
4. **UI and documentation:** Implement the main-screen entry, settings/purchase UI, shared timestamp label, statuses, and both localizations. Update affected manual-only/privacy/limitations documentation, including `ios/README.md` where relevant. Completion: focused UI scenarios cover both ownership states, consent, blockers, and shared completion display.
5. **Integration and release handoff:** Compile production configurations, run bounded targeted tests, and report the results plus external setup and device checks below. Completion: every acceptance case is covered by a test or explicitly recorded as an outstanding device/release check.

Pure policy can live in `BridgeCore` when appropriate; StoreKit, BackgroundTasks, and HealthKit adapters belong in the app. Inject scheduler, entitlement, clock, and store boundaries as needed rather than making tests use real services. Audit cold-launch restoration: the existing foreground restore fetches a preview, so a background launch must not accidentally fetch/import before eligibility checks or download twice unnecessarily.

Agents working in parallel should agree on shared interfaces and file ownership first. Useful parallel areas are pure policy/tests and the StoreKit adapter; `AppModel`, launch wiring, project-file edits, and UI integration need coordination. Do not have agents concurrently edit the same Xcode project file or run multiple simulator test runners.

## 4. Acceptance coverage

Use deterministic tests with synthetic accounts/readings, injected stores, a fake clock/scheduler, and verified/unverified entitlement fixtures. Include at least:

- [ ] Free/manual sync remains functional, with no automatic import on login, launch, foreground entry, purchase, or enable-toggle activation.
- [ ] Automatic sync is off when no stored setting exists; intervals accept only 15/30/60 and default to 30.
- [ ] Missing ownership/setup/confirmation/permission prevents automatic imports and does not request interactive authorization from a background callback.
- [ ] Verified purchase and restore unlock the setting without enabling it; cancellation, pending purchase, verification failure, and product-load failure do not unlock it.
- [ ] Offline verified ownership, temporary unknown ownership, refund/revocation, and transaction updates follow section 1.
- [ ] Enable, interval change, successful manual import, background completion, failure, and cold launch reconcile one pending request with the right earliest eligibility/backoff.
- [ ] Foreground events do not import; overlapping manual/background requests do not duplicate cloud/import work.
- [ ] Locked Keychain/Health access, mid-operation protection changes, no network, rate limiting, and task expiration preserve truthful status and allow safe retries.
- [ ] Required user actions suppress repeated attempts; resolving them follows the consent rules rather than silently enabling a changed profile.
- [ ] Each consent-reset event persists off and cancels pending work; persistence failure, stale scheduled callbacks, and an in-flight fetch cannot bypass safety checks.
- [ ] Fresh selected-patient fetching, duplicate prevention, correction versions, and interrupted-save retries remain correct.
- [ ] Both successful manual and automatic imports update the same “Last update” UI/state; failed/deferred work does not. Local storage warning behavior remains explicit.
- [ ] UI covers non-Premium purchase/restore, Premium settings, incomplete setup, disabled background refresh, locked-phone disclosure, needs-attention status, and stop/reset behavior.
- [ ] Fixture entitlements/scenarios are confined to tests or DEBUG simulator builds. Production builds cannot grant ownership via launch arguments, UserDefaults, or an injected simulator scenario.

### Bounded test execution

The worktree inspected for this spec has no root `AGENTS.md`. Follow any instructions subsequently added there. Use the actual root-level project/package paths, not stale nested paths in older documentation.

- Core: `swift test --package-path BridgeCore --scratch-path "${TMPDIR:-/tmp}/lhb-core-tests"`.
- Model/scenario tests: one booted iPhone simulator with a fixed UDID, root `LibreHealthBridge.xcodeproj`, scheme `LibreHealthBridge`, `-parallel-testing-enabled NO`, and `-only-testing:LibreHealthBridgeTests`.
- UI: focused identifiers such as `-only-testing:LibreHealthBridgeUITests/LibreHealthBridgeUITests/testMethodName`; shard instead of running the entire scheme unfiltered.
- Compile without launching a simulator using `build -destination 'generic/platform=iOS Simulator'`. Also check Release or `generic/platform=iOS` for fixture exclusion.
- Use one simulator test runner at a time. Reuse an OS-temp derived-data directory within this checkout; logs and results also belong in OS temp.
- Bound **each** build/test invocation, including `swift test`, to at most 175 seconds with process-group cleanup. A harness timeout alone is insufficient. A suitable wrapper is:

```python
# Usage: python3 /tmp/bounded-test.py /tmp/test.log COMMAND ARGUMENTS...
import os, signal, subprocess, sys
with open(sys.argv[1], "w") as log:
    proc = subprocess.Popen(sys.argv[2:], stdout=log, stderr=subprocess.STDOUT,
                            start_new_session=True)
    try:
        result = proc.wait(timeout=175)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
        print("Timed out; this invocation did not pass", file=sys.stderr)
        sys.exit(124)
sys.exit(result)
```

Report observed Swift Testing and XCTest counts separately, failures/timeouts, and partially run suites. Filtering a global Swift Testing function by `AppModelTests/<function>` has selected zero tests here. Test summaries without a successful Xcode invocation are not a pass. Read failure/last-completed-test lines before retrying, and confirm owned runner processes are stopped after a timeout. The existing Nova test action is unbounded and runs the whole scheme; do not use it for this work.

## 5. External release setup and honest limitations

The coding agent can implement and test locally. The following remain external release work:

- Create the non-consumable in App Store Connect, confirm the product ID, choose price/availability, supply review metadata, and obtain approval. Do not invent a production price or claim local StoreKit testing proves a live product is available.
- Validate purchase/restore and revocation behavior with Apple's supported test environments. Automated tests must not use real purchases or real user accounts.
- On a dedicated test device/account, validate actual background launch, locked-device deferral, unlock followed by a later eligible attempt, interrupted saves, and the effect of disabled Background App Refresh/force quit. This acceptance work must be explicit and separate from synthetic automated tests; do not use fixture scenarios against real stores.
- Observe opportunistic iOS scheduling without interpreting an interval choice as a timing guarantee. Forced/simulated task launches prove handler behavior, not real-world frequency.
- Verify that disclosure and actual experience align before charging for the feature, especially the overnight limitation.

### Out of scope

Guaranteed periodic execution; automatic foreground imports; reliable locked-phone/overnight importing; weaker credential protection; glucose caching; push infrastructure; background-mode workarounds; subscriptions; optional tips/donations; Apple Home/HomeKit; notifications; detailed sync history; direct sensor access; alarms; and a full-history guarantee.

### Primary references to verify during implementation

- Apple BackgroundTasks: <https://developer.apple.com/documentation/backgroundtasks>
- StoreKit: <https://developer.apple.com/documentation/storekit>
- HealthKit data protection: <https://developer.apple.com/documentation/healthkit/protecting-user-privacy>
- Paid feature unlocks and tipping: <https://developer.apple.com/app-store/review/guidelines/#in-app-purchase>
- Refund requests and regional eligibility: <https://support.apple.com/en-us/118223>

## Definition of done

Implementation satisfies the contract above, acceptance coverage is accounted for, production builds exclude test bypasses, documentation matches the changed behavior, and the final handoff lists changed files, actual test counts/results, and unresolved release/device checks. This spec alone does not authorize App Store publication, real purchases, or use of a real account/device for fixture tests.
