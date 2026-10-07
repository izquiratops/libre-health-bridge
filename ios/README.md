# Libre Health Bridge for iPhone

Version 0.1 is a manual LibreLinkUp-to-Apple Health importer. It does not communicate directly with the sensor.

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
   open ~/Repositories/libre-health-bridge/ios/LibreHealthBridge.xcodeproj
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
  -project ios/LibreHealthBridge.xcodeproj \
  -scheme LibreHealthBridge \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath ios/.derivedData \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
```

An unsigned simulator build can launch but fail Keychain access because it lacks application-identity entitlements. Ad-hoc simulator signing needs no physical-device certificate.

In this Xcode installation, **DeviceHub** provides the simulator window. The app is at `/Applications/Xcode.app/Contents/Applications/DeviceHub.app`.

## First import

1. Log in with your LibreLinkUp credentials.
2. Tap **Set up Health import**.
3. In **Health profile and permissions**, select your own profile from the dropdown.
4. In the setup sheet, compare the glucose value and measurement time with LibreLinkUp.
5. Confirm that the readings belong to you and match LibreLinkUp.
6. Tap **Continue and sync**.
7. Allow the Blood Glucose write permission.
8. Open Health and find **Blood Glucose → Show All Data**.
9. Compare the imported values, times, and app source with LibreLinkUp.
10. Tap **Sync with Apple Health**.
11. Make sure that existing readings do not appear twice.

If you deny access, enable Blood Glucose writes in Health. Then return to the app and tap the sync button again.

The app converts `FactoryTimestamp` from UTC. It shows measurement times in the phone's time zone.

The bottom bar has **Home**, **Details**, and **Information** tabs. Home contains the account and Health cards. Their detail buttons open the corresponding section in Details.

Details shows download data and statistics for the last completed Health import. The Health section appears only after a completed import. Information contains the safety warning, privacy information, and app version. All views follow the system light or dark appearance.

The profile dropdown is in **Health profile and permissions**. The **Change profile or permissions** button opens this configuration from Home or the Health details. A profile change clears the local sync status and requires confirmation of your readings before another import. Existing Health samples remain unchanged.

The importer excludes malformed, future-dated, and range-flagged readings. It does not turn high or low range flags into exact values.

## Features

- Regional login and one authentication retry after HTTP 401.
- Device-only Keychain storage for credentials, selected connection, confirmation, and sync status.
- A profile dropdown with selection by stable patient identifier. Logout is required to change accounts.
- Status cards and a Details tab with download data and Health import statistics.
- A download preview in `mg/dL` or `mmol/L`.
- A setup sheet for profile selection, reading confirmation, and Health permissions.
- Manual import of the latest reading and available history.
- Original measurement times and interstitial-source metadata.
- Counts for new, corrected, existing, and skipped readings.
- Last successful fetch, completed sync, and actual Health write times.
- Logout that removes saved credentials and local status.

No Health import occurs at login or app launch. The app imports only after you tap the sync button. The interface supports English and Spanish.

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

The app stores only the display-unit preference in UserDefaults. The privacy manifest declares this access.

The app has no analytics or sensitive application logs. It covers its content when the scene becomes inactive.

Screenshots, device diagnostics, and Apple's services are outside this app's control. Hashed reading identifiers are pseudonymous, not anonymous.

## Failure behavior

Rate limits and network failures stop the operation without an automatic retry loop. Terms acceptance requires the official LibreLinkUp app.

If Health is locked or unavailable, the app shows an error. A failed save does not produce a success report.

A completed Health permission sheet does not prove authorization. The app checks glucose write permission before importing.

A profile change clears the previous preview and confirmation before the app downloads the selected profile. It never imports a graph for a mismatched patient identifier.

## Tests and device build

Run the pure Swift tests on this Mac:

```sh
cd ~/Repositories/libre-health-bridge/ios/BridgeCore
swift test
TZ=Pacific/Honolulu swift test
```

These tests use synthetic data and mock HTTP responses. They cover routing, authorization failures, timestamps, units, invalid data, patient isolation, and import planning.

Compile for iPhone without signing:

```sh
cd ~/Repositories/libre-health-bridge
xcodebuild \
  -project ios/LibreHealthBridge.xcodeproj \
  -scheme LibreHealthBridge \
  -destination 'generic/platform=iOS' \
  -derivedDataPath ios/.deviceBuild \
  CODE_SIGNING_ALLOWED=NO build
```

This command verifies compilation, not installation or HealthKit behavior. Real Health writes still require the signed-device acceptance checks.

### Device acceptance checklist

- Correct profile, glucose value, units, and measurement time.
- Permission denied: no import and a clear explanation.
- First import: expected samples and original times in Health.
- Repeated import: no duplicate samples.
- App restart: duplicate prevention still works.
- Network failure: no stale preview import and no false success report.
- Revoked Health permission: no import.
- Logout: no stored login, but existing Health samples remain.

## Limits

Version 0.1 has no background polling, direct sensor access, notifications, widgets, Watch app, or full-history guarantee.

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
