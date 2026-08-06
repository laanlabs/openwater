#!/bin/bash
#
# Archive openWater and upload it to TestFlight.
#
# Everything here is non-interactive, which is the whole point: an upload that
# stops to ask for an Apple ID password cannot be run for you. Authentication is
# an App Store Connect API key — a file on this machine plus two identifiers —
# and the key is never passed on the command line where it would land in shell
# history or a process list.
#
#   Setup (once):
#     1. App Store Connect → Users and Access → Integrations → App Store Connect
#        API → Team Keys → generate a key with the App Manager role.
#        (Developer cannot upload builds; Admin is more than this needs.)
#     2. Download AuthKey_<KEYID>.p8 — Apple lets you download it exactly once.
#     3. mkdir -p ~/.appstoreconnect/private_keys
#        mv ~/Downloads/AuthKey_<KEYID>.p8 ~/.appstoreconnect/private_keys/
#     4. Save the two identifiers next to it:
#        printf 'ASC_KEY_ID=XXXXXXXXXX\nASC_ISSUER_ID=aaaaaaaa-bbbb-...\n' \
#          > ~/.appstoreconnect/openwater.env
#
#   Usage:
#     scripts/testflight.sh            # next build number
#     scripts/testflight.sh 12         # a specific build number
#
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG=~/.appstoreconnect/openwater.env
if [ -f "$CONFIG" ]; then
    # shellcheck disable=SC1090
    set -a; . "$CONFIG"; set +a
fi

: "${ASC_KEY_ID:?Missing ASC_KEY_ID. See the setup notes at the top of this script.}"
: "${ASC_ISSUER_ID:?Missing ASC_ISSUER_ID. See the setup notes at the top of this script.}"

KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8
if [ ! -f "$KEY_PATH" ]; then
    echo "No API key at $KEY_PATH" >&2
    echo "Download AuthKey_${ASC_KEY_ID}.p8 from App Store Connect and put it there." >&2
    exit 1
fi

# Build number: the argument, or one past whatever the project says now.
CURRENT=$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' openWater.xcodeproj/project.pbxproj | grep -o '[0-9]*')
BUILD=${1:-$((CURRENT + 1))}

if [ "$BUILD" != "$CURRENT" ]; then
    echo "==> Build number $CURRENT → $BUILD"
    # Every configuration, so the watch app and the phone app agree. A mismatch
    # is rejected at upload with a message that does not mention build numbers.
    sed -i '' "s/CURRENT_PROJECT_VERSION = ${CURRENT};/CURRENT_PROJECT_VERSION = ${BUILD};/g" \
        openWater.xcodeproj/project.pbxproj
fi

ARCHIVE=$(mktemp -d)/openWater.xcarchive
EXPORT=$(mktemp -d)

echo "==> Archiving"
xcodebuild -project openWater.xcodeproj \
    -scheme openWater \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    archive

# Checked against the built product rather than the source, because the two have
# disagreed before: Xcode silently drops UIBackgroundModes supplied as a build
# setting, and a watch app missing WKBackgroundModes builds and runs and is then
# rejected at upload.
echo "==> Verifying the archive"
python3 - "$ARCHIVE" <<'PY'
import plistlib, sys, pathlib
archive = pathlib.Path(sys.argv[1])
app = archive / "Products/Applications/openWater.app"
phone = plistlib.loads((app / "Info.plist").read_bytes())
watch_plists = list((app / "Watch").glob("*.app/Info.plist"))

problems = []
for key in ("NSLocationWhenInUseUsageDescription",
            "NSLocationAlwaysAndWhenInUseUsageDescription",
            "NSMotionUsageDescription"):
    if not phone.get(key):
        problems.append(f"iOS app is missing {key}")
if "location" not in (phone.get("UIBackgroundModes") or []):
    problems.append("iOS app is missing the location background mode")

if not watch_plists:
    problems.append("no watch app embedded in the archive")
for plist in watch_plists:
    watch = plistlib.loads(plist.read_bytes())
    if "workout-processing" not in (watch.get("WKBackgroundModes") or []):
        problems.append("watch app is missing WKBackgroundModes: workout-processing")
    if "workout-processing" in (watch.get("UIBackgroundModes") or []):
        problems.append("watch app has workout-processing in UIBackgroundModes, which upload rejects")
    if watch.get("CFBundleVersion") != phone.get("CFBundleVersion"):
        problems.append("watch and phone build numbers differ")

if problems:
    print("\n".join("  ✗ " + p for p in problems))
    sys.exit(1)
print(f"  ✓ version {phone.get('CFBundleShortVersionString')} build {phone.get('CFBundleVersion')}")
PY

cat > "$EXPORT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>${OPENWATER_TEAM_ID:-34FWY7G2HB}</string>
  <key>destination</key><string>upload</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

echo "==> Uploading to TestFlight"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$EXPORT/ExportOptions.plist" \
    -exportPath "$EXPORT" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "==> Build $BUILD uploaded. Processing takes a few minutes before it appears in TestFlight."
