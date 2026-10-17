# Continuous integration

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs on pull requests to
`main`, pushes to `main`, and manual dispatches. It has three independent jobs:

- **Format and lint:** SwiftFormat checks whitespace without changing files.
  SwiftLint rejects new warnings and errors.
- **BridgeCore tests:** `swift test` builds and tests the local Swift package.
- **iOS unit and UI tests:** `xcodebuild test` builds the app and runs both test
  targets in the shared `LibreHealthBridge` scheme. The UI tests use synthetic
  simulator scenarios. No cloud credentials, Health data, or signing secrets
  are required. The job uploads the `.xcresult` bundle, including on test failure,
  and retains it for seven days.

CI uses the ARM64 `xcode-27` runner, Xcode 27.0, and an iPhone 17 simulator with iOS 27.0.
Keep these versions compatible with the
[GitHub runner image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
when you update the workflow. Builds and tests also check Swift types.

## Run the same checks locally

Use macOS with full Xcode, an installed iOS simulator runtime, and
[Homebrew](https://brew.sh/) on your `PATH`. Run these commands from the repository root:

```sh
make tools
make format-check
make lint
make test
```

`make tools` runs `brew install swiftformat swiftlint`. The checks use the
Homebrew executables on your `PATH`; no custom installer or GitHub token is needed.
Tool versions follow Homebrew rather than fixed release pins. Use
`swiftformat --version` and `swiftlint version` to inspect your installed versions.

Use `make format` to apply whitespace fixes. Formatting rules are in
[`.swiftformat`](../.swiftformat). They preserve the existing Swift constructs
and use four-space indentation without indenting conditional compilation blocks.

Use `make test-core` or `make test-ios` to run one test job. Local simulator tests
use an iPhone 17 on the latest installed runtime by default. To select a different
simulator, get its UDID from `xcrun simctl list devices available`, then run:

```sh
make test-ios IOS_DESTINATION='platform=iOS Simulator,id=YOUR_SIMULATOR_UDID'
```

Test builds and timestamped result bundles go in the ignored `ios/.derivedData`
directory. Set `RESULT_BUNDLE` to override the bundle path; the path must not
already exist. Open a result bundle in Xcode to inspect failures and screenshots.
CI does not replace testing Health imports on a physical iPhone.

## Existing lint violations

[`.swiftlint.yml`](../.swiftlint.yml) applies the default SwiftLint rules to the
package, app, and tests. The initial 57 violations are recorded in
[`.swiftlint-baseline.json`](../.swiftlint-baseline.json). This keeps the CI change
separate from code refactoring. New violations fail `make lint`, including
warnings. Do not add new violations to the baseline to make CI pass.

When you fix existing violations, update the baseline with SwiftLint:

```sh
swiftlint lint --no-cache --write-baseline .swiftlint-baseline.json
make lint
```

Review the baseline diff to confirm that it only removes resolved violations.
