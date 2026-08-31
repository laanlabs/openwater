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
#     scripts/testflight.sh            # phone and watch, next build number
#     scripts/testflight.sh 12         # phone and watch, a specific build
#     scripts/testflight.sh --tv       # Apple TV
#     scripts/testflight.sh --all 12   # every platform, one build number
#
# The Apple TV app is not in the default, and that is a statement about the
# App Store record rather than about the build: a tvOS upload is rejected until
# tvOS has been added to the app in App Store Connect (the app → Add Platform).
# The rejection does not say so in those words, so it is worth knowing before
# it happens. Once the platform is live, --all is the one to run.
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

# Which platforms. The phone and the watch are one archive — the watch app is
# embedded in the phone's — and the television is its own, because it is its
# own product on its own SDK.
WANT_IOS=yes
WANT_TV=no
case "${1:-}" in
    --ios)  shift ;;
    --tv)   WANT_IOS=no; WANT_TV=yes; shift ;;
    --all)  WANT_TV=yes; shift ;;
    -*)     echo "Unknown option: $1. See the usage notes at the top." >&2; exit 1 ;;
esac

# Build number: the argument, or one past whatever the project says now.
CURRENT=$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' openWater.xcodeproj/project.pbxproj | grep -o '[0-9]*')
BUILD=${1:-$((CURRENT + 1))}

if [ "$BUILD" != "$CURRENT" ]; then
    echo "==> Build number $CURRENT → $BUILD"
    # Every configuration, so the watch app and the phone app agree. A mismatch
    # is rejected at upload with a message that does not mention build numbers.
    #
    # The television is swept up in the same pass, which is what we want: a
    # universal purchase is one product, and two platforms drifting apart by a
    # build number is a thing to notice here rather than in the TestFlight list.
    sed -i '' "s/CURRENT_PROJECT_VERSION = ${CURRENT};/CURRENT_PROJECT_VERSION = ${BUILD};/g" \
        openWater.xcodeproj/project.pbxproj
fi

# The upload, shared. The export options are identical for both platforms —
# the archive knows which SDK it came from — so the only thing that differs is
# which archive is handed over and what to call it on the way past.
upload() {
    local archive=$1 label=$2
    local export_dir
    export_dir=$(mktemp -d)

    cat > "$export_dir/ExportOptions.plist" <<PLIST
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

    echo "==> Uploading $label to TestFlight"
    xcodebuild -exportArchive \
        -archivePath "$archive" \
        -exportOptionsPlist "$export_dir/ExportOptions.plist" \
        -exportPath "$export_dir" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$KEY_PATH" \
        -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_ISSUER_ID"
}

if [ "$WANT_IOS" = yes ]; then
    IOS_ARCHIVE=$(mktemp -d)/openWater.xcarchive

    echo "==> Archiving the phone and watch apps"
    xcodebuild -project openWater.xcodeproj \
        -scheme openWater \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$IOS_ARCHIVE" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$KEY_PATH" \
        -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
        archive

    # Checked against the built product rather than the source, because the two have
    # disagreed before: Xcode silently drops UIBackgroundModes supplied as a build
    # setting, and a watch app missing WKBackgroundModes builds and runs and is then
    # rejected at upload.
    # The test recordings ride along with debug builds so the analysis can be
    # compared against sessions the pages describe. They are bundle resources, and
    # Xcode copies resources in every configuration — the `#if DEBUG` around the
    # seeding code keeps them from being *loaded* in release and does nothing to
    # keep them from being *shipped*. Verified: a release build contained all ten.
    #
    # They are other riders' GPS traces. Stripped here, where the archive is
    # already being opened, and then checked for below so a change to this script
    # cannot quietly stop stripping them.
    echo "==> Removing test recordings from the archive"
    APP="$IOS_ARCHIVE/Products/Applications/openWater.app"
    REMOVED=$(find "$APP" \( -name "*.openwater" -o -name "*.gpx" -o -name "*.fit" \) | wc -l | tr -d ' ')
    find "$APP" \( -name "*.openwater" -o -name "*.gpx" -o -name "*.fit" \) -delete
    echo "    removed $REMOVED"

    echo "==> Verifying the archive"
    python3 - "$IOS_ARCHIVE" <<'PY'
import plistlib, sys, pathlib
archive = pathlib.Path(sys.argv[1])
app = archive / "Products/Applications/openWater.app"
phone = plistlib.loads((app / "Info.plist").read_bytes())
watch_plists = list((app / "Watch").glob("*.app/Info.plist"))

problems = []

# Nothing that looks like somebody's session may leave this machine. The
# stripping above should already have handled it; this is the check that makes
# the stripping trustworthy rather than assumed.
strays = [p for p in archive.rglob("*")
          if p.suffix.lower() in {".openwater", ".gpx", ".fit", ".tcx"}]
if strays:
    problems.append("recordings left in the archive: "
                    + ", ".join(sorted(p.name for p in strays)[:5]))

for key in ("NSLocationWhenInUseUsageDescription",
            "NSLocationAlwaysAndWhenInUseUsageDescription",
            "NSMotionUsageDescription"):
    if not phone.get(key):
        problems.append(f"iOS app is missing {key}")
if "location" not in (phone.get("UIBackgroundModes") or []):
    problems.append("iOS app is missing the location background mode")

# Apple has required a privacy manifest since May 2024 and warns on upload
# without one (ITMS-91053). The warning does not stop a build going out, which
# is exactly why it went unnoticed — so it is checked here, where it costs
# nothing, rather than discovered in App Store Connect after the upload.
if not (app / "PrivacyInfo.xcprivacy").exists():
    problems.append("iOS app is missing PrivacyInfo.xcprivacy")
else:
    manifest = plistlib.loads((app / "PrivacyInfo.xcprivacy").read_bytes())
    used = {entry.get("NSPrivacyAccessedAPIType")
            for entry in manifest.get("NSPrivacyAccessedAPITypes") or []}
    # UserDefaults is the one required-reason API this app touches. If that
    # ever stops being declared, the upload warning comes back.
    if "NSPrivacyAccessedAPICategoryUserDefaults" not in used:
        problems.append("privacy manifest does not declare its UserDefaults use")
    for entry in manifest.get("NSPrivacyAccessedAPITypes") or []:
        if not entry.get("NSPrivacyAccessedAPITypeReasons"):
            problems.append(f"{entry.get('NSPrivacyAccessedAPIType')} has no reason code")

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
    if not (plist.parent / "PrivacyInfo.xcprivacy").exists():
        problems.append("watch app is missing PrivacyInfo.xcprivacy")

# The document types are what let a rider open a track by tapping it. They are
# easy to lose in an Info.plist edit and nothing at build time notices.
if not phone.get("CFBundleDocumentTypes"):
    problems.append("iOS app declares no document types — tapping a GPX will not open it")
if not phone.get("UTExportedTypeDeclarations"):
    problems.append("iOS app does not export the .openwater type")

# Having declared document types, Apple requires the app to say whether it
# opens the original or wants a copy. Omitting it is the "Missing Document
# Configuration" warning on upload — which, like the privacy manifest before
# it, never failed a build and so went unnoticed until the upload dialog.
if "LSSupportsOpeningDocumentsInPlace" not in phone and not phone.get("UISupportsDocumentBrowser"):
    problems.append("iOS app declares document types but neither "
                    "LSSupportsOpeningDocumentsInPlace nor UISupportsDocumentBrowser "
                    "— upload will warn")

if problems:
    print("\n".join("  ✗ " + p for p in problems))
    sys.exit(1)
print(f"  ✓ version {phone.get('CFBundleShortVersionString')} build {phone.get('CFBundleVersion')}")
PY
    upload "$IOS_ARCHIVE" "the phone and watch apps"
fi

if [ "$WANT_TV" = yes ]; then
    TV_ARCHIVE=$(mktemp -d)/openWaterTV.xcarchive

    echo "==> Archiving the Apple TV app"
    xcodebuild -project openWater.xcodeproj \
        -scheme 'openWater TV' \
        -configuration Release \
        -destination 'generic/platform=tvOS' \
        -archivePath "$TV_ARCHIVE" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$KEY_PATH" \
        -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
        archive

    # Nothing to strip here. The television carries no recordings — it has no
    # DevSeed, no sample tracks and no way to make one — so the check below is
    # the whole of it, and it is a check rather than an assumption for the same
    # reason the phone's is.
    echo "==> Verifying the archive"
    python3 - "$TV_ARCHIVE" <<'PY'
import plistlib, sys, pathlib
archive = pathlib.Path(sys.argv[1])
app = archive / "Products/Applications/openWater TV.app"
if not app.exists():
    print("  ✗ no tvOS app in the archive")
    sys.exit(1)
info = plistlib.loads((app / "Info.plist").read_bytes())

problems = []

strays = [p for p in archive.rglob("*")
          if p.suffix.lower() in {".openwater", ".gpx", ".fit", ".tcx"}]
if strays:
    problems.append("recordings in the archive: "
                    + ", ".join(sorted(p.name for p in strays)[:5]))

# The brand assets are the failure this check exists for. An image stack whose
# layers are listed back-first compiles without a word from actool, ships, and
# draws a blank navy rectangle on the home screen; a missing top shelf image is
# rejected at upload instead. Neither is visible at build time.
if not (info.get("CFBundleIcons") or {}).get("CFBundlePrimaryIcon"):
    problems.append("no app icon — check ASSETCATALOG_COMPILER_APPICON_NAME and "
                    "that the brandassets carry an App Icon imagestack")
shelf = info.get("TVTopShelfImage") or {}
if not shelf.get("TVTopShelfPrimaryImage"):
    problems.append("no top shelf image")
if not shelf.get("TVTopShelfPrimaryImageWide"):
    problems.append("no wide top shelf image")

# The same required-reason API as the phone, and the same warning if it goes
# undeclared: this app reads UserDefaults for the rider's favourites.
if not (app / "PrivacyInfo.xcprivacy").exists():
    problems.append("tvOS app is missing PrivacyInfo.xcprivacy")
else:
    manifest = plistlib.loads((app / "PrivacyInfo.xcprivacy").read_bytes())
    used = {entry.get("NSPrivacyAccessedAPIType")
            for entry in manifest.get("NSPrivacyAccessedAPITypes") or []}
    if "NSPrivacyAccessedAPICategoryUserDefaults" not in used:
        problems.append("privacy manifest does not declare its UserDefaults use")
    for entry in manifest.get("NSPrivacyAccessedAPITypes") or []:
        if not entry.get("NSPrivacyAccessedAPITypeReasons"):
            problems.append(f"{entry.get('NSPrivacyAccessedAPIType')} has no reason code")

# A universal purchase is one app record, which means one bundle id shared with
# the phone. Wrong here and the upload arrives as a different product, or as
# nothing at all.
if info.get("CFBundleIdentifier") != "com.laan.labs.openWater":
    problems.append(f"bundle id is {info.get('CFBundleIdentifier')}, not the "
                    "phone's — a universal purchase needs both platforms on one id")

if problems:
    print("\n".join("  ✗ " + p for p in problems))
    sys.exit(1)
print(f"  ✓ version {info.get('CFBundleShortVersionString')} "
      f"build {info.get('CFBundleVersion')}")
PY

    upload "$TV_ARCHIVE" "the Apple TV app"
fi

echo "==> Build $BUILD uploaded. Processing takes a few minutes before it appears in TestFlight."
