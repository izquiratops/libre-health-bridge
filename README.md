# Libre Health Bridge

This project contains a Node.js cloud prototype and a SwiftUI iPhone app. Both retrieve LibreLinkUp readings through an unofficial cloud interface.

The iPhone app can import validated readings into Apple Health. See [iPhone installation and first import](ios/README.md).

The Node.js client described here does not connect to the sensor or write to Apple Health. Abbott can change or restrict the cloud interface.

**WARNING: Do not use this prototype for treatment decisions or alarms. Keep the official LibreLink app in normal operation.**

## Requirements

- Node.js 22 or newer.
- An interactive terminal.
- A LibreLinkUp account that already shows your readings.

No third-party packages or Xcode tools are required.

## Fetch once

1. Open Terminal.
2. Run these commands:

   ```sh
   cd ~/Repositories/libre-health-bridge
   npm start
   ```

3. Enter your LibreLinkUp email at the prompt.
4. Enter your password at the hidden prompt.
5. If the account has multiple connections, select your own connection.

The default output contains counts, timestamps, and the regional endpoint. It excludes glucose values and patient identifiers.

## Compare readings locally

Run:

```sh
npm start -- --show-readings
```

This command prints normalized readings from the available graph history and latest measurement. Terminal scrollback contains sensitive health data.

Compare the newest value and timestamp with LibreLinkUp. The API history can have a different sampling interval from the latest readings.

The client uses `ValueInMgPerDl` for glucose values. It calculates `valueMmolL` with a divisor of 18.0182 and rounds to two decimal places.

The client interprets `FactoryTimestamp` as UTC, like the referenced uploader. It retains `Timestamp` as `sourceLocalTimestamp` for comparison.

The timestamp interpretation still requires live validation. Spain includes more than one time zone. Do not apply a fixed Spanish offset.

Readings with `isHigh` or `isLow` flags receive null normalized values. The prototype does not treat these readings as exact measurements.

## Observe cloud updates

Run:

```sh
npm start -- --watch 60
```

Each cycle fetches the selected connection and its graph history. The client waits 60 seconds after each cycle.

`newOrChangedCount` shows changes within this process. The first cycle counts all available readings. Restarting the client resets this count.

`ageSeconds` measures the age of the newest available reading. It does not isolate network latency or guarantee that LibreLink uploads continuously.

To print new or changed readings, add `--show-readings`. To stop the client, press Ctrl+C.

This mode has no background service. Sleep, terminal closure, or network failure interrupts collection. History backfill depends on the cloud's available history.

## Security and failure behavior

- Credentials and tokens stay in process memory. JavaScript cannot guarantee secure memory erasure.
- The program does not save credentials, tokens, or readings to files.
- Shell arguments do not contain credentials.
- Regional login redirects remain under `libreview.io`. HTTP redirects are disabled.
- The client retries authentication once after HTTP 401.
- Rate limits, network failures, and unexpected responses stop the client. There is no automatic retry loop for these failures.
- Terms acceptance requires the official LibreLinkUp app. This client does not accept terms.
- Error output excludes server messages and response bodies.

Terminal recording, screenshots, shell redirection, and backups can still retain output. Hash-based reading identifiers are pseudonymous, not anonymous.

## Troubleshooting

If the API returns status 4, open LibreLinkUp and review the required terms.

If authentication fails, verify the same credentials in LibreLinkUp. The unofficial protocol can also change.

The client uses the reference client's `product: llu.android` and `version: 4.16.0` headers. These identify the cloud protocol, not your LibreLink version.

If readings are absent, verify the accepted sharing connection in LibreLinkUp.

If the newest timestamp is in the future, verify the Mac clock and timestamp interpretation before further work.

Do not share passwords, tokens, patient identifiers, or raw responses when reporting a problem.

## Tests

Run:

```sh
npm test
TZ=Pacific/Honolulu npm test
```

Tests use synthetic readings and mock HTTP responses. They do not log into Abbott or prove live compatibility.

The tests cover regional routing, authentication retry, terms handling, rate limits, response privacy, timestamp parsing, units, and deduplication.

## Research references

- [Abbott: LibreLinkUp sharing setup](https://www.librelinkup.com/articles/getting-started)
- [LibreView Home Assistant integration](https://github.com/PTST/LibreView-HomeAssistant)
- [LibreView Python API reference](https://github.com/PTST/LibreView_Py/blob/main/LibreView/utils/API.py)
- [Nightscout LibreLinkUp uploader](https://github.com/timoschlueter/nightscout-librelink-up)

These repositories provide protocol references, not an official API contract. This prototype has no dependency on their code.

## iPhone app

The SwiftUI app provides manual syncing, Keychain storage, preview validation, and HealthKit duplicate prevention.

Open `ios/LibreHealthBridge.xcodeproj` in Xcode. See [the iPhone guide](ios/README.md) for signing, installation, tests, and limitations.

Real HealthKit behavior requires validation on the signed iPhone build. Version 0.1 has no background syncing or full-history guarantee.
