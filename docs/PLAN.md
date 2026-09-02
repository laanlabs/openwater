# openWater — Implementation Plan

An open-source GPS speed & technique tracker for wind-powered watersports, with a
first-class Apple Watch experience.

Original implementation. No code, assets, or branding are taken from any existing
product; the goal is feature parity on *capability*, not imitation.

Primary sports: **wingfoil, parawing, windsurf, kitesurf, downwind SUP/paddle,
sail, kayak, tow/dock start**.

---

## 0. Guiding principles

1. **Watch is not a companion — it is the recorder.** The watch app runs standalone
   (own `CLLocationManager` + `HKWorkoutSession`), computes live metrics on-device,
   survives wrist-down / water-lock, and syncs a full-fidelity track to the phone.
   The phone is never required to be present or even to exist.
2. **All analysis lives in one pure-Swift package** (`OpenWaterCore`) shared by
   iOS, watchOS and the test suite. No `UIKit`/`SwiftUI`/`CoreLocation` types in
   the analysis layer — it consumes plain value types, so every metric is unit
   testable with synthetic tracks and runs on CI without a simulator.
3. **Doppler speed, not derived speed.** `CLLocation.speed` is Doppler-derived
   from the GNSS carrier and is dramatically more accurate than differentiating
   positions. It is the primary speed source; position-derived speed is only a
   fallback. Every sample carries its accuracy, and accuracy gates every record.
4. **Records must be defensible.** Speed categories follow the published
   GPS-Speedsurfing / GPSTC definitions so numbers are comparable with the wider
   community, and every result carries a validity + confidence flag.
5. **Local-first, no account.** Everything works offline. Sync/social is an
   optional layer added later, never a gate.

---

## 1. Repository layout

```
openWater/
├── OpenWaterCore/                  # local SwiftPackage — all logic, no UI
│   ├── Sources/OpenWaterCore/
│   │   ├── Model/                  # value types
│   │   ├── Ingest/                 # filtering, smoothing, track assembly
│   │   ├── Analysis/               # every metric
│   │   ├── IO/                     # GPX / FIT / CSV / GeoJSON
│   │   └── Records/                # PB tracking
│   └── Tests/OpenWaterCoreTests/
├── openWater/                      # iOS app (SwiftUI + SwiftData)
├── openWater Watch App/            # watchOS app (standalone recorder)
├── openWaterTests/                 # iOS unit tests
├── openWaterUITests/
└── docs/
```

`OpenWaterCore` is a **local** package reference so it builds inside Xcode for
all platforms *and* via `swift test` on the command line (fast iteration, no
simulator boot).

---

## 2. Data model (`OpenWaterCore/Model`)

```swift
struct TrackPoint            // one GNSS fix
  timestamp: Date
  latitude, longitude: Double
  altitude: Double?
  speedMS: Double?           // Doppler, m/s, nil if unavailable
  courseDeg: Double?
  horizontalAccuracy: Double // metres, <0 == invalid
  speedAccuracy: Double?     // m/s, <0 == invalid
  verticalAccelSD: Double?   // CoreMotion, for foil/jump detection
  heartRate: Double?
  cadence: Double?           // pumps or strokes / min

struct Track                 // ordered, cleaned points + derived per-sample arrays
struct Session               // Track + metadata (sport, gear, spot, wind, notes)
struct SessionSummary        // everything computed; Codable, cached in SwiftData
enum  Sport                  // wingfoil, parawing, windsurf, kite, sup, sail, kayak, other
struct Units                 // knots / km-h / mph / m-s, metric / imperial
```

All types `Sendable` + `Codable`.

---

## 3. Ingest pipeline (`OpenWaterCore/Ingest`)

| Stage | Purpose |
|---|---|
| `PointValidator` | drop fixes with `horizontalAccuracy > threshold` (default 10 m), negative speed accuracy, impossible jumps (> 45 m/s), duplicate timestamps |
| `SpeedSource` | prefer Doppler; fall back to Haversine/Δt with a warning flag; record which was used |
| `AdaptiveSmoother` | 1-D Kalman on speed with measurement variance = `speedAccuracy²`; keeps genuine peaks that a moving average would clip |
| `Resampler` | uniform 1 Hz (or native rate) grid + cumulative distance array — every downstream analysis operates on this, so window maths is O(n) |
| `QualityScorer` | per-session 0–100 GPS quality: fix rate, mean accuracy, dropout count, Doppler availability |

---

## 4. Metrics (`OpenWaterCore/Analysis`) — the heart of the app

### 4.1 Time-window bests — `TimeWindowBest`
Sliding-window max of mean speed over a duration. O(n) with the prefix-sum of
distance (`best = max over i,j of (dist[j]-dist[i]) / (t[j]-t[i])` where the
window ≈ target). Standard windows:

`2 s`, `5 s`, `10 s`, `30 s`, `1 min`, `5 min`, `10 min`, `30 min (1800 s)`, `1 hour (3600 s)`

Plus **`5 × 10 s`** — the five best *non-overlapping* 10-second runs, averaged.
This is the core community ranking metric, so it gets a dedicated
non-overlapping-interval selector (greedy by descending speed with overlap
rejection, which is optimal for equal-length windows).

### 4.2 Distance-window bests — `DistanceWindowBest`
Fastest average speed over a *fixed distance*, flying start. Standard:

`100 m`, `250 m`, `500 m`, `1000 m`, `1852 m (nautical mile)`, `5 km`, `10 km`

**The user can add any custom distance** ("max speed over X km") — the engine is
generic over `Measurement<UnitLength>` and results are cached per session, so
adding `2 km` later recomputes from the stored track with no data loss.

Each result yields: speed, start/end index, start/end time, the geometry of the
run for map highlighting, and a validity flag (enough valid fixes, no dropout
inside the window).

### 4.3 Alpha 500 — `AlphaCalculator`
A 500 m run containing at least one gybe/turn whose end point lies within 50 m of
its start point. Implemented as: for each candidate start index, walk forward
accumulating distance to 500 m, then test the start↔end great-circle distance
≤ 50 m and that a heading reversal ≥ 90° occurred inside. Pruned with a spatial
grid so it stays fast on hour-long tracks. Reports best alpha speed + the loop
geometry.

### 4.4 Run segmentation — `RunSegmenter`
Splits the track into **runs** (straight-ish reaches) separated by **transitions**.
A new run starts when smoothed heading deviates > 45° from the run mean and the
deviation persists. Per run: distance, duration, avg/max speed, mean heading,
VMG, on-foil %, start/end position.

This is the backbone for winging: a session becomes a list of runs you can sort
by speed, and the maps highlight your best one.

### 4.5 Wind estimation — `WindEstimator`
No weather API needed — the wind is inferred from your own track:

1. Build a 5°-binned histogram of *distance sailed* per heading.
2. Wing/windsurf tracks are strongly bimodal on each of the upwind and downwind
   sides; the "no-go" sector is the direction with near-zero distance.
3. Estimate wind direction as the circular-mean bisector of the two upwind modes,
   cross-checked against the bisector of the two downwind modes and against the
   direction of minimum achieved speed.
4. Confidence score from mode sharpness and total track coverage.

Manual override always available (and preferred when the user knows the number);
optional later: fetch observed wind for the spot/time.

### 4.6 Polar & angles — `PolarBuilder`
With wind direction known, every sample gets a **True Wind Angle (TWA)**.

- Polar curve: max & 90th-percentile speed per 5° TWA bin, port/starboard split.
- **VMG upwind / downwind**, best and sustained (best 30 s VMG).
- **Tacking angle**: angle between mean port and starboard upwind run headings.
- **Gybing angle**: same downwind.
- Best upwind and best downwind run, with the TWA actually held.
- Port/starboard symmetry score — reveals your weak side.

This is the section that matters most for wing/parawing: the whole sport is
angles, and nobody's app shows them well.

### 4.7 Foiling — `FoilDetector`
Foiling is detected from the combination of sustained speed above a
sport-specific takeoff threshold **and** a collapse in vertical acceleration
variance (on foil the board stops slamming). CoreMotion `verticalAccelSD` is
recorded at 10 Hz on the watch and downsampled into the track.

Outputs: time on foil (abs + %), number of flights, longest flight (time and
distance), mean flight speed, touchdown count, **time-to-first-foil** (how long
your pump-up takes), and takeoff/landing speed.

### 4.8 Maneuvers — `ManeuverDetector`
A maneuver = cumulative heading change ≥ 70° within ≤ 12 s. Classified by the TWA
it passes through: **tack** (through the wind), **gybe** (through downwind),
**carve/turn** (neither).

Per maneuver: entry speed, exit speed, minimum speed, speed loss %, duration,
recovery time (back to 90 % of entry speed), turn radius, turn rate, and — the
one that matters for foiling — **did it stay on foil** ("dry" vs. touchdown).

Scored 0–100 from speed retention + duration + dryness. Aggregates: count,
dry-gybe rate, best/worst gybe, port-vs-starboard breakdown, and a trend chart
across sessions so you can watch your gybe percentage climb.

### 4.9 Jumps — `JumpDetector`
Free-fall signature in vertical acceleration + speed dip + the GNSS altitude
bump. Reports airtime, estimated height (`h = g·t²/8` from hangtime), count,
and best jump. Relevant to kite and wing.

### 4.10 Cadence — `CadenceEstimator` (beta)
Sliding FFT / autocorrelation over the accelerometer magnitude in the 0.5–3 Hz
band → **pump cadence** (wing/parawing/downwind) or **stroke rate** (SUP, kayak).
Reports cadence over time, strokes per run, and distance-per-stroke.

### 4.11 Session-level aggregates
Duration (total & moving), distance, max speed, average speed, moving average,
speed histogram, elevation/tide-free altitude trace, heart rate zones, calories,
GPS quality score.

### 4.12 Personal bests — `Records`
Every category (time-window, distance-window, alpha, VMG, longest flight, dry-gybe
rate, …) tracked all-time / per-year / per-sport / per-gear / per-spot. New PBs
are surfaced immediately after a session and haptically announced live on the
watch the moment they happen.

---

## 5. watchOS app — the critical piece

**Target:** `openWater Watch App`, standalone (`WKWatchOnly` capable), watchOS 26.

### Recording
- `HKWorkoutSession` in `.other` / `.sailing` / `.surfingSports` keeps the app
  alive and running in the background with the screen off — this is the *only*
  reliable way to hold GNSS on watchOS.
- `CLLocationManager` with `desiredAccuracy = .bestForNavigation`,
  `activityType = .otherNavigation`, background location.
- `CMMotionManager` device motion at 10 Hz for foil/jump/cadence.
- **Water Lock** engaged automatically at start (`WKInterfaceDevice.enableWaterLock()`).
- Live metric computation reuses `OpenWaterCore` — the same code that produces the
  post-session numbers produces the live ones, so they can never disagree.
- Crash/battery-death safe: points are appended to an on-disk binary log every
  5 s, so a session is recoverable.

### Live screens (swipeable `TabView`, always-on aware)
1. **Speed** — huge current speed, max, avg, ↑/↓ trend arrow.
2. **Splits** — live 10 s avg, best 10 s, best 500 m, best 2 s, alpha.
3. **Session** — duration, distance, run count, heart rate, calories.
4. **Angles** — current TWA, VMG, heading rose, tacking angle so far.
5. **Foil** — on-foil indicator, current flight time, longest flight, dry-gybe count.
6. **Controls** — pause/resume, lap/run marker, end, water lock.
7. **Race** — sailing start countdown (5-4-1-0) with haptics, plus line-bias helper.

Always-on display gets a low-luminance variant (speed + time only) so battery
lasts a long downwinder.

### Haptics
New PB, run complete, split boundary, countdown ticks, low battery, auto-pause.

### Sync
`WCSession` file transfer of the compressed track + summary the moment the phone
is reachable; the watch keeps its copy until the phone acknowledges. Also writes
the workout to HealthKit (route included) so it shows in Fitness/Activity rings.

### Complications
`WidgetKit` accessory complications: last session max speed, tap-to-start.

---

## 6. iOS app

- **Sessions list** — cards with sport icon, date, spot, max speed, distance,
  duration; filter and sort by any metric; search.
- **Session detail** —
  - Map with speed-gradient track, best-run overlay, alpha loop, maneuver pins,
    scrubbable playback with a synced speed/altitude chart.
  - Metric grid (all of §4) with tap-to-explain and tap-to-locate-on-map.
  - Runs table, maneuvers table, polar chart, wind rose, foil timeline.
- **Records** — PB board across all categories with the session that set each.
- **Trends** — Swift Charts: max speed, dry-gybe %, time on foil, distance,
  VMG per session over time; per sport and per gear.
- **Gear locker** — boards/foils/wings/sails with per-gear stats, so you can
  answer "is the 1100 actually faster than the 980?".
- **Spots** — auto-clustered from session start points, per-spot bests and
  conditions log.
- **Import** — GPX and FIT files (Garmin / Suunto / Coros / Vakaros exports) via
  the document picker and the Share Sheet, plus HealthKit workout routes.
- **Export** — GPX, CSV, GeoJSON, full-fidelity JSON archive, and a shareable
  session image card.
- **Settings** — units (knots default), thresholds per sport, custom distance and
  time windows, accuracy gate, privacy (nothing leaves the device by default).
- **Live phone recording** — the same recorder as the watch for people without one.

---

## 7. File formats (`OpenWaterCore/IO`)

| Format | Direction | Notes |
|---|---|---|
| GPX 1.1 | in + out | with `gpxtpx` extensions for hr/cadence, and speed in a custom namespace |
| TCX | in + out | Garmin's training-centre XML; still the most widely accepted interchange |
| FIT | in | minimal decoder: file header, definition + data messages, `record`/`session`/`lap`; enough for every watch vendor's export. Read-only and kept in its own module — writing FIT means engaging with vendor SDK terms, so it stays out until that is settled |
| CSV | in + out | one row per sample, all channels |
| GeoJSON | out | LineString with per-point properties |
| `.openwater` JSON | in + out | lossless archive incl. summary + settings, for backup and for sharing raw sessions |

The `.openwater` schema is **documented and versioned** in `docs/SCHEMA.md` and is
the contract a future web companion or self-hosted server builds against. Export
is complete by construction: it is the same encoder the app uses to persist, so
it cannot silently drop a channel.

---

## 8. Safety & race features

- **Auto-pause / auto-stop** on prolonged stillness, with resume detection.
- **Session countdown** (race start sequence) with haptics on the watch.
- **Emergency contact** shortcut on the watch controls screen.
- **Battery guard** — reduces sample rate and warns below a configurable level.
- **Live share** (later): opt-in periodic position beacon to a self-hostable
  endpoint; explicitly off by default and never required.

---

## 8a. Making a track readable — the spaghetti problem

An hour of winging in a bay is forty passes through the same water. Drawn as one
speed-coloured line it is a scribble: you cannot see which pass was the fast one,
when you were flying, or where you fell. This is not a colour-ramp problem — the
information is genuinely occluded, because geography puts run 3 on top of run 30.

Four things fix it, and all four are built on the same foundation: **classify
every sample into a `RideState`** (`foiling`, `riding`, `slow`, `stopped`,
`fall`) and derive drawable segments from it.

1. **State-aware map drawing.** Flying segments are drawn bold and opaque;
   riding is thinner; slow and stopped recede to a faint ghost. Consecutive
   segments deliberately share their boundary sample so the line stays
   continuous. One glance tells you which parts of that tangle were flights.
2. **Fall markers.** A **fall** — off the foil *and* stopped — is distinguished
   from a **touchdown**, which you ride straight out of. Falls get a pin on the
   map; touchdowns get a subtle break in the line. "Twelve touchdowns" is a
   normal session; "twelve falls" is a hard one, and conflating them hides the
   thing you most want to track.
3. **Run isolation.** Every segment knows which run it belongs to, so selecting
   run 17 draws it in full colour and drops the other thirty-nine to a ghost
   layer. Stepping through runs one at a time is the single biggest legibility
   win available.
4. **The Ribbon — stop plotting geography.** Each run becomes its own horizontal
   lane, stacked in time order. Nothing overlaps, because time never overlaps.
   Position along a lane is distance, colour is speed, fill is ride state, and
   the connectors between lanes show what joined them — a gybe, a tack, or a
   fall. A session reads top-to-bottom like a score. The map still answers
   *where*; the Ribbon answers *what happened*.

Falls also unlock the metric that tracks real progression in foiling better than
speed ever will: **longest clean streak** — the longest stretch of riding without
going in, in both time and distance — plus falls per hour, mean water-start
recovery time, and distance per fall.

## 8b. Downwind & bump riding — `DownwindAnalyzer`

Downwinding is not just "a long reach", and no tracker measures it properly. The
whole sport is *linking glides*: pump onto a bump, ride the energy, connect to
the next one before you drop. So the metric that matters is not max speed, it is
how much of the run was free.

The signal is a repeating pump-then-glide cycle. Pumping shows up as a strong
periodic component in the 0.5–2 Hz accelerometer band together with flat or
falling speed; a glide is the opposite — quiet accelerometer, speed rising or
held. Segmenting on that transition gives:

- **glide count**, **longest glide** (time and distance), **glide fraction** of
  the run — the headline number;
- **pumps per glide** and **distance per pump** — your efficiency;
- **connection rate**: glides entered without an intervening touchdown, i.e. how
  often you linked rather than restarted;
- **glide entry / exit / peak speed**, and the speed drop between glides;
- **bump period** — the swell interval you were riding, from the autocorrelation
  of the speed trace, which tells you what the ocean was doing.

Parawing gets one extra piece of state: the wing is stowed on the glide and
redeployed to reconnect, so a session has interleaved powered and unpowered
phases. Those are detected from the presence of upwind capability (a parawing
rider under power can hold an angle; a rider gliding cannot) and reported as
**powered vs. glided distance**, which is the number parawing riders actually
argue about.

## 8c. Attitude — heel, pitch, trim

CoreMotion attitude is recorded alongside position on the watch. For sailing it
gives **heel** and **pitch** traces and their correlation with speed. For foiling
it gives **ride height stability** and the pitch oscillation that precedes a
breach, plus **rail-to-rail** transition timing. It is recorded as raw channels
with confidence, never as a claim about the boat's actual attitude, since the
device is on a wrist that moves independently of the hull.

## 8d. Privacy, trust and honesty

Non-negotiable, and specified up front rather than retrofitted:

- **Private by default.** Nothing leaves the device unless the user exports it.
  There is no account and no server in v1.
- **Endpoint masking.** Launch and landing points are the most sensitive data in
  a track — they are usually somebody's home or car. Any share or export offers
  a configurable start/end radius to trim, on by default for sharing.
- **One-tap export and one-tap delete**, both complete.
- **Versioned analytics.** Every `SessionSummary` records the algorithm version
  that produced it, so a number can always be traced to the code that made it and
  a recompute after an algorithm change is explicit rather than silent.
- **Confidence, not certainty.** Detected events (jumps, gybes, flights) carry a
  confidence and are labelled as detections. Raw samples are always retained and
  viewable, and a user can correct or delete a misdetected event.
- **No overclaiming.** A number computed from position-derived speed says so. A
  window containing a GPS dropout is flagged, not quietly averaged over.

## 8e. Live share (post-v1, opt-in)

An expiring link with an explicit recipient action, showing last-update time,
battery and connection state so stale data is obvious — and carrying a plain
statement that it is **not an emergency service and not a rescue system**. This
requires an endpoint, so it ships against a documented, self-hostable adapter
rather than a service we operate.

## 8f. Adapter architecture

Maps, weather, storage and device import each sit behind a protocol in
`OpenWaterCore` with no default network implementation compiled into v1. That
keeps licensing surface at zero for the first release and lets a club swap in
their own tile server or forecast provider without forking session logic.

## 9. Deliberately out of scope for v1

Accounts, cloud sync, global leaderboards, challenges, groups, the social feed,
and spot discovery from other users' data — all of these need a server, and a
server needs an operator. The data model reserves fields for them and the export
format is designed so a community server can be added without migration. v1 is
a complete, private, offline tool.

---

## 10. Build order

| Phase | Contents | Verified by |
|---|---|---|
| **1** | `OpenWaterCore` skeleton, model, ingest, geo maths | `swift test` |
| **2** | Time/distance window bests, alpha, runs, quality | synthetic-track unit tests with known answers |
| **3** | Wind, polar, angles, maneuvers, foil, jumps, cadence | unit tests |
| **4** | GPX + FIT + CSV IO | round-trip tests |
| **5** | Wire package into the Xcode project; iOS session list + detail | builds & runs |
| **6** | **watchOS target**: recorder, live screens, haptics, water lock, WC sync | builds & runs in simulator |
| **7** | HealthKit workout + route, complications | |
| **8** | Records, trends, gear, spots, import/export UI, settings | |
| **9** | Polish: always-on, accessibility, localisation scaffold, docs, LICENSE | |

Phases 1–4 are pure Swift and land first because they are the whole value of the
app and they are testable without ever launching a simulator.

---

## 11. The weather-first Spots page (2026-08-18)

The Spots tab inverted from "directory with weather attached" to
"weather with a directory attached", modeled on Orca's interaction
grammar. What shipped, in dependency order:

1. **Currents data layer** — `CurrentsOutlook.swift`: Open-Meteo hourly
   ocean currents everywhere, swapped wholesale for NOAA CO-OPS
   current-prediction stations within 15 km (the tide screens' two-source
   doctrine, applied to its sibling). Direction convention documented at
   the type: currents point *toward*; wind points *from*. Unit-tested
   against captured wire formats, including the subordinate-station trap
   (`interval=60` answering MAX_SLACK rows).
2. **Centre pin** — `CentrePinReadout.swift`, an overlay (never a map
   annotation) with the wind pill at headline size; the map centre is now
   what "here" means, and dragging the map is the sampling gesture.
3. **Place search** — `PlaceSearch.swift`, `MKLocalSearchCompleter`
   biased to the visible region; a place is a camera move — the centre
   pin samples it — never a navigation push.
4. **The conditions panel** — shipped as `SpotConditionsPanel.swift`
   (Weather / Currents / Tides / Waves / Cams as compact tabs in the
   map-attached sheet) and **removed the same day**: it duplicated
   `NearbyConditionsSheet` ("Conditions here"), which stays the one
   conditions surface. Pins, rows and search picks push the guide page
   again; `HourScrubber.swift` survives it (route editor, Current tab).
   The station-currents layer (item 1) lost its screen for a day; the
   Current tab consumes it now (decided 2026-08-18): a station within
   15 km owns the timeline and a turns-chip row, its rows laid onto the
   field's axis (`CurrentsOutlook.aligned`, tested) so the one scrubber
   drives bars and raster together; the map keeps the model's wash, the
   station stands on it as a named dot, and both captions say whose
   numbers are whose.
5. **Routes** — `RoutePath` (Core, tested), `PlannedRoutes.swift`
   (UserDefaults, the `PrivateSpot` pattern), tap-to-draw editor with
   spot snapping, save sheet with `RouteNamer` prefill.
6. **Route weather** — `RouteWeather.swift`: one wind + one marine
   request per activation (≤12 samples, every ~2 km), scrubbing reads
   memory, an estimated-position marker walks the line, chords recolor
   green/orange/red by degrees off dead-downwind, and the readout carries
   the current's with-you/against-you verdict.

The shuttle planner was absorbed the same day: `RouteHandoff` (the
`ScreenshotRoute.requested` pattern — a static seam plus a notification,
because the Spots page may not exist yet when Tools asks) carries the
Tools→Spots deep link, the row's first tap walks the old
`shuttle.launch`/`shuttle.takeout` endpoints into a saved route exactly
once (a route with the same ends is reused, never duplicated), the
driver's share message lives on as the share button in the route panel,
and `ShuttlePlannerView` is gone. Private-spot pins open the full
conditions sheet directly (no guide page to push), their
`shoreFacingDeg` riding along. One earned lesson is written at the consume site: a map
camera set while the page is hidden or mid-first-layout is quietly
dropped, so the handoff claims its seam immediately and acts a breath
later.

The wind wash followed (2026-08-18, `WindWash.swift`): the flow map's
field on the main Spots map as a remembered toggle. SwiftUI's `Map`
still cannot draw the flow map's geo-registered raster, so the honest
translation is *map content*: the same 7×9 model grid, bilinearly
upsampled by the raster's own walk, stepped through the same
`WindPalette` bands, emitted as a few hundred `MapPolygon` cells with a
feathered alpha edge. Being content is the point — MapKit keeps the
field under every pin and marker, carries it through pan, zoom and
rotation for free, and nothing recomputes per frame; the cells change
only when the field refetches, on the flow map's own drift thresholds,
one hour deep because the main map's wash means *now*. A provenance
chip under the toggle says so. The flow map keeps the scrubber, the
arrows and the smooth raster — the wash here is the glance, that screen
is the study.

The layers menu grew the hardware pins (2026-08-18): Wind stations,
Cameras and Buoys as independent remembered toggles beside the wash,
drawn as small `HardwarePin` circles that never compete with the spot
pins. Stations and cams come from the guide's regional resource cache
(60 km around the map centre, capped at 80); buoys from the NDBC index
(25 nearest). Each pin does what its row in the conditions sheet does —
a cam plays in `CamViewerSheet`, a buoy pushes `BuoyPinScreen` (the
index carries no readings, so the pin fetches the latest on the way
in), a wind station is an outbound link. The refetch key is coarser
than the weather key — ~10 km of panning — because the pins reach tens
of kilometres out.

## 12. openWater on Apple TV (2026-08-31)

The phone is carried to the beach and the watch goes on the water. The
television is for the kitchen at seven in the morning, before anybody
has found their phone, and it answers one question from across the
room: is it on? So the app is three screens — the starred spots with
live wind, a wind map of the coast they sit on, and the cameras — and
records nothing, because an Apple TV goes nowhere.

**The shared package.** Target membership here is folder membership, so
a file cannot belong to two apps; the watch has always shared code with
the phone only through `OpenWaterCore`, and the television follows the
same rule. `OpenWaterSpots` is the second local package: the guide
store, the weather and observation clients, the forecast cache, the
coastline mask and the wind field, with `WindPalette` lifted out of
`FlowMapScreen` and the 7×9 grid out of it into `WindField`. Three
files were split model-from-view on the way — `WindTrack` from its
chart, `PrivateSpot` from its editors, `ForecastModel` from its picker
— because in each case the model is what the television wanted and the
view was iOS's own. The bundled indexes moved with them and are now
read through `Bundle.module`, which is asserted by a test: a miss there
is silent, and looks like a quiet day rather than a broken build.

**The wash renders unchanged.** SwiftUI's `Map`, `MapPolygon` and
`Annotation` are all available on tvOS 17, so the field the phone draws
is the field the television draws, from the same `buildLayout` and
`colourCells`. The map does not pan or zoom — there is no gesture worth
building on a remote, and the frame is the box the rider's own spots
sit in, which is the only coast this app is about. That frees the
D-pad, and left and right go to the hour: the model already holds three
days of it and scrubbing is a re-render rather than a fetch, so the
clock is the thing the big screen finally earns.

**The cameras are the platform limit.** tvOS has neither WebKit nor
SafariServices, and those are the only two ways `CamViewerSheet`
renders a cam, so the phone's whole camera collection does not come
across. Measured against the live guide: of 842 cameras, 52 publish an
HLS playlist and 24 a still image the operator overwrites — about one
in eleven. Surfline's CDN serves its playlists to `AVPlayer`'s own user
agent and 403s a browser's, so those play with no token and no account,
and the 42 stills beside them make the grid real pictures rather than
placeholder cards. `GuideResource` learned `streamUrl` and `stillUrl`
to tell them apart (the resource cache went to v3 for it, or every
device would have answered "no playable cams" for a week).

The rest are not listed. A row that cannot be pressed is worse on a
television than an absent one — there is no long-press, no tooltip,
nothing to explain itself — so the empty state says plainly that most
cams in the guide are web pages and they are on your phone. Widening
this is the website's job, not the app's: every `stillUrl` harvested
into a camera document lights up here for free.

**Favourites are the TV's own.** They are `UserDefaults` on the phone
with no sync behind them, and giving a shipped app an iCloud container
to solve a once-per-household setup is a poor trade. The television
picks its own, drilling country → spot, because there is no map gesture
on a remote and no keyboard worth typing a launch name on.

## 13. The television opens on a map (2026-08-31)

Section 12 built the TV app around the rider's starred spots: the
board first, a wind map framed on the box those stars sit in, and the
cameras near them. It assumed setup — somebody has to star something
before any of the three screens says anything at all — and it assumed
the remote could not drive a map. Both assumptions are now spent.

**The map leads, and it has to know where it is.** The order is the
order the questions get asked: what is the wind doing out there, then
show me it, then the list somebody curated once. That puts the
never-set-up case on the first screen, so the map has to find its own
coast. tvOS gives exactly two calls — `requestWhenInUseAuthorization`
and a one-shot `requestLocation`; no `startUpdatingLocation` exists on
the platform — and what comes back is a coarse network-derived guess.
Which is enough: the question is which stretch of water, not which
launch. When it comes back with nothing, `.searchable` puts the
system's own keyboard up and the rider names a place. `TVLocation`
holds whichever it is, prefers a typed place over a fix (somebody who
typed "Tarifa" is not asking to be shown the living room next launch)
and remembers it, because a television is set up once and watched for
a year. `PlaceSearch` moved from the phone into `OpenWaterSpots` for
this — the same completer, the same debounce, the same resolve.

**The remote can drive a map, in a mode.** The tab bar owns "up", so a
map that listens for the D-pad permanently is a focus trap: the rider
pans north and leaves the screen. So focus sits on a control bar, and
*Pan & zoom* hands the D-pad to a full-screen focusable button until
Menu gives it back — the four keys pan by a third of the view, Select
zooms in, Play/Pause zooms out, and a legend on the glass says so,
because a television cannot be explored. The camera is commanded
rather than gestured: each press computes a new region, believes it
immediately so the next press compounds, and lets `onMapCameraChange`
correct it to whatever MapKit fitted. The hour keeps its clock, now as
two buttons around a label rather than a control that swallows left
and right.

**Everything else the phone's map does, this now does too.** The
comets (`WashParticleLayer`, which only ever needed a `MapProxy`), the
muted basemap under a live wash, the centre crosshairs reading the
wind and the air under the dot, and the guide's own pins carrying
their numbers. The pin cap is twelve against the phone's fifty: a
badge here is four times the size, and twenty-four of them on the East
End came out as one grey ribbon with three legible words in it.

**Every camera is listed now, and the unplayable ones lead to a QR
code.** Section 12 hid the rows a television cannot play, on the
argument that a dead end is worse than an absence. That was right
about the dead end and wrong about the row: the cams a rider knows by
name are mostly YouTube, and a list that silently drops them reads as
a guide that has never heard of the local water. So all of them are
listed — playable first, then by distance — and pressing one this box
cannot play gives its name, its distance and a QR code. The phone in
the room is the browser the television does not have.

YouTube is handed to YouTube's own app rather than decoded here, and
the distinction matters because the first version of this note got it
wrong. Google ships a tvOS YouTube app and it plays these streams
perfectly; what does not exist is a YouTube player a *third party* may
embed. On the phone the sanctioned route is the IFrame player inside a
web view — exactly what `CamViewerSheet` does — and tvOS has no web
view at all, so that route is absent rather than merely awkward.

The remaining route would be to impersonate YouTube's own client
against their private player endpoint and pull an HLS manifest out of
the response. Measured against a live cam in the guide on 2026-08-31:
`hlsManifestUrl` is no longer in the watch page at all, so the old
plain scrape is already dead, and what is left breaks YouTube's terms
and risks a shipped app. So `CamHandoff` offers `youtube://<id>` and
falls back to the https link; the completion handler is the honest
test of whether anything answered, and a failure swaps the button for
a sentence rather than leaving a control that quietly does nothing.
Declaring the scheme in `LSApplicationQueriesSchemes` to pre-empt that
with `canOpenURL` was considered and skipped: it would still be a
guess about a household's installed apps, and the answer is one press
away. What is free and
fair is the poster frame: `previewUrl` falls back to
`img.youtube.com/vi/<id>/hqdefault.jpg`, which arrives 4:3 with bars
that a 16:9 fill crops off almost exactly, so the grid is real
pictures of the actual beaches rather than placeholder cards.
`displayName` also learned to drop leading boilerplate — the guide
files these as "Watch — Youtube — Main Beach — East Hampton", which on
a television card truncates to three identical labels.

**The privacy manifest changed with it.** Coarse location is now
declared, and only coarse: what tvOS hands over is a neighbourhood,
the map rounds to about a kilometre before asking Open-Meteo, and
nothing is stored off the device. A rider who would rather type a
place name than be located gets the same app.

**"Conditions here" is the map's other door.** The centre pill answers
"is it on?" in three characters, which is the whole job at seven in
the morning; the second question — how long does it hold, is anybody
actually measuring it, whose model says so — needed somewhere to go,
and on the phone that is a sheet with five tabs. `ConditionsScreen` is
that reduced to four blocks a room can read: the number now with the
air beside it, the twelve hours after it, the instruments reporting
nearby, and the model picker.

It leads the control bar and takes its default focus, tinted where
every other capsule is grey, because it is the only button on that bar
that is a destination rather than a way of moving the map. The
forecast strip and the measured-stations block are `SpotScreen`'s own,
lifted from private to internal rather than copied — two versions of a
bar chart is how a phone and a television start disagreeing about the
weather. The model picker writes the same `spots.forecastModel`
default the phone's does, so a household that picked ECMWF on the
beach gets ECMWF in the kitchen; picking one forgets every cached
wind and the map behind it re-fetches on keys that now carry the
model, the wash included.

**Getting down off the tab bar.** Reported from a sofa: coming down from
the tab bar, focus "gets lost" rather than landing on the control bar.
Three causes, stacked, and all three had to go.

tvOS resolves a directional move by geometry — it looks for the
focusable item below whatever had focus — so Down from the "Map" tab
item aimed at the middle of the bar, not at "Conditions here" on the
left. `focusSection()` makes the whole bar one target, so Down means
"into the bar"; `focusScope` plus `prefersDefaultFocus` on the first
button says which item that is. `defaultFocus` alone could not: it
applies on appearance, and returning from the tab bar is not one.

Worse, the item the geometry aimed at was a hole. The hour stepper's
back chevron is `disabled` at "Now" — which is where the screen opens
— and a disabled button is not focusable, so the press had nothing to
land on at exactly the coordinates it was aiming for. The chevrons are
now dimmed but never disabled; they clamp, so pressing at the limit is
simply nothing, and the row has no gaps for focus to fall through.

The map is `focusable(false)` for the same class of reason. With no
interaction modes there is nothing to focus it for, and a map that
quietly takes focus is indistinguishable from focus vanishing: nothing
highlights and the next press goes nowhere.

Two layout bugs came out of the same pass. Only the map ignores the
safe area now — a television overscans, and a control bar pinned 50
points off the panel edge is half off the glass in a living room — and
the crosshairs moved inside the map's own frame, because centring them
on the safe-area rect put the dot forty points below the coordinate it
claims to read, the tab bar being taller than the bottom inset.

**Playing YouTube, behind a switch (2026-08-31).** The note above says
YouTube is handed to YouTube's own app. That is still the default, and
now it is only the default: `SettingsScreen` carries one switch that
makes openWater resolve those streams itself.

The correction that got us here is worth keeping. "There is no YouTube
player on tvOS" was wrong twice over — Google ships one, and
SmartTubeIOS shows a third party can build one. What is true is
narrower: there is no *sanctioned* third-party player, because the
sanctioned route everywhere else is the IFrame player in a web view and
tvOS has no web view.

`YouTubeStream` asks InnerTube — YouTube's internal endpoint, the one
their own clients use — presenting a mobile client identifier, and
takes `streamingData.hlsManifestUrl` out of the answer. It works for
live streams only, which costs nothing here because every camera in the
guide is a live stream; the web client's ciphered DASH is a much larger
problem this deliberately does not go near. The four strings that make
up the client identity are named together at the bottom of the file,
because when this stops working they are the first thing to look at,
and the failure is logged with the playability status so that "the cam
went off air" and "the shape we ask in stopped working" can be told
apart.

No code was taken from SmartTubeIOS: it is GPL-3.0, openWater is MIT,
and vendoring it would relicense this app. The request shape is not
copyrightable; their implementation is.

Off by default, and the switch says why: against YouTube's terms,
liable to break without warning, and a camera that fails falls back to
the QR code rather than to an error. That fallback is the reason this
could be added at all — there is no state in which the feature failing
leaves a rider worse off than before it existed.

**Settings is a tab (2026-08-31).** It started as a button at the foot
of the favourites board, which was wrong on a television for a simple
reason: the tab bar *is* the menu. A screen that is not on it is a
screen somebody has to be told about, and a switch nobody can find is a
switch that does not exist. So the app is three screens and a settings
tab, and the doc comment that said "three screens and no more" now says
so.

**When the switch did not work.** Reported immediately: turning it on
played nothing. The structure was fine — the card reads the same
default the switch writes — so the failure was on YouTube's side, and
the first version of `YouTubeStream` could not say which. Two changes
came out of that.

It now asks as four clients in order rather than one: TVHTML5 first,
being what an Apple TV honestly is and the one most likely to be handed
a plain live HLS manifest, then the two mobile clients, then the web —
which also answers live streams with HLS and requires no pretence about
hardware at all. The first that yields a manifest wins.

And a failure is now printed on the hand-off screen rather than only
logged. This matters more than it looks: `LOGIN_REQUIRED` across every
client means YouTube wants attestation and this whole approach is
finished, while "not live" means only that this camera is off air. From
a sofa those are the same nothing. The rule the rest of this app lives
by — never say "not reporting" without asking, and say what you asked —
applies to a video stream exactly as it applies to an anemometer.

**Scrolling on a television (2026-08-31).** Reported against the
conditions screen and true of the spot screen too: the page would not
scroll. The cause is the sharpest difference between the two platforms
and it is easy to write straight past. A tvOS `ScrollView` has no drag.
It moves for exactly one reason — to keep the *focused* view on screen
— so a column of text, bars and readings, none of which is focusable,
does not scroll at all however far past the bottom it runs.

The second half of the bug was worse than nothing happening. Both pages
did have one focusable thing, at the very bottom: the model picker on
one, the camera row on the other. The focus engine found it on
appearance and scrolled straight to it, so a screen opened to answer
"what is the wind doing here" opened already past the number.

`ScrollStop` is the fix — a wrapper that makes a read-only block
focusable, so the D-pad has somewhere to land at each step down the
page and the scroll follows it. Its focus ring is a faint wash rather
than tvOS's card lift, because these are things to read and a block
that jumps under the eye reads as a button that failed. `focusScope`
plus `prefersDefaultFocus` on the first block puts the opening focus on
the headline, which is the same pair the map's control bar needed for
the same underlying reason.

The general rule, now stated once: on this platform, anything a rider
must be able to reach has to be focusable, and anything below the fold
must be reachable by pressing Down from the thing above it.

**The long view (2026-08-31).** The conditions screen answered "what is
it doing now" and stopped there, which is half of what somebody in a
kitchen wants. It now carries a summary line each for the sea and the
tide beside the wind, and three screens behind them — the one thing on
a television that genuinely earns the whole display.

`WindOutlookScreen` draws five days with every model as its own line.
This is the screen a big display is *for*: the phone shows the same
comparison in a card two inches across where six overlapping lines are
a smear, and here they are separable. The average is deliberately not
the headline — it is one heavier line among the others, because the
message is the *spread*. Six lines bundled on Saturday afternoon means
Saturday is close to settled; the same six fanned from eight knots to
twenty-two means nobody knows, and a rider who drives three hours on
that has been misled by a single averaged line that looked just as
certain. Five days and no more: past that the lines are a
weather-shaped random number generator.

`TideDetailScreen` draws the curve rather than a table of times,
because the question is never "when is high water" on its own — it is
"will there be water over the bar when I get there", which is a shape
between two turns. The datum is always stated: NOAA harmonic
predictions are referenced to mean lower low water and the marine model
to mean sea level, the same beach reads about a metre apart between
them, and a curve with no datum invites a comparison that cannot be
made.

`WaveDetailScreen` draws the ground swell against the combined sea, and
the gap between the two lines is the wind wave — which is the fastest
way to tell a clean morning from a blown-out afternoon without reading
a wind number. Every band leads with the period, because four feet at
six seconds and four feet at fourteen are different sports.

`DistanceUnit.heightValue(fromMetres:)` came out of this and now backs
`Format.height` as well, so a chart axis and the caption under it
cannot end up in different units — which is the specific way a wave
chart lies.

**Adding a spot got a search box.** The original screen drilled country
→ spot only, on the stated argument that there is no keyboard worth
typing a launch name on. The map tab's own search had already disproved
that: `searchable` on tvOS puts the system keyboard on the left and the
matches on the right, with dictation for free. So there are three ways
in now — type it, take one of the twelve nearest to wherever the map is
pointed, or browse a country — because those are three different people
looking at the same screen.

**The driving surface was drawing itself.** Entering pan-and-zoom put a
white panel over most of the map. The cause: on tvOS *every* button
style draws a focused appearance, `.plain` included, and this button is
the whole screen. It now uses a style that returns its label and
nothing else, plus `focusEffectDisabled`. The legend is the only thing
that should say the map has the remote.

**Menu had nowhere to go (2026-08-31).** Opening "Conditions here" and
pressing Menu did nothing: the screen would not close and the map did
not come back. The cause is a nesting that looks harmless. A
`NavigationStack` inside a `fullScreenCover` takes the Menu button
because popping is its job — and at the root of the stack there is
nothing to pop, so it consumes the press and does nothing, which is
indistinguishable from the app hanging.

The first fix declined at depth — `onExitCommand(perform:)` with
`dismiss` at the root and `nil` once something was pushed, on the
reasoning that the stack's own pop was right there and claiming the
button would pop twice. That was wrong in the other direction, and
reported within the hour: from a subpage, one press went all the way
back to the map. Declining does not hand the press to the stack; it
hands it to the cover, which dismisses the lot.

So the stack's own Menu handling is not relied on at all. Both screens
answer unconditionally — pop if there is anywhere to pop to, otherwise
close — which is one press, one level, whatever tvOS would have done
with it. The general shape: a `NavigationStack` inside a modal does not
divide the Menu button sensibly with the modal, and the only reliable
answer is to take the whole button.

**Weather got its own screen.** Chance of rain hour by hour on a fixed
0–100 axis — fixed on purpose, because an auto-scaled one makes a day
topping out at 12% look identical to one topping out at 90%, which is
backwards for somebody deciding whether to drive. Temperature is a
second chart under it rather than a second series on the same axis:
share an axis between a percentage and a temperature and one of them is
always a flat line along the bottom.

The numbers are Open-Meteo's `precipitation_probability`, which is what
the phone's own conditions screens already draw. WeatherKit is in the
iOS app but only for recorded-session wind and the minute-rain card;
bringing it to the television would need an entitlement, the capability
on the App ID, and Apple's mandatory attribution — worth doing only if
the household is meant to see Apple's numbers specifically rather than
the two apps agreeing.

**Radar, and the second half of a shared file (2026-08-31).** The
television gets the phone's radar as its own tab, between the cameras
and the favourites — beside the cameras rather than the map on purpose,
because those two answer the same kind of question, what is actually
happening out there, where the map is about what the models think will.

`RadarMap.swift` split rather than moved. The provider layer, the tile
maths and the overlay — including the trick where a zoom-10 request is
served by cropping the deepest real tile, which is what stops
RainViewer's grey "Zoom Level Not Supported" placeholder tiling the
screen — are now `OpenWaterSpots/Radar.swift` and shared. What stayed on
the phone is only its own `MKMapView` wrapper and screen, both of which
turn on `MapStyleOption`, an idea belonging to a settings screen the
television does not have. Each app keeps a small wrapper; neither owns
a second copy of the arithmetic.

`RadarTiles.session` had to go public with it, and the reason is worth
keeping: the prefetch and the drawing must go through one cache or the
warming is wasted, because a loop where each frame starts downloading as
it is shown flashes — a 300 ms step is not long enough to fetch a screen
of tiles.

**It opens where the map tab is.** `TVLocation` now carries the wind
map's settled region, span and all, so radar inherits the zoom rather
than making somebody drive a second map to a coast they already found.

**Scrubbing is Pause and Step.** A slider would want the D-pad, and this
screen has not got it to spare — the same constraint the wind map's
control bar answers a different way. The frame's clock is printed beside
the attribution, because a loop without one lets a two-hour-old sweep
read as current, which is the radar version of the rule the wind pins
already live by.

**Reading the page for the stream (2026-08-31).** Most cameras in the
guide are "web pages" only in the sense that a browser is how their
operator expects you to arrive. Underneath, the page hands its own
player an ordinary URL, and an Apple TV can play that. `WebcamStream`
does the reading a browser would.

This is emphatically not the YouTube case, and the distinction is the
whole reason it needed no switch: nothing here presents itself as
somebody else's client or touches a private endpoint. It fetches the
public page a viewer would get and takes the media URL that page
publishes to its own player — the same thing the guide already does
when it harvests a camera's `stillUrl`.

Four readers, measured against real pages rather than guessed:

- **EarthCam** carries `html5_streamingdomain` and `html5_streampath` in
  a JSON blob; concatenated and unescaped they are a signed HLS playlist
  at 1080p. A page lists every camera at that location and some are off
  air — three of eleven answered 404 on their Times Square page — so the
  candidates are probed and the first live one wins. The probe is a
  ranged GET rather than HEAD, because these CDNs answer HEAD with 405
  while serving the body perfectly well.
- **Any HLS playlist** written into the page.
- **A `<video>` or `<source>` element**, resolved against the page's own
  URL after redirects.
- **A script's clip list.** Montauk Point Lighthouse publishes five
  angles as plain MP4s — `clipUrls = ['northside.mp4', 'rips.mp4', …]` —
  and its page cycles them on `onended`. Those come back as a playlist
  and `ClipLoop` queues them in an `AVQueuePlayer`, refilling when the
  queue drains. Without the refill the picture stops after two minutes
  and reads as a broken camera; the items have been consumed by then, so
  it is a refill and not a seek.

The `<video>` reader has to decline Montauk's own tag, which is built by
`document.writeln` out of string concatenation: `src="'+ clipUrls[0] +
'"` is a fragment of JavaScript, not a URL, and the clip reader is what
that page actually needs.

**Favourites search got its screen back.** It was a `sheet`, which on
tvOS is a narrow centre column — and `searchable` puts a whole keyboard
inside it, so the prompt truncated mid-word, the letters crowded and the
results got a third of a 4K display. Full screen now. The heading also
read "Near Nearby": the same mistake the camera list's empty state made,
fixed the same way, by asking whether the place was actually *chosen*
rather than whether its name is empty.

## 14. Harvesting a camera out of its own page (2026-09-01)

The readers in §13 handed the two cameras that were asked for and were
honest about being two site hacks in a generic coat: one keyed to
EarthCam's brand, one to the literal variable name `clipUrls`. Rewritten
as the shapes underneath, and the pipeline now pools every reader's
results rather than stopping at the first hit — because a page very
often carries more than one camera, and first-wins threw four fifths of
Montauk away.

**The rules.** A split URL (a host under one JSON key, the rest of the
path under another — no single regex for a whole URL can find one of
these, which is why it needs its own rule). Any HLS playlist written
whole. The standard self-declarations: `og:video`,
`twitter:player:stream`, JSON-LD `contentUrl`. A `<video>` or `<source>`
element. And any bracketed array holding two or more media filenames,
whatever it is assigned to — which is Montauk's five angles without
Montauk's variable name in it. Failing all of those, one level of
`<iframe>` is followed, which matters because a great many operator
pages are a thin wrapper around a player hosted elsewhere.

**The pairing rule is the part that took three attempts**, and it is
worth writing down because every version looked reasonable.

Pairing hosts to paths *by index* assumed the two alternate one for one.
EarthCam does not: each camera carries an rtmp `streamingdomain` beside
its `html5_streamingdomain`, so the lists drift and one camera's host
gets welded to another's path.

Pairing by *nearest preceding host* was worse. Measured on their Times
Square page the hosts are eleven `html5_streamingdomain` — the video CDN
— and eleven `imagedomain`, which are picture servers; the paths include
`livepath`, `android_livepath` and `livestreamingpath` beside the
`html5_streampath` that is wanted. Nearest-preceding cheerfully glued
image hosts onto stream paths: sixteen candidates for what turned out to
be five real cameras, most of them confident 404s eating a probe budget
capped at eight.

What actually relates the two halves is the *key family* —
`html5_streampath` belongs to `html5_streamingdomain` — with the
any-host fallback narrowed to pages offering exactly one host, which is
the single-camera case that has nothing to get wrong. Measured after:
eight candidates, all on the right CDN, five live cameras where the
previous rule found two.

**Arrows, because the list is the point.** `CamAnglePlayer` puts left
and right on the angles: Montauk's Northside, Rips, Alamo, Southside and
Frontgate, or every live camera on an EarthCam location page. Labels
come from the filename where the operator gave it one — they name these
after what they point at more often than not — and fall back to a
position where the id is a number.

No `VideoPlayer`, deliberately: tvOS's transport bar eats the D-pad, so
left and right would scrub rather than change camera. The picture is a
bare `AVPlayerLayer` and every key belongs to this screen. Nothing is
lost — there is nothing to scrub on a live camera, and the recorded
clips loop.

**Measured against the guide (2026-09-01).** The readers were run over a
stratified sample of the guide's own cameras — 219 of them, capped at
four per host so no operator was hammered, covering 154 hosts and every
non-YouTube camera in the US set by proportion.

    reachable pages                  201 of 219   (91%)
    yielded a stream, first pass      27          (14% of reachable)
    yielded a stream, after the fix   50          (25% of reachable)
    with more than one stream         10          (these get arrows)

**The fix was one line's worth of idea and it nearly doubled the rate.**
A great many pages write their media URL inside JavaScript, where the
slashes are escaped — and a regex that matches a URL cannot contain a
backslash and still be matching a URL, so every one of those was
invisible. Unescaping the document once, up front, before any reader
sees it, turned on njbeachcams, thesurfersview, 48half, angelcam,
nybeachcams and several one-offs: 23 cameras across nine hosts, none of
which needed a rule of its own. Angelcam also escapes the hyphens in its
own hostname as `-`, which is why the unescaper decodes `\uXXXX`
generally rather than the one sequence it used to.

**Guide-wide that projects to about 91 cameras**, 14% of the
non-YouTube set — lower than the sample's 25% because the sample caps
per host and the guide does not. The projection is dominated by
njbeachcams alone (35, all of which now work).

**Where the rest is, in order of size:**

- **Surfline, 294.** Blocks the fetch outright. Not a loss: the ones
  publishing HLS already carry `streamUrl` in the registry, which is
  how the fifty-odd playable cams got there.
- **ipcamlive, 56** across two hosts. Their player page exposes an
  `alias`, a `streamid` and an `address`, so the shape is right there —
  but the obvious `{address}streams/{streamid}/stream.m3u8` returns 404,
  and a guess is not worth shipping. Worth an hour with their player.
- **FAA weathercams, 37.** A JavaScript app with no media hooks in the
  HTML at all; there is an API behind it. These are stills rather than
  streams, so they would land as `stillUrl`.
- **Ozolio, 23**; **Nest, 10** (needs an account, so no); **rtsp.me, 3**
  (RTSP, which `AVPlayer` cannot play in any case).

The honest read: the generic readers have taken the cameras that publish
their URL somewhere a reader can see it, and what is left is three
platforms with their own APIs. That is a per-platform job, and the right
place for it is the website's harvester writing `streamUrl` into the
registry — where the phone gets it too — rather than the television
re-deriving it on every press.

## 15. What a television gets wrong in a living room (2026-09-01)

Five things, all found by running the app on an actual Apple TV through
TestFlight rather than in a simulator. Every one of them was invisible
on a desk.

**The theme was only ever dark by accident.** The set was in Light
appearance and half the app went unreadable: `.primary` resolves to
black, so the camera hand-off drew black text on the black ground it
paints, and `.thinMaterial` came up pale under white map chrome, which
left the control bar looking empty. This design is dark by construction,
so the app now says so once — `preferredColorScheme(.dark)` at the root
— and every screen that paints its own black ground also states
`.foregroundStyle(.white)`, so `.secondary` and `.tertiary` resolve
against white rather than against the system's idea of the day.

**A modal is not automatically opaque.** A `fullScreenCover` presents
over what is already there and a tvOS `List` paints no background of its
own, so the place search arrived as a keyboard and a column of names
floating directly on the wind map — reported, accurately, as "the whole
screen is jumbled" — and the favourites editor did the same over its own
board. Both now sit on black. A search screen is not chrome over a map;
it is a screen.

**Panning was jumping.** One press moved a third of the view, which on a
television means the coast you were reading leaves the screen and
finding it again takes two presses back and a guess. A twelfth now, so a
held key slides and four or five presses cross a bay.

**Reset and locate earned buttons.** Zooming in four times and wanting
the coastline back is not the same wish as wanting to leave the coast
altogether, so they are two glyphs rather than one: the first restores
the opening span without moving the centre, the second gives the fix its
say back and returns there. Glyphs, because the bar already carries four
words and a clock.

**The map shows instruments now, not spots.** A starred launch wearing a
*model* number is the same forecast the wash beneath it is already
drawing, said twice — and the second saying looks like a measurement,
which is the one thing `WIND_MAP_RULES` is most insistent it must not
be. The pins are anemometers: `FreeStations` around the view, R1 applied
without exception, so an instrument that is silent or stale gets no pin
rather than a pin wearing the model's guess. The badge is deliberately
unlike the wash it sits on — white on hard black rather than another
capsule tinted from the same ramp — because a rider glancing at this map
has to tell "the model says" from "a mast at the end of that jetty says"
without reading a word. Twelve of them: eighteen wrote over each other
wherever the instruments genuinely cluster.

**Radar opened flickering, and it was the phone's bug all over again
(2026-09-01).** It started playing, so each frame began downloading as
it was shown — and four hundred milliseconds is nowhere near long enough
to fetch a screenful of tiles, so the map blinked between a drawn frame
and a half-empty one. The phone had already solved this with a preload;
the television shipped without one.

Two changes, and the first matters more. It now opens **paused on the
newest observation** — `frames` runs past → nowcast, so index 0 is two
hours ago, which is not what "is it raining" means. That is the question
this tab is actually opened for, and it is one frame, not thirteen. The
loop answers the *second* question — is it coming here — so it is a
button, and pressing it warms every frame's tiles through
`RadarTiles.session` first, counting up on the button's own label, then
starts.

**And the tiles were half the resolution they could be.** Both providers
render at 256 or 512 at the same paths, and a 256-pixel tile on a 4K
television is drawn at roughly twice its own resolution — the blockiness
reported from a living room. Asking for 512 is real detail rather than
an upscale: WMS renders the same bounding box at whatever size it is
given, and RainViewer publishes both. The crop path in `loadTile` now
reads the overlay's own `tileSize` instead of a literal 256, because
those two drifting apart is exactly how a cropped tile comes back at
half resolution. Both apps get it.

**Meters wear a different material now.** The centre readout, the
weather pill and the instruments were three black capsules with white
edges saying three different kinds of thing. The dot in the middle is
the *model* where you are looking; the pins are instruments elsewhere
that measured something. Same grammar, different material: steel blue
with a cool edge against the readout's flat black, so which is which is
visible from a sofa without reading either.

Their names are off by default, behind a button on the bar. The numbers
are the answer and the names are a lookup — and where instruments
cluster, three airports around East Hampton, the name chips are wider
than the capsules they belong to and write over each other.

**And the chance of rain moved to the conditions hub.** `SpotWeather`
carries a code and a temperature and no probability at all, so the hub
now fetches `WeatherDetail` for one number. "Will it rain on me" is the
second question anybody asks after "is it windy" — too important to be a
press away. The hour nearest now rather than the day's maximum, because
a forty per cent afternoon and a forty per cent chance right now are
different facts and this screen is about right now.

**Options, and the flash that was not a download (2026-09-01).**

The map's bar had grown to eight things, two of which were layer
switches. Those moved into a panel above it — rows rather than more
capsules, because a switch has to say what it is *and* what it currently
is, and a capsule carrying both ends up reading "Wind on", which is a
command half the time and a state the other half. The state is a word at
the end of the row: from three metres a checkmark is a smudge and a tint
is a guess about whether that colour means anything. The panel is its
own focus scope, so it has its own idea of which row Down lands on
rather than arguing with the bar's.

**The radar flash had two causes and the first fix only found one.**
Preloading the tiles was right and did not cure it, because the gap was
never a download. Each frame *removed the old overlay and added a new
one*, and the map is bare for however long MapKit takes to draw the
replacement — that gap is the flash.

Every frame now goes on the map at once and the loop moves an alpha:
thirteen `MKTileOverlay`s, one visible at `0.75` and the rest at zero,
switched by writing `alpha` on renderers held from the moment MapKit
makes them (it makes them lazily and never hands them back, so the only
way to have one later is to keep it). No add, no remove, nothing to
redraw from scratch — the picture cross-fades. The overlay set is
rebuilt only when the *set* changes, which is the layer switch, not the
frame.

Measured in the simulator rather than assumed: six screenshots through a
running loop, whole-screen mean brightness 69.22 on every one, while the
frame clock in the caption changed between them. A blanking frame shows
as a brightness dip, and there were none.

**The radar stutter, third time, and this one was measured (2026-09-01).**

Two earlier fixes each addressed something real and neither cured it.
Warming the tiles through `URLSession` was right about caching and wrong
about what was slow. Laying every frame on the map and switching by
alpha was right about the blanking — a removed overlay leaves the map
bare — and still stuttered.

So it was instrumented rather than reasoned about: a counter in
`loadTile`, a counter around the PNG encoder, and a log stream through a
running loop. What came back:

    tile requests   752, all inside the first 1.3 seconds
    PNG encodes     713, spread over the next ten
    requests during the loop itself   0

MapKit asks for every overlay's tiles the moment they are added — alpha
zero does not stop it — so the network was never the problem, and the
warm step had been solving a problem that did not exist. What costs is
what happens next: MapKit requests **zoom 8** while RainViewer publishes
to 7, so every tile takes the crop path — decode a 512-pixel PNG, cut a
quadrant, redraw it, encode a new PNG. And `MKTileOverlayRenderer`
discards its rendered tiles for an overlay it is not currently drawing,
so each pass round the loop did all of it again.

The fix is a cache of finished tiles on `RadarTileOverlay`, keyed by
frame and tile, bounded by count and bytes. The preload now goes through
`loadTile` rather than the URL session, so it performs exactly the work
the renderer will ask for and leaves the answer where the renderer will
look — playing becomes a dictionary lookup. It warms at
`lastRequestedZoom`, recorded from MapKit rather than derived: the
obvious arithmetic gives 7 for the view that was measured asking for 8,
and a preload at the wrong zoom warms nothing at all.

**The loop, finally, is overlay-per-frame (2026-09-01).** Three
approaches failed before this one and each failed for a MapKit reason
worth keeping.

*Swap one overlay for another* blanked the map for the length of a
download. *Preload the tiles* fixed the download but not the blank,
because the blank was a re-encode: above RainViewer's zoom every tile is
cropped and re-encoded, and the renderer discards that for an overlay it
is not drawing. *Hide thirteen overlays behind `alpha`* stopped the
blank and then made the sweep vanish on the second pass — MapKit does
not restore a renderer's content when its alpha returns from zero.
*Mutate one overlay's source and `reloadData()`* left the picture
frozen: MapKit caches a rendered tile by its z/x/y path, the path does
not change between frames, so it returns the bitmap it already has.
Measured frozen — 0.000 pixel change frame to frame.

What works is the plain thing the download gap originally argued
against: a distinct overlay per frame, the wanted one added before the
previous is removed. A distinct overlay has a distinct path identity, so
its tiles are genuinely its own and MapKit draws them; and the crop
cache — the one piece that survived every rewrite — makes `loadTile`
answer instantly, so there is no gap to blank. The overlays are built
once each and kept, cleared only when the layer set changes.

Diagnosed and verified by diffing the map's own pixels rather than its
brightness, which was the mistake that passed the frozen build: fourteen
frames, 8–26 per-frame change where the frozen build was 0.000, and the
low-brightness frames confirmed by eye to be real thin-rain scans rather
than blanks.

**Alpha was the wrong lever (2026-09-01).** The thirteen-overlays
design played its first pass and then the sweep vanished — a bare map
with the clock still ticking, reported from a living room and
reproduced in the simulator: twenty-six screenshots at a flat 71.3 mean
brightness with no radar in any of them. MapKit does not undertake to
bring a renderer's content back when its alpha returns from zero, and
it does not.

So the loop is one overlay that changes what it serves.
`RadarTileOverlay` holds its source behind a lock — `loadTile` runs off
the main thread and the frame is changed from it — and `show(_:)` swaps
it; the coordinator then calls `reloadData()`, which is the documented
way to tell a tile overlay its content has changed. The overlay itself
is replaced only when the *provider* changes, never for a frame, so the
map is never without one.

This is only affordable because of the crop cache: `reloadData()` costs
a redraw, and the redraw is a dictionary lookup rather than several
hundred PNG encodes. The three fixes are one fix — the cache is what
makes a redraw cheap enough to do thirteen times a loop.

Verified the same way it was diagnosed: thirty screenshots across
several cycles, brightness 87.55–87.61 throughout against the broken
build's 71.3, and rain on screen in every one.

**The jump was a synchronous remove, and the bar was a wall (2026-09-01).**

Reported still jumpy on the television and the simulator both: a frame
took about a second to appear. The cause was one line — the loop added
the new overlay and then, on the very next statement, removed the old
one, before the new overlay's renderer had drawn a single tile. So the
old frame vanished and the map waited, bare, for the new one to paint.
The pixel-diffing that "passed" this earlier had sampled settled frames
and never caught the gap between them.

Now the frames dissolve. The old overlay is held at full strength while
the new one fades up from zero on top of it — a thirty-hertz alpha ramp
over the two renderers — and the old one is removed only once the new is
all the way in. There is never a moment with nothing drawn. It depends
on the crop cache: a dissolve holds the old frame for less than half a
second, so the new frame has to be *drawn* within that window, which
means its tiles have to be warm. So the whole loop is warmed on entry
now, not on the first press of Play — which also makes Step instant.
Verified by capturing a running loop: brightness steady with no dip to
the bare-map value, and the clock advancing frame to frame.

And the control bar stopped being six things at once. Play, Step and the
loop shared a row with a coverage toggle and four NOAA products — most
of it about *what* to draw rather than whether it is playing. The
overlay choices moved behind **More options**, which opens a second bar
— ‹ Back, Global loop, and the four NOAA stills — that Menu also backs
out of. The bar a rider meets is now three buttons.


**The dissolve was wrong; a clean cut is right (2026-09-01).** Cross-
fading two translucent radar layers blends both frames at once, which
reads as mud — it looked worse than the jump it replaced. Reverted to a
hard cut, which is how a radar loop is meant to move. The one rule that
survives is no bare gap: the new frame is added opaque on top and the
old one is removed a fifth of a second later, never in the same breath,
so the old frame is only taken down once the new one has painted. The
warm-on-entry cache is what keeps that paint within the window.
Measured across fifty rapid captures of a running loop: brightness
varied only with real frame content (79–100, the lows being genuine
thin-rain scans), with no blank and no periodic darkening pulse.

**Radar is a flat image now, not a tile overlay (2026-09-01).** Every
attempt to animate `MKTileOverlay`s — swap, cross-fade, mutate,
delayed-remove — flickered, because MapKit re-composites a tile
overlay's whole geometry whenever it changes and does it on its own
clock. A loop cannot be smooth on top of that.

So each frame is rendered *once* into a single map-sized `UIImage`,
geo-registered by asking the map where each tile's corner coordinates
land, and the loop is a `UIImageView` swapping its `image` — a pointer
assignment the GPU draws in one frame. No tiling, no re-composite, no
flicker. The map is fixed while looping, so one alignment holds for
every frame; a change of place or zoom rebuilds the set, off a signature
of the frames and the exact rectangle. Two details earned their
comments: the tiles are computed from the map's *actual* region, which
MapKit widens to fit 16:9 — the requested region left the ocean side of
the map bare — and the frames render at point scale rather than the
screen's, because a 4K bitmap per frame is a lot of memory for a coarse
picture. Measured across forty captures of a running loop: brightness a
flat 75–79 with no dip, frames advancing with content, no blank.

The bar's dead "Play loop" is gone too. On a NOAA still there is no loop
to play, so the main bar names the layer — "NOAA · Rain" — beside More
options rather than offering a greyed-out Play, which is the state a
rider hit by choosing a product and pressing Back.

## 16. Memory and performance on the device (2026-09-01)

Hangs reported on real Apple TV hardware, which has far less memory
headroom than the simulator forgives. An audit of the television target
found the radar the culprit and fixed it, and confirmed the rest.

**The radar held tens of megabytes for the life of the app.** A
`TabView` keeps every tab alive, and the radar's coordinator kept a
rendered image per frame — thirteen full-1080p bitmaps, over a hundred
megabytes — whether or not the tab was on screen. Now the tab carries an
`isActive`, like the wind map's wash: leaving it cancels the build,
drops the images and stops the loop; returning rebuilds. The frames also
render at half resolution now — radar is coarse and stretched over the
whole map, so full resolution bought nothing and cost four times the
memory — which brings the working set from ~108 MB to ~27 MB.

**The frame compositing moved off the main thread.** Thirteen
full-screen draws on the main actor was a visible hitch on entry; the
render is `nonisolated` now, so the tile decode and drawing happen off
the main thread and only the finished image returns to it.

**The shared caches were sized for a phone.** The crop cache dropped
from 96 to 40 MB and the tile URL cache from 32 to 16 MB in memory — a
whole radar loop is only a few megabytes of compressed tile data, so
these were ceilings far above the working size, crowding the map and the
images for no gain.

Confirmed already sound: the wind map sleeps its wash and stops its
particle animation when the tab is left; every camera player pauses and
releases its `AVPlayer` on disappear; the loop is a cancellable task and
the build task is cancelled on `deinit`; no timers are left running.

What a device-side Instruments pass would still be worth checking: the
wash's 60-hertz particle canvas is real GPU work on the map tab, gated
to when it is active but not otherwise throttled for the television.

**A window into the box (2026-09-01).** A television has no console in
the room, so a hang leaves nothing to read. `DebugHUD` is a bug button
in the corner that opens three live figures: the app's memory footprint
(what jetsam measures), the available memory before the system starts
reclaiming (the early warning for a pressure hang, device-only — the
simulator reports nothing), and the frame rate (which separates "out of
room" from "working too hard"). The display-link meter runs only while
the panel is open, so it costs nothing the rest of the time. It is the
instrument for turning "it went slow" into a number.


## 17. The phone reads the page for a stream too (2026-09-02)

The stream finder was the television's, because the television had no
browser to fall back on. The phone does — it opened every non-YouTube
cam in an in-app Safari — but a site like EarthCam or Montauk Point
Lighthouse carries several cameras a viewer would want to flick between,
and a web page gives no way to do that. So `WebcamStream` moved into
`OpenWaterSpots` and the phone now reads the same page for the same
streams.

`CamViewerSheet` keeps its two ends unchanged — YouTube in the embedded
IFrame player, an unharvestable page in Safari — and puts the finder
between them: a brief read, then a native `AVPlayer` with chevrons and a
swipe to step through a site's cameras, or Safari if nothing playable
turned up. Verified on the phone against EarthCam's Times Square page:
seventeen live feeds resolved and cycling. The multi-camera experience
the television grew is now the phone's as well, off one shared reader.

**The pin is a place now, not a readout (2026-09-02).** The crosshairs
told you the wind under them and forgot the moment you panned away,
while the cameras tab went on listing whatever coast the box had guessed
at. A pin button on the bar keeps the point instead: it writes through
`TVLocation.choose`, which is the same store a typed place uses — so it
survives a relaunch, the search button wears its name, and the cameras
re-find themselves around it, because that tab already keys on
`location.here`. Named after the guide's nearest launch when one is
within ten kilometres, so it reads "Napeague" rather than a pair of
decimals. Setting it does not re-frame the map: the point is already on
screen, and re-centring would throw away the zoom the rider just chose —
every *other* way the place changes still moves the camera, because
those are somewhere new.

**The current gets a screen (2026-09-02).** Wind is the question this app
opens with, but on a tidal coast the current decides whether a crossing
is a glide or an afternoon of going nowhere — and unlike wind it is
invisible from the beach, so a picture of it earns its place on a
television more than almost anything.

`CurrentFlowScreen` is the phone's flow map on the television's terms:
the same `WindWashModel` asked for `.currents` instead of `.wind`, so it
is the same field, the same quads and the same comets — and for water
the comets are not decoration, because a still arrow states a direction
while a moving one states a rate. It sits on the conditions report as a
fifth row, and only where there is water that runs: an empty current
screen on an inland point would be a row promising something it cannot
show.

Two honesties carried over from the phone. The arrows do not flip: a
current states *toward*, and the wind habit of adding 180° would reverse
every river. And the source is named rather than blended — a NOAA
station replaces the model wholesale, because they are different physics
with different answers.

One thing the phone did not have to solve: a *subordinate* NOAA station
publishes only the turns and no hourly curve at all, so `now` is nil and
the headline came up blank. It now leads with the next turn instead —
"Next: Max flood 1.4 kn" — and says plainly that this station predicts
turns rather than a rate.
