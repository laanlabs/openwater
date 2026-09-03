# Marketing

App Store submission assets, and the scripts that regenerate them.

Everything here is generated from the real app. The screenshots are captures of
openWater running with a demo session that goes through the *same* analysis
pipeline as a recorded one — every number visible in these images was actually
computed, not mocked up. That matters beyond honesty: when a screen changes,
one command regenerates the whole set rather than leaving stale art behind.

```
Marketing/
├── AppStore-Metadata.txt      Everything App Store Connect asks for
├── capture-screenshots.sh     Drives a simulator, captures raw screens
├── capture-tv-screenshots.sh  The same, for Apple TV
├── build-appstore-assets.sh   Raw captures → every required size
├── Compose.swift              Composes raw screens into marketing panels
└── screenshots/
    ├── raw/                   Straight device captures, no styling
    │   ├── iphone/            1320 x 2868
    │   ├── ipad/              2064 x 2752
    │   ├── watch/              422 x  514
    │   └── appletv/           3840 x 2160
    └── appstore/              ← upload these
        ├── iphone-6.9/        1320 x 2868
        ├── iphone-6.7/        1284 x 2778
        ├── iphone-6.5/        1242 x 2688
        ├── ipad-13/           2064 x 2752
        ├── watch-410x502/      410 x  502
        ├── watch-416x496/      416 x  496
        └── appletv/           3840 x 2160
```

All three iPhone sizes are produced because App Store Connect's required size
depends on which display slot the app record uses, and it rejects anything that
is not an exact match. Upload whichever it asks for.

## Regenerating

Build the app first, then capture and compose:

```bash
xcodebuild -scheme openWater -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/ow-dd build

./Marketing/capture-screenshots.sh <iphone-simulator-udid> Marketing/screenshots/raw/iphone
./Marketing/capture-screenshots.sh <ipad-simulator-udid>   Marketing/screenshots/raw/ipad

./Marketing/build-appstore-assets.sh
```

`xcrun simctl list devices` gives the UDIDs. The last step turns the raw
captures into every required size and verifies the dimensions.

## Apple Watch

The watch screenshots are captures of a **real recording session**, not mocked
data. The simulator was driven along a course with `simctl location`, so the
speeds, splits, distance and flight timer visible on them were all genuinely
computed by the same engine that runs on a wrist:

```bash
xcrun simctl boot <watch-udid>
xcodebuild -scheme "openWater Watch App" -destination "platform=watchOS Simulator,id=<watch-udid>" -derivedDataPath /tmp/ow-watch build
xcrun simctl install <watch-udid> "/tmp/ow-watch/Build/Products/Debug-watchsimulator/openWater Watch App.app"

xcrun simctl location <watch-udid> start --speed=9 \
  37.8450,-122.3400 37.8490,-122.3330 37.8450,-122.3260 37.8410,-122.3330
```

Then launch the app, tap Start, and capture each page with
`xcrun simctl io <watch-udid> screenshot`. Paging needs taps because Water Lock
engages at session start, so this part is not scripted.

Two of the watch captures show simulator limitations rather than app ones, and
are excluded from the marketing set for that reason: the angles page has no
wind set, and the foil page correctly reports "no motion sensor" because a
simulator has no accelerometer. Both behave differently on real hardware.

## How the capture works

Each screen is captured by relaunching the app straight onto it with a
`-openWaterScreen <name>` launch argument, rather than by tapping through the
UI. Two reasons:

- **It is device-independent.** Tap coordinates differ between a phone and a
  13-inch iPad, and break whenever a layout moves.
- **Maps work.** The obvious approach is an XCUITest, but the test runner's
  simulator gets no network for MapKit, so every map renders as a blank
  placeholder grid. Launching onto a screen lets the shots be taken on an
  ordinary booted simulator where the map behaves as it does for a real user.

The launch arguments (`-openWaterScreen`, `-openWaterSeedDemoData`,
`-openWaterResetData`) are inert unless passed; see `ScreenshotRoute.swift`.

The capture script also pins the status bar to 9:41 with full signal and a
charged battery, which is what Apple's own screenshots use.

## Before uploading

`AppStore-Metadata.txt` has a checklist at the end. The items that genuinely
block submission:

- **A privacy policy URL is required**, even though the app collects nothing.
- **The app name must be checked for availability** in App Store Connect.
- **Review contact details and the copyright holder** still need filling in.
