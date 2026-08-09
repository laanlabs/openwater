#!/usr/bin/env bash
#
# Put the whole test set on a simulator, named test-1 to test-10.
#
#   scripts/load-simulator.sh <simulator-udid>
#
# Wipes the app's existing sessions first, so the set on the device is
# exactly the set in testdata/ and nothing is there twice. Everything it
# installs is rebuilt from testdata/, so this is repeatable.
set -euo pipefail
cd "$(dirname "$0")/.."

UDID="${1:?usage: load-simulator.sh <simulator-udid>}"
BUNDLE="com.laan.labs.openWater"
OUT="$(mktemp -d)"

echo "==> Building titled archives from testdata/"
TEST_RUNNER_OPENWATER_ARCHIVE_OUT="$OUT" \
xcodebuild test \
  -project openWater.xcodeproj -scheme openWater \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:openWaterTests/SessionExpectationTests/testWriteTitledArchives \
  -parallel-testing-enabled NO -disable-concurrent-destination-testing \
  2>&1 | grep -E "^wrote |error:|TEST (SUCCEEDED|FAILED)"

echo "==> Clearing the app so the set is not doubled"
xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true

APP=$(find ~/Library/Developer/Xcode/DerivedData/openWater-*/Build/Products/Debug-iphonesimulator \
      -maxdepth 1 -name "openWater.app" | head -1)
xcrun simctl install "$UDID" "$APP"

echo "==> Importing"
xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
for n in $(seq 1 10); do
  f="$OUT/test-$n.openwater"
  [ -f "$f" ] || { echo "   missing $f"; continue; }
  xcrun simctl openurl "$UDID" "file://$f"
  echo "   test-$n"
done

echo
echo "Done. Archives were built in $OUT"
