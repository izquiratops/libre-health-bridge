# Simulator screenshots

## Nova tasks

Open this repository in Nova and choose a task from the project task list:

- **iOS Tests** runs the Xcode test scheme on an iPhone simulator.
- **Design Review** runs the tests, exports UI-test attachments, and captures the standard and case screenshots below.
- **iOS Simulator** builds, installs, and launches the app in Simulator.

Tasks select a booted iPhone first, then iPhone 18 Pro, then the first available iPhone. Set `SIMULATOR_UDID` in the task environment to choose another simulator. Build products and the test result bundle are stored under `ios/.derivedData`.

The DEBUG simulator app uses fixed, synthetic fixtures for these screenshots. The fixture does not use a cloud account or HealthKit data.

Run the script with a booted simulator UDID and the built DEBUG simulator `.app` path:

```sh
bash ios/DesignReview/capture.sh SIMULATOR_UDID /path/to/LibreHealthBridge.app
```

The script checks the app executable for the DEBUG fixture flags before it accesses the simulator. Do not use a Release app: without the fixture, the app could access a real account.

The script saves Spanish (`es_ES`) screenshots in `ios/DesignReview/screenshots`. It captures six standard screens and fifteen problem cases in light and dark appearance. The problem cases include missing profiles, missing or stale readings, blocked Health access, stopped sync, and cloud errors. It also captures the ready home screen at the accessibility-extra-extra-extra-large content size. Add `--cases-only` to keep the existing standard screenshots unchanged. The script restores the prior appearance and content size on exit. It does not change the status bar or erase the simulator. Screenshots use the simulator's existing time.

The UI tests attach a screenshot for each problem case and each interaction. Run the tests on a simulator with a DEBUG build. Then export the screenshots from the result bundle:

```sh
bash ios/DesignReview/export-ui-tests.sh /path/to/LibreHealthBridge.xcresult
```

The export script saves English screenshots in `ios/DesignReview/screenshots/ui-tests`. These screenshots include the disabled login button and the logout confirmation. Only use a result bundle from the synthetic UI tests. Do not export screenshots from a real account.

Unit tests cover problems that do not have a screen, such as failed Keychain deletion and cancelled Health writes. The simulator fixtures do not exercise the real cloud, Keychain, or HealthKit. Test a signed build on an iPhone before you rely on Health imports.

Optional: before running the script, set the simulator time to 9:41 yourself with `xcrun simctl status_bar SIMULATOR_UDID override --time '9:41'`. The script does not clear or restore this override; manage it manually.

The app follows the system appearance. The screenshots show synthetic app content, so they are not pixel-identical to the Health references in `design-target-screens`.
