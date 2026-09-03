#!/bin/bash
#
# Capture Apple TV App Store screenshots at native resolution.
#
# Each screen is captured by relaunching the app straight onto it via the
# -openWaterTVScreen launch argument. On the phone that approach is a
# convenience; here it is the only option. A tvOS simulator cannot be sent a
# remote press from this machine at all — `simctl` has no injection, and
# synthesized key events are refused — so any screen more than one press from
# the launch tab is otherwise unreachable and unphotographable.
#
# A tvOS capture is 3840 x 2160, which is one of the two sizes App Store
# Connect accepts for Apple TV (the other being 1920 x 1080). They are uploaded
# as captured; there is no device frame to compose and no status bar to fix,
# because a television has neither.
#
# Usage: Marketing/capture-tv-screenshots.sh <simulator-udid> <output-dir>

set -euo pipefail

UDID="${1:?usage: capture-tv-screenshots.sh <simulator-udid> <output-dir>}"
OUT="${2:?usage: capture-tv-screenshots.sh <simulator-udid> <output-dir>}"
BUNDLE="com.laan.labs.openWater"

# Ask Xcode where the build products are rather than hard-coding DerivedData.
# The phone script learned this the hard way: a stale path silently captured a
# months-old build, because installing an old app is not an error.
if [[ -n "${APP_PATH:-}" ]]; then
    APP="$APP_PATH"
else
    PRODUCTS=$(xcodebuild -scheme "openWater TV" \
        -destination "platform=tvOS Simulator,id=$UDID" \
        -configuration Debug -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
    APP="$PRODUCTS/openWater TV.app"
fi

if [[ ! -d "$APP" ]]; then
    echo "No app at $APP — build the \"openWater TV\" scheme first, or set APP_PATH." >&2
    exit 1
fi
echo "Using $APP"

mkdir -p "$OUT"

echo "Booting $UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
sleep 3

if [[ -n "${SKIP_INSTALL:-}" ]]; then
    echo "Reusing the installed app (SKIP_INSTALL)"
else
    xcrun simctl install "$UDID" "$APP"
fi

# A known board, rather than whatever this simulator happens to hold.
#
# The favourites screen photographs saved spots, so without this it captures
# the debris of whatever was last tested on this device — during development
# that was two identical pins named "Montauk, NY" left over from a bug being
# chased. The ids are real launches from the guide along the coast the app
# opens on, so the shot is representative rather than staged: the wind beside
# each one is fetched live at capture time like any other.
#
# Written into the app container's own plist, not with `simctl spawn defaults`.
# That command writes a domain the sandboxed app does not read — it reads back
# perfectly and changes nothing the app sees, which is a silent failure worth
# naming. And the app is terminated first, because a live process holds its
# defaults in memory and flushes them on the way out, overwriting the setup.
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
sleep 2
PREFS="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)/Library/Preferences/$BUNDLE.plist"
# Edited with plistlib rather than `plutil -replace`, which reads a dot in a
# key path as nesting — every one of these keys contains dots, so plutil looks
# for a "favorites" inside a "spotGuide" that does not exist and fails.
PREFS="$PREFS" python3 <<'SEED'
import os, plistlib, json
path = os.environ["PREFS"]
try:
    with open(path, "rb") as f:
        prefs = plistlib.load(f)
except FileNotFoundError:
    prefs = {}
prefs["spotGuide.favorites"] = ["FS-1036", "FS-1041", "FS-1040", "FS-0821", "FS-0490"]
prefs.pop("spotGuide.privateSpots", None)
prefs["tv.place"] = json.dumps({"name": "Montauk, NY",
                                "latitude": 41.0362,
                                "longitude": -71.9545}).encode()
prefs["tv.map.wind"] = True
prefs["tv.debug.hud"] = False
prefs["tv.cams.map"] = False
with open(path, "wb") as f:
    plistlib.dump(prefs, f)
print(f"Seeded {path}")
SEED

# Every shot is a cold launch. The app holds its place, its wash and its
# forecast in memory, so relaunching is what guarantees each screen is captured
# in the state a rider actually meets it in rather than one warmed by the shot
# before it.
shot() {
    local name="$1" screen="$2" settle="$3"
    echo "  $name ($screen, ${settle}s)"
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    xcrun simctl launch "$UDID" "$BUNDLE" -openWaterTVScreen "$screen" >/dev/null
    # Tiles, the wind field and the charts all arrive over the network. The
    # waits are per screen rather than one generous number for all of them —
    # see `TVScreenshotRoute.settleSeconds`, which these mirror.
    sleep "$settle"
    xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null 2>&1
}

echo "Capturing into $OUT"
# Ordered as they should be uploaded: the map is what the app is for, the
# report is what it knows, and the cameras are why somebody leaves it on.
shot "01-map"           map          26
shot "02-conditions"    conditions   30
shot "03-outlook"       windOutlook  30
shot "04-cameras"       cameras      20
shot "05-cameras-map"   camerasMap   20
shot "06-radar"         radar        26
shot "07-favourites"    favorites    12

xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true

echo
echo "Captured:"
for f in "$OUT"/*.png; do
    printf "  %-28s %s\n" "$(basename "$f")" \
        "$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}')"
done
