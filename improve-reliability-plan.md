## iOS review

**Assessment:** A solid small-app foundation, but not yet production-hardened. The largest gaps are failure recovery, app-level testing, and consistent operation state—not a need for more frameworks.

Reviewed only `ios/`, using two read-only `gpt-6-luna` subagents and direct validation. No source files changed.

### Prioritized findings

#### 1. High — A malformed glucose value can crash setup
**Files:** `ios/LibreHealthBridge/ContentView.swift:297`, `ios/BridgeCore/Sources/BridgeCore/ReadingNormalizer.swift:39`

Normalization accepts any positive, finite `Double`. Setup then converts it using `Int(value.rounded())`, which traps for values outside the integer range.

**Validated:** `1e20` passes preview validation but cannot be represented as `Int`.

**Professional baseline:** Format numbers without an unchecked integer conversion. Define supported input bounds separately, and test oversized finite values.

#### 2. High — Privacy protection may not cover presented sheets
**Files:** `ios/LibreHealthBridge/LibreHealthBridgeApp.swift:10–16`, `ios/LibreHealthBridge/ContentView.swift:38–50`

The inactive-scene cover sits above the root content, but login and setup are presented as sheets above that hierarchy. Those sheets contain account and health information.

`.privacySensitive()` alone does not conceal content when the app becomes inactive; Apple documents it as participating in privacy redaction.

**Professional baseline:** Apply a reusable privacy cover to every presentation root, or use a window-level solution. Test app-switcher snapshots with each sheet open.

**Status:** Structural risk; device verification required.

#### 3. Medium — Failed restoration can leave profile setup without a retry path
**Files:** `ios/LibreHealthBridge/AppModel.swift:37–46`, `ios/LibreHealthBridge/ContentView.swift:289–305,400–405`

Consider a saved session with no selected profile:

1. Restoration loads the session.
2. Fetching connections fails.
3. The profile menu remains empty and disabled.
4. The refresh button is hidden because no profile is selected.
5. Restoration cannot rerun because `restored` is already true.

Recovery requires relaunching or logging out.

**Professional baseline:** Provide connection refresh independently of profile selection. Represent restoration as explicit loading, loaded, and retryable-failure states.

#### 4. Medium — Operation results conflate failure, partial success, and ignored requests
**Files:** `ios/LibreHealthBridge/AppModel.swift:113–130,165–174`

Two examples:

- Health writes succeed, but saving session status fails: the app displays **“Sync failed”**, although Health has changed.
- A second sync arrives while busy: `perform` returns `false`, and that invocation changes feedback to failure while the original operation continues.

**Professional baseline:** Return explicit outcomes such as success, completed-with-storage-warning, cancelled, rejected-as-busy, and failure. Only the active operation should own its feedback.

Add regression tests for both scenarios.

#### 5. Medium — The most consequential application behavior is untested
**Files:** `ios/LibreHealthBridge/AppModel.swift:23–25`, `ios/LibreHealthBridge/HealthWriter.swift:24–38`, `ios/LibreHealthBridge.xcodeproj/project.pbxproj:94–114`

The core has useful tests, but the Xcode project has no application test target. `AppModel` constructs its own Keychain, Health writer, and cloud client, making controlled failure testing difficult.

**Professional baseline:** Inject a session store, Health writer, and cloud-client factory. Reuse the existing `GlucoseHealthStore` seam rather than introducing an elaborate architecture.

Priority tests:

- Restore failure and retry.
- Profile switching clears verification.
- Permission denial prevents writes.
- Health success followed by persistence failure.
- Repeated commands and cancellation.
- Failed refresh never imports stale data.

#### 6. Medium — Cancellation handling is incomplete
**Files:** `ios/BridgeCore/Sources/BridgeCore/CloudClient.swift:105–108`, `ios/LibreHealthBridge/HealthWriter.swift:47–64,107–124`

The client preserves `CancellationError`, but maps `URLError(.cancelled)` to a network failure. **Validated with an injected transport.**

The Health query continuation has no cancellation handler, and the writer does not check cancellation between querying existing samples and saving.

**Professional baseline:** Normalize cancellation at adapter boundaries, stop cancellable queries, and check cancellation before starting writes. Define how to report a save that finishes after cancellation.

### Best code-reuse opportunities

| Area | Current gap | Recommended change |
|---|---|---|
| Timestamp validation | Regex compilation and timestamp parsing repeat across selection, preview, and normalization. | Cache the regex and share a parsed/validated measurement representation. |
| Reading identity | The `"libre-health-bridge.v1."` namespace appears in both core identity generation and Health filtering. | Centralize identifier construction and recognition. |
| Screen structure | `ContentView.swift` contains five screens plus presentation helpers. | Split by screen; share the duplicated bottom action layout and privacy cover. Avoid a generic screen framework. |
| Glucose presentation | Setup hard-codes `mg/dL` despite an existing `GlucoseUnit` abstraction. | Use one safe, locale-aware glucose formatter built around that abstraction. |
| Localization | `Connection.displayName` returns a localization-key sentinel that the UI compares against a literal. | Keep domain names separate from localized fallback text; localize at the presentation boundary. |

### What already meets a good standard

- Clear separation between `BridgeCore` and platform adapters.
- Injectable cloud transport and Health-store boundary.
- Defensive timestamp parsing and malformed-reading exclusion.
- Bounded authentication retries and restricted regional routing.
- Device-only Keychain storage and redacted errors.
- Stable HealthKit sync identifiers and correction versions.

### Validation

- **25 core tests passed**, also under `TZ=Pacific/Honolulu`.
- **Unsigned iPhone build passed.**
- Real-device HealthKit behavior and privacy snapshots remain unverified.

**Recommended order:** Fix the crash and privacy coverage first, add dependency injection and application tests second, then simplify operation outcomes and extract reusable components.

References checked: Apple’s [privacy-sensitive views](https://developer.apple.com/documentation/swiftui/view/privacysensitive(_:)), [HealthKit authorization](https://developer.apple.com/documentation/healthkit/hkhealthstore/authorizationstatus(for:)), and [sync identifiers](https://developer.apple.com/documentation/healthkit/hkmetadatakeysyncidentifier).
