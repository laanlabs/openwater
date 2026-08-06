#!/bin/bash
#
# Capture App Store screenshots at native resolution.
#
# Each screen is captured by relaunching the app straight onto it via the
# -openWaterScreen launch argument, rather than by driving the UI tap by tap.
# That makes the capture independent of device size and layout, and — the reason
# it exists — lets the shots be taken on a normal booted simulator instead of
# the test runner's, where MapKit gets no network and every map renders blank.
#
# Usage: Marketing/capture-screenshots.sh <simulator-udid> <output-dir>

set -euo pipefail

UDID="${1:?usage: capture-screenshots.sh <simulator-udid> <output-dir>}"
OUT="${2:?usage: capture-screenshots.sh <simulator-udid> <output-dir>}"
BUNDLE="com.laan.labs.openWater"

# Ask Xcode where the current build products are rather than hard-coding a
# DerivedData path. The hard-coded one went stale and this script silently
# captured a months-old build — screenshots of a tab that no longer existed,
# with no error anywhere, because installing an old app is not a failure.
if [[ -n "${APP_PATH:-}" ]]; then
    APP="$APP_PATH"
else
    PRODUCTS=$(xcodebuild -scheme openWater \
        -destination "platform=iOS Simulator,id=$UDID" \
        -configuration Debug -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
    APP="$PRODUCTS/openWater.app"
fi

if [[ ! -d "$APP" ]]; then
    echo "No app at $APP — build the openWater scheme first, or set APP_PATH." >&2
    exit 1
fi
echo "Using $APP"

mkdir -p "$OUT"

echo "Booting $UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
sleep 3

# A fixed status bar: a real clock and battery percentage make a screenshot look
# like a holiday snap rather than a product shot, and Apple's own screenshots
# all use 9:41.
xcrun simctl status_bar "$UDID" override \
    --time "9:41" \
    --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 \
    --dataNetwork wifi --wifiMode active --wifiBars 3 >/dev/null 2>&1 || true

# A fresh install clears the location grant with it, and `simctl privacy` has
# no working switch for location — so the first launch raises the permission
# alert and it lands on top of whichever screen was being photographed. Grant
# it once by hand, then re-run with SKIP_INSTALL=1 to keep that grant.
if [[ -n "${SKIP_INSTALL:-}" ]]; then
    echo "Reusing the installed app (SKIP_INSTALL)"
else
    echo "Installing"
    xcrun simctl uninstall "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    xcrun simctl install "$UDID" "$APP"
fi

# Seed once, then reuse the store for every subsequent launch so the analysis
# is not recomputed eight times.
echo "Seeding demo data"
xcrun simctl launch "$UDID" "$BUNDLE" -openWaterResetData -openWaterSeedDemoData >/dev/null
sleep 12
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true

shoot() {
    local name="$1" screen="$2" settle="${3:-6}"
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    sleep 1
    xcrun simctl launch "$UDID" "$BUNDLE" -openWaterScreen "$screen" >/dev/null
    # Map tiles arrive over the network and charts animate in; a screenshot
    # taken too early shows a placeholder grid or a half-drawn chart.
    sleep "$settle"
    xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null 2>&1
    echo "  $name"
}

echo "Capturing to $OUT"
shoot 01-sessions   sessions      4
shoot 02-map        map          10
shoot 03-runs       runs          5
shoot 04-analysis   analysis      6
shoot 05-playback   playback     10
shoot 06-fullmap    fullScreenMap 10
shoot 07-spots      spots        10
shoot 08-tools      tools         4
shoot 09-record     record        8

xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true
echo "Done."
