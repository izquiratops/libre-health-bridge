#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 || ( $# -eq 3 && "$3" != --cases-only ) ]]; then
  echo "Usage: $0 SIMULATOR_UDID DEBUG_SIMULATOR_APP [--cases-only]" >&2
  exit 2
fi
udid=$1
app=$2
if [[ ! -d "$app" || ! -f "$app/Info.plist" ]]; then
  echo "Expected a built DEBUG simulator .app with Info.plist: $app" >&2
  exit 2
fi
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")
if [[ -z "$bundle_id" ]]; then
  echo "Missing CFBundleIdentifier in $app/Info.plist" >&2
  exit 2
fi
if ! /usr/libexec/PlistBuddy -c 'Print CFBundleSupportedPlatforms' "$app/Info.plist" | awk '
  /^[[:space:]]*iPhoneSimulator[[:space:]]*$/ { found = 1 }
  END { exit !found }
'; then
  echo "Expected an iPhoneSimulator app: $app" >&2
  exit 2
fi
executable=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Info.plist")
if [[ -z "$executable" || ! -f "$app/$executable" ]]; then
  echo "Missing app executable: $app" >&2
  exit 2
fi
fixture_binaries=("$app/$executable")
if [[ -f "$app/$executable.debug.dylib" ]]; then
  fixture_binaries+=("$app/$executable.debug.dylib")
fi
if ! strings "${fixture_binaries[@]}" | awk '
  index($0, "--ui-scenario") { scenario = 1 }
  index($0, "--ui-screen") { screen = 1 }
  END { exit !(scenario && screen) }
'; then
  echo "Expected a DEBUG fixture app with --ui-scenario and --ui-screen: $app" >&2
  exit 2
fi

# Record settings before changing the simulator.
appearance=$(xcrun simctl ui "$udid" appearance)
content_size=$(xcrun simctl ui "$udid" content_size)
if [[ "$appearance" != light && "$appearance" != dark ]] ||
   [[ "$content_size" == unknown || "$content_size" == unsupported ]]; then
  echo "Cannot preserve this simulator's appearance or content size." >&2
  exit 1
fi
restore() {
  local result=$?
  trap - EXIT
  # Continue restoration even if one simulator command fails.
  xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
  xcrun simctl ui "$udid" appearance "$appearance" || result=1
  xcrun simctl ui "$udid" content_size "$content_size" || result=1
  exit "$result"
}
trap restore EXIT

output_dir=$(cd "$(dirname "$0")" && pwd)/screenshots
mkdir -p "$output_dir"
xcrun simctl install "$udid" "$app"
xcrun simctl ui "$udid" content_size large

capture() {
  local scenario=$1 screen=$2 name=$3
  xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
  xcrun simctl launch "$udid" "$bundle_id" \
    -AppleLanguages '(es)' -AppleLocale es_ES \
    --ui-scenario "$scenario" --ui-screen "$screen" >/dev/null
  sleep 4
  xcrun simctl io "$udid" screenshot "$output_dir/$name.png"
}

for style in light dark; do
  xcrun simctl ui "$udid" appearance "$style"
  if [[ ${3:-} != --cases-only ]]; then
    capture ready home "home-ready-$style"
    capture signed-out home "home-signed-out-$style"
    capture ready information "information-ready-$style"
    capture signed-out login "login-signed-out-$style"
    capture setup setup "setup-setup-$style"
    capture error home "error-home-$style"
  fi
  # Every failure uses synthetic credentials/readings; never launch the real cloud client.
  for scenario in no-profiles missing-profile no-reading stale-reading permission-denied health-unavailable paused; do
    capture "$scenario" setup "case-$scenario-setup-$style"
  done
  capture paused home "case-paused-home-$style"
  for scenario in terms-required rate-limited wrong-patient invalid-credentials invalid-response secure-storage health-save; do
    capture "$scenario" home "case-$scenario-home-$style"
  done
done

if [[ ${3:-} != --cases-only ]]; then
  xcrun simctl ui "$udid" appearance light
  xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large
  capture ready home home-ready-accessibility-extra-extra-extra-large
fi
