# Libre Health Bridge for iPhone

Libre Health Bridge imports LibreLinkUp readings into Apple Health. Manual import is free; a one-time Premium purchase unlocks optional, best-effort automatic background attempts. It does not communicate directly with the sensor.

**WARNING: Keep LibreLink running for readings and alarms. Do not use this app for treatment decisions.**

## Requirements

- Xcode with support for the iPhone's iOS version.
- An iPhone with iOS 17 or newer and Developer Mode enabled.
- A signing team that can provision the HealthKit capability.
- A LibreLinkUp account that already shows your readings.

The project uses Apple frameworks and a local Swift package. It has no third-party dependencies or custom server.

## Install on the connected iPhone

1. Open the project:

   ```sh
   open LibreHealthBridge.xcodeproj
   ```

2. Select the **LibreHealthBridge** target in Xcode.
3. Open **Signing & Capabilities**.
4. Select your team.
5. Leave **Automatically manage signing** enabled.
6. Select your connected iPhone as the run destination.
7. Unlock the iPhone.
8. If the phone requests trust or Developer Mode, complete those steps.
9. Run the app with **Command-R**.

Xcode must create or select a development certificate and provisioning profile. An unsigned build cannot run on the iPhone.

If the team cannot provision HealthKit, resolve the account capability restriction. Do not remove the HealthKit entitlement to force installation.

If the bundle identifier is unavailable, select a unique identifier under **Signing & Capabilities**.

Keep that identifier stable after the first import. A different app identity can create a separate Health data source and duplicate imports.

## Run in the simulator

1. Select the installed **iPhone 18 Pro** simulator as Xcode's run destination.
2. Run the app with **Command-R**.
3. Enter your LibreLinkUp credentials inside the app.

The simulator uses its own Keychain and Health store. Simulator imports do not write to the connected iPhone's Health store.

The cloud login still accesses your real LibreLinkUp account. No sample data replaces the cloud responses.

For a command-line build, keep simulator signing enabled:

```sh
cd ~/Repositories/libre-health-bridge
xcodebuild \
  -project LibreHealthBridge.xcodeproj \
  -scheme LibreHealthBridge \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath "${TMPDIR:-/tmp}/lhb-simulator-build" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
```

An unsigned simulator build can launch but fail Keychain access because it lacks application-identity entitlements. Ad-hoc simulator signing needs no physical-device certificate.

In this Xcode installation, **DeviceHub** provides the simulator window instead of `Simulator.app`. The Nova run task detects either app under the selected Xcode installation. Here, DeviceHub is at `/Applications/Xcode.app/Contents/Applications/DeviceHub.app`.

## First import

1. Log in with your LibreLinkUp credentials.
2. Tap **Set up Health import**.
3. In the Health setup sheet, select your own profile.
4. Compare the glucose value and measurement time with LibreLinkUp.
5. Turn on **Confirm this reading is mine** after comparing the value and time. Turn it off to withdraw confirmation.
6. Allow the Blood Glucose write permission in the setup sheet.
7. Tap **Confirm**.
8. Open Health and find **Blood Glucose → Show All Data**.
9. Compare the imported values, times, and app source with LibreLinkUp.
10. Tap **Sync with Apple Health** for another manual import.
11. Make sure that existing readings do not appear twice.

If you deny access, enable Blood Glucose writes in Health. Then return to the setup sheet and tap **Confirm**.

The app converts `FactoryTimestamp` from UTC. It shows measurement times in the phone's time zone.

The bottom bar has **Home** and **Information** tabs. Home shows the connection, Health status, and shared **Last update** time. Information shows the safety warning, privacy information, and app version.

Tap **Stop synchronization** on Home before you open the Health setup sheet. The sheet shows why sync stopped. A missing profile or disabled Health permission also stops sync. Select a profile and enable permission in the sheet. Then tap **Confirm** to resume. A profile change clears the local sync status. Existing Health samples remain unchanged.

The importer excludes malformed, future-dated, and range-flagged readings. It does not turn high or low range flags into exact values.

## Features

- Regional login and one authentication retry after HTTP 401.
- Device-only Keychain storage for credentials, selected connection, confirmation, and sync status.
- A profile dropdown with selection by stable patient identifier. Logout is required to change accounts.
- Status cards on Home with the connection, Health status, and shared **Last update** time.
- A download preview in `mg/dL` or `mmol/L`.
- A setup sheet for profile selection, reading confirmation, and Health permissions.
- Manual import of the latest reading and available history.
- Original measurement times and interstitial-source metadata.
- One **Last update** time on Home for completed manual and automatic imports.
- Logout that removes saved credentials and local status.

No import occurs at login, app launch, purchase, toggle activation, or foreground entry. Manual import runs when you tap the sync button. If you explicitly enable Premium automatic sync, iOS may offer a later background opportunity. The interface supports English and Spanish.

### Optional Premium automatic sync

Open **Automatic sync** on the main screen. Before buying, read the timing, locked-phone, unofficial-access, and safety disclosures. StoreKit shows the localized one-time purchase price and provides **Restore Purchases**. Buying or restoring does not enable sync. After completing Health setup and confirming your own profile, turn on automatic sync and choose 15, 30, or 60 minutes (30 by default). The interval is only the earliest requested opportunity; iOS may delay or skip it, especially after force quit or when Background App Refresh is disabled. Locked-phone data protection can defer overnight imports. Opening the app does not catch up automatically. Stop synchronization, withdraw confirmation, change profiles, or log out to turn automatic sync off. Manual sync remains available without Premium.

A successful automatic import updates the same **Last update** display as manual import. A deferred or failed attempt does not. There are no alarms, notifications, or guaranteed background frequency. Refunds can be requested from Apple under its policies and applicable consumer rights.

`LibreHealthBridge/Premium.storekit` is a **local testing-only** non-consumable configuration with a placeholder price, not a live App Store product. For isolated StoreKit tests, select it in Xcode's Run scheme options on a DEBUG simulator; deselect it for device/release testing. Before release, create and approve the product in App Store Connect, confirm `PremiumProduct.id`, choose the real price, add review metadata, and validate purchase/restore/revocation with Apple's supported test environments. A simulator run does not establish live product availability.

## Duplicate prevention

Each reading receives a stable HealthKit sync identifier derived from the patient identifier and UTC measurement time.

Before each import, the app queries only its own samples in the relevant time range. It does not request read access to other sources.

Unchanged readings are skipped. Corrections receive a higher HealthKit sync version. HealthKit replaces the matching older sample instead of adding another sample.

HealthKit stores the identifiers, so duplicate prevention does not depend on an in-memory list or local import file.

This mechanism also protects retries after an interrupted save. A new sync checks Health again before writing.

Deleting an imported sample from Health allows the next manual sync to recreate it while the cloud still supplies that reading.

Other importers can create duplicate data. Use one importer for this source. Logout does not remove existing Health samples.

## Privacy

Credentials go directly to Abbott's `libreview.io` service over HTTPS. HTTP redirects are disabled, and regional routing stays under that domain.

The Keychain item uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. It does not synchronize through iCloud Keychain or migrate to another device.

API tokens and downloaded glucose values stay in memory. Imported readings persist in Health under the user's Health settings.

Automatic opt-in, interval, earliest attempt, and redacted attention/backoff state are saved with the protected Keychain session; StoreKit provides verified purchase ownership. No ordinary local flag grants ownership. The privacy manifest declares existing UserDefaults access.

The app has no analytics or sensitive application logs. It covers its content when the scene becomes inactive.

Screenshots, device diagnostics, and Apple's services are outside this app's control. Hashed reading identifiers are pseudonymous, not anonymous.

## Failure behavior

Rate limits and network failures stop the current operation; opted-in background attempts use conservative later requests, respecting a valid HTTP Retry-After delay. Terms acceptance requires the official LibreLinkUp app and blocks further background attempts until the user resolves it. Invalid credentials and missing setup also require attention.

If Keychain or Health is protected while locked, background imports defer without clearing consent; credentials retain when-unlocked device-only protection. A failed import does not update the last completed sync time. If a Health import succeeds but local status storage fails, the app shows a storage warning rather than claiming a clean persisted result.

A completed Health permission sheet does not prove authorization. The app checks glucose write permission before importing.

A profile change clears the previous preview and confirmation before the app downloads the selected profile. It never imports a graph for a mismatched patient identifier.

## Tests and device build

Run the pure Swift tests on this Mac:

```sh
cd BridgeCore
swift test
TZ=Pacific/Honolulu swift test
```

These tests use synthetic data and mock HTTP responses. They cover routing, authorization failures, timestamps, units, invalid data, patient isolation, and import planning.

Compile for iPhone without signing:

```sh
cd ~/Repositories/libre-health-bridge
xcodebuild \
  -project LibreHealthBridge.xcodeproj \
  -scheme LibreHealthBridge \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "${TMPDIR:-/tmp}/lhb-device-build" \
  CODE_SIGNING_ALLOWED=NO build
```

This command verifies compilation, not installation or HealthKit behavior. Real Health writes still require the signed-device acceptance checks.

### Device acceptance checklist

- Correct profile, glucose value, units, and measurement time.
- Permission denied: no import and a clear explanation.
- First import: expected samples and original times in Health.
- Repeated import: no duplicate samples.
- App restart: duplicate prevention still works.
- Network failure: no stale preview import and no false sync success message.
- Revoked Health permission: no import.
- Logout: no stored login, but existing Health samples remain.
- Dedicated test device and test Apple account: validate StoreKit purchase/restore/revocation, cold background launch, locked-phone deferral, later unlock, interrupted saves, disabled Background App Refresh and force quit. Do not use synthetic simulator launch arguments against real stores. A simulated task launch does not prove iOS will run at a selected interval.

## Limits

Background refresh is opportunistic, not a permanent service or guaranteed periodic polling. There is no automatic foreground import, reliable locked-phone importing, direct sensor access, notifications, widgets, Watch app, or full-history guarantee.

Cloud history has a limited window. Manual sync cannot recover readings that the cloud no longer supplies.

The cloud interface is unofficial and can change. This app is not affiliated with Abbott or Apple.

## Source layout

- `LibreHealthBridge/`: SwiftUI screens, application state, Keychain, and HealthKit adapter.
- `BridgeCore/`: cloud protocol, timestamp normalization, and import planner.
- `BridgeCore/Tests/`: tests that run on the Mac without an iPhone or simulator.
- `LibreHealthBridge.xcodeproj/`: Xcode project and shared scheme.

## Apple references

- [HealthKit authorization](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)
- [HealthKit sync identifiers](https://developer.apple.com/documentation/healthkit/hkmetadatakeysyncidentifier)
- [HealthKit sync versions](https://developer.apple.com/documentation/healthkit/hkmetadatakeysyncversion)
