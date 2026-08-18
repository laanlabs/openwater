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
   biased to the visible region; a place is a camera move plus a panel
   selection, never a navigation push.
4. **The conditions panel** — `SpotConditionsPanel.swift` +
   `HourScrubber.swift`: Weather / Currents / Tides / Waves / Cams as
   compact tabs in the map-attached sheet, one shared hour cursor, value
   rows at the cursor, provenance footers everywhere.
   `NearbyConditionsSheet` survives whole as "More detail".
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
and `ShuttlePlannerView` is gone. Private-spot pins joined the panel
selection flow at the same time, their `shoreFacingDeg` riding along to
the full sheet. One earned lesson is written at the consume site: a map
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
