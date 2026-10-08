#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PROJECT="$ROOT/ios/LibreHealthBridge.xcodeproj"
DERIVED_DATA="$ROOT/ios/.derivedData"
SCHEME=LibreHealthBridge

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 {test|design-review|build|run}" >&2
  exit 2
fi
action=$1

# Open the Simulator app so `run` can launch the built app in a visible device.
open_simulator_app() {
  local developer_dir contents app
  developer_dir=${DEVELOPER_DIR:-$(xcode-select -p)}
  contents=$(cd "$developer_dir/.." && pwd)
  for app in \
    "$developer_dir/Applications/Simulator.app" \
    "$contents/Applications/Simulator.app" \
    "$contents/Applications/DeviceHub.app"; do
    if [[ -d "$app" ]]; then
      open -a "$app"
      return
    fi
  done
  echo "Could not find Simulator.app or DeviceHub.app for Xcode at $developer_dir" >&2
  return 1
}

# Reuse an explicit or already-booted iPhone when possible; otherwise choose a default.
simulator_id() {
  if [[ -n "${SIMULATOR_UDID:-}" ]]; then
    printf '%s\n' "$SIMULATOR_UDID"
    return
  fi
  xcrun simctl list devices available -j | python3 -c '
import json, sys
items = [d for devices in json.load(sys.stdin)["devices"].values() for d in devices if d.get("isAvailable")]
iphones = [d for d in items if d["name"].startswith("iPhone")]
booted = next((d for d in iphones if d.get("state") == "Booted"), None)
preferred = next((d for d in iphones if d["name"] == "iPhone 18 Pro"), None)
selected = booted or preferred or next(iter(iphones), None)
if not selected:
    sys.exit("No available iPhone simulator. Set SIMULATOR_UDID to a simulator UDID.")
print(selected["udid"])
'
}

# Test, review, and run actions need a booted simulator; a plain build does not.
case "$action" in
  test|design-review|run)
    udid=$(simulator_id)
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b
    ;;
esac

case "$action" in
  test)
    # Run the full scheme test suite on the selected simulator.
    xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
      -destination "platform=iOS Simulator,id=$udid" \
      -derivedDataPath "$DERIVED_DATA" \
      CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
    ;;
  design-review)
    # Run UI tests and retain their result bundle for design-review exports.
    result="$DERIVED_DATA/DesignReview.xcresult"
    rm -rf "$result"
    xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
      -destination "platform=iOS Simulator,id=$udid" \
      -derivedDataPath "$DERIVED_DATA" -resultBundlePath "$result" \
      CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
    # Export test-generated review artifacts, then capture the app's current screens.
    bash "$ROOT/ios/DesignReview/export-ui-tests.sh" "$result"
    bash "$ROOT/ios/DesignReview/capture.sh" "$udid" \
      "$DERIVED_DATA/Build/Products/Debug-iphonesimulator/LibreHealthBridge.app"
    ;;
  build)
    # Compile for the simulator without requiring a specific device to be booted.
    xcodebuild build -project "$PROJECT" -scheme "$SCHEME" \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$DERIVED_DATA" \
      CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
    ;;
  run)
    # Build for the selected simulator before installing and launching the app.
    xcodebuild build -project "$PROJECT" -scheme "$SCHEME" \
      -destination "platform=iOS Simulator,id=$udid" \
      -derivedDataPath "$DERIVED_DATA" \
      CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
    app="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/LibreHealthBridge.app"
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")
    open_simulator_app
    xcrun simctl install "$udid" "$app"
    xcrun simctl launch "$udid" "$bundle_id"
    ;;
  *)
    echo "Unknown task: $action (expected test, design-review, build, or run)" >&2
    exit 2
    ;;
esac
