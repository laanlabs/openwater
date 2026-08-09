#!/usr/bin/env bash
#
# Re-record the session expectations from everything in testdata/.
#
# Run this after a deliberate analytical change, then read `git diff` on
# openWaterTests/Expectations/ before committing. That diff is the change,
# stated in the numbers a rider actually reads.
#
# The recordings themselves are never committed — see docs/OPEN.md.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${1:-platform=iOS Simulator,name=iPhone 17 Pro}"

# TEST_RUNNER_ prefix: xcodebuild does not forward the shell environment to
# the test process, and strips this prefix on the way in.
TEST_RUNNER_OPENWATER_RECORD_EXPECTATIONS=1 \
xcodebuild test \
  -project openWater.xcodeproj \
  -scheme openWater \
  -destination "$DEVICE" \
  -only-testing:openWaterTests/SessionExpectationTests \
  -parallel-testing-enabled NO \
  -disable-concurrent-destination-testing \
  2>&1 | grep -E "Recorded|error:|TEST (SUCCEEDED|FAILED)"

echo
echo "Now read the diff:  git diff --stat openWaterTests/Expectations/"
