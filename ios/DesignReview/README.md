# Simulator screenshots

The DEBUG simulator app uses fixed, synthetic fixtures for these screenshots. The fixture does not use a cloud account or HealthKit data.

Run the script with a booted simulator UDID and the built DEBUG simulator `.app` path:

```sh
bash ios/DesignReview/capture.sh SIMULATOR_UDID /path/to/LibreHealthBridge.app
```

The script checks the app executable for the DEBUG fixture flags before it accesses the simulator. Do not use a Release app: without the fixture, the app could access a real account.

The script saves Spanish (`es_ES`) screenshots in `ios/DesignReview/screenshots`. It captures seven screens in system light and dark appearance. It also captures the ready home screen at the accessibility-extra-extra-extra-large content size. The script restores the prior appearance and content size on exit. It does not change the status bar or erase the simulator. Screenshots use the simulator's existing time.

Optional: before running the script, set the simulator time to 9:41 yourself with `xcrun simctl status_bar SIMULATOR_UDID override --time '9:41'`. The script does not clear or restore this override; manage it manually.

The app follows the system appearance. The screenshots show synthetic app content, so they are not pixel-identical to the Health references in `design-target-screens`.
