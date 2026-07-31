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
├── Compose.swift              Composes raw screens into marketing panels
└── screenshots/
    ├── raw/                   Straight device captures, no styling
    │   ├── iphone/            1320 x 2868
    │   └── ipad/              2064 x 2752
    └── appstore/              Branded panels with headlines and CTAs
        ├── iphone/            1320 x 2868  ← upload these
        └── ipad/              2064 x 2752  ← and these
```

## Regenerating

Build the app first, then capture and compose:

```bash
xcodebuild -scheme openWater -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/ow-dd build

./Marketing/capture-screenshots.sh <iphone-simulator-udid> Marketing/screenshots/raw/iphone
./Marketing/capture-screenshots.sh <ipad-simulator-udid>   Marketing/screenshots/raw/ipad

swift Marketing/Compose.swift Marketing/screenshots/raw/iphone Marketing/screenshots/appstore/iphone 1320 2868 iphone
swift Marketing/Compose.swift Marketing/screenshots/raw/ipad   Marketing/screenshots/appstore/ipad   2064 2752 ipad
```

`xcrun simctl list devices` gives the UDIDs.

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

- **Deployment target is iOS 26.2**, which excludes nearly every device in use
  today. `OpenWaterCore` already supports iOS 17 / watchOS 10 — lowering the app
  targets to match would reach vastly more riders.
- **A privacy policy URL is required**, even though the app collects nothing.
- **Apple Watch screenshots are not captured.** They need the watchOS simulator
  runtime installed, and are only required if the watch app is listed with its
  own screenshots.
