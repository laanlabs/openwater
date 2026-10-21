# Reddit post

A plain walkthrough, 42 seconds, square: the web cams guide zoomed to South
Florida with a pin opened and its camera playing, then the app fast — map,
runs, downwind runs, upwind VMG and angles, polar, speed and VMG, SUP foil
surf (rides and waves), wing surf (86 waves at Montauk), the wind-wash spot
map, the nearest-first cams list — and a one-line end card.

- `openwater-reddit.mp4` — 1080×1080, the one to upload as a video post
- `openwater-reddit-800.gif` — 800 px, 12 fps
- `openwater-reddit-640.gif` — 640 px, 12 fps

`trailer-style/` holds the earlier cut built on the explainer's look (glow,
captions, dissolves), kept for reference.

## How it was made

Phone segments are real simulator recordings driven by
`make/GifDriveTests.swift` (dropped into `openWaterUITests/` for the run and
removed after) and filmed with `simctl io recordVideo`. The demo library was
seeded with `-openWaterSeedDemoData` and then had `testdata/test-12.openwater`
(SUP foil) and `testdata/test-13.openwater` (wingfoil surf) opened into it. The
website frames in `make/web/` are Claude-in-Chrome screenshots of
openwaterapp.com/spots/cams/united-states--florida, zoomed with synthetic
wheel events over Fort Lauderdale, a pin clicked, and "Play here" pressed.
`make/assemble.py` lays everything out on a flat square canvas with small
labels and hard cuts in `make/plan.json` order, then writes the MP4 and GIFs.
Recordings must be converted to constant frame rate first (`fps=30`): the
simulator writes variable-rate files that go black when seeked into a still
stretch. A flat background plus `paletteuse=diff_mode=rectangle` is what keeps
the GIFs small.
