#!/usr/bin/env bash
#
# Fill openWater/DevSeed/ from testdata/, so debug builds carry the test set.
#
#   scripts/sync-dev-seed.sh [simulator-udid]
#
# Writes each recording as a titled .openwater archive — an archive carries
# its own title and sport, so the sessions arrive named test-1 to test-10 and
# match the pages in openWaterTests/Expectations/.
#
# Re-run after adding or changing anything in testdata/. Nothing it writes is
# ever committed; see openWater/DevSeed/README.md.
set -euo pipefail
cd "$(dirname "$0")/.."

UDID="${1:-}"
if [ -z "$UDID" ]; then
  UDID=$(xcrun simctl list devices available | grep -m1 "iPhone 1[0-9] Pro (" \
         | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
fi
[ -n "$UDID" ] || { echo "No simulator found; pass a udid"; exit 1; }

OUT="$PWD/openWater/DevSeed"
mkdir -p "$OUT"
rm -f "$OUT"/*.openwater

TEST_RUNNER_OPENWATER_ARCHIVE_OUT="$OUT" \
xcodebuild test \
  -project openWater.xcodeproj -scheme openWater \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:openWaterTests/SessionExpectationTests/testWriteTitledArchives \
  -parallel-testing-enabled NO -disable-concurrent-destination-testing \
  2>&1 | grep -E "^wrote |error:|TEST (SUCCEEDED|FAILED)"

echo
echo "DevSeed now holds:"
ls -1 "$OUT" | grep -v README || echo "  (nothing — is testdata/ empty?)"
