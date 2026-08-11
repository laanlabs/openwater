# Surf: where the forecast falls short, and the plan

The reference for this document is a research guide, ["Building a Free,
Spot-Level Surf and Downwind-Foil Forecast"](https://docs.google.com/document/d/1n5B5748_zgXE0U86OF1j6mytLWwOlG-K/edit),
which reverse-engineers what Surfline's LOTUS system does and maps the part
of it free data can honestly reproduce. Its thesis also fits in one
sentence: a useful free surf forecast is *partitioned* — separate swell
trains, never one significant height — *exposure-aware* — wind and swell
judged against the shore they arrive at, not against each other —
*observation-checked* — buoys measure the split the model guesses — and
*stated as a range with provenance*, never as "3.2 ft" said with a straight
face. What LOTUS adds beyond that — proprietary SWAN nearshore transforms,
surveyed bathymetry, camera machine learning, human forecasters — assumes a
backend, and the guide's own advice to a small team is to reproduce the
scientific pattern, not to claim to reproduce LOTUS.

The app already believes most of this too. The marine model's swell
breakdown is fetched and drawn, the surf screen refuses to render an inland
lake as five days of confident flat, and the strip colours days by what the
wind does to the swell — a fact — rather than scoring them. What follows is
where the surf side falls short of the guide, what to do about it, and in
what order — adapted, like `WIND.md`, to what this app actually is: a
client-side iOS app with no backend, talking to free keyless APIs.

## Where the app stands

What already exists, and is worth protecting:

- **The train decomposition.** `SurfConditions` carries primary swell,
  secondary swell and wind wave as separate trains with height, period and
  direction, plus water temperature and current — the breakdown that
  decides whether it is worth paddling out
  (`openWater/Spots/NearbyConditions.swift`).
- **The multi-day view.** `SurfOutlook` serves four bands a day and the
  hourly series behind them; `SurfForecastScreen` draws surf, wind and tide
  against one axis; `SurfOverviewStrip` gives the fortnight at a glance.
- **Honest absences.** `hasModel` distinguishes "flat" from "no marine
  cell"; the strip's colours are labelled as what the wind does, not how
  good the surf is.
- **Real observations underneath.** NDBC buoys with measured wave height,
  period and direction; NOAA tide predictions; the worldwide model tide
  curve labelled with its datum.

And the structural gaps, in the order they hurt:

1. **One wave model, no error bar.** Every marine call takes Open-Meteo's
   `best_match`. The wind side got a compare screen precisely because one
   forecast line is a number with no error bar; the wave side — where model
   disagreement is often *larger* — has nothing.
2. **Offshore height sold as surf height.** `surfRangeFt` multiplies
   significant height by an undocumented 0.8–1.25 and hard-codes feet,
   ignoring the unit preference the rest of the surf UI respects. The guide's
   rule: never call offshore Hs "surf" without a documented conversion.
3. **Wind judged against the swell, not the shore.** `Band.windEffect`
   classifies offshore/cross/onshore from the angle between wind and swell —
   a proxy that calls a side-shore day offshore whenever the swell happens to
   oppose the wind. The real thing needs one number the app does not have:
   which way the beach faces. (`WIND.md` Tier 3's open "Spot geometry" item
   is this same missing datum.)
4. **Modelled never meets measured.** The buoy's `.spec` file carries the
   *measured* swell/wind-wave split — the observed version of the app's
   modelled trains — and the app never fetches it. No wave analogue of the
   wind nowcast or the model scorecard exists, though the same buoy file
   carries 45 days of wave history for free.
5. **No staleness, and a doubled fetch.** Marine calls use the cache path
   that discards the answer's age, so surf screens can show a stale
   forecast without saying so; the multi-day outlook is fetched once by the
   sheet and again by the screen it opens.
6. **Heights combined wrongly if at all.** Nothing yet adds trains — but
   the moment something does, it must add energies (root-sum-square), never
   heights: 1 m + 1 m = 1.41 m, not 2 m.

## The tiers

### Tier 1 — correctness and honesty

- [x] **`SwellMath` in core.** One documented home for the conversions:
  `SwellTrain` (height, period, direction-from), `combinedHeight` by
  root-sum-square, `energy` as Hs²·Te (a 1 m 15 s swell outworks 1.5 m at
  6 s, and anything weighing trains should know it), energy-weighted
  `dominantDirection`, and `faceHeightRange(offshoreHs:periodS:)` — *the*
  offshore-to-face conversion, a stated heuristic returning a range in
  metres, widened upward for long period. Everything that says "surf
  height" calls this. `Analysis/SwellMath.swift`, unit-tested.
- [x] **Units respected.** `SurfCard` renders the face range in the rider's
  unit like the rest of the surf UI, labelled as an estimate from offshore
  swell — not hard-coded feet presented as a reading.
- [x] **Staleness said out loud.** The marine fetches go through
  `ForecastCache.serve`, and the surf tab and forecast screen carry the
  same "no network — model from N ago" line the outlook card earned in
  `WIND.md` Tier 4.
- [x] **One fetch.** The sheet hands its multi-day outlook to
  `SurfForecastScreen` instead of the screen re-fetching what the sheet
  just loaded.
- [x] **The measured split.** NDBC's `.spec` files carry SwH/SwP/SwD and
  WWH/WWP/WWD — swell and wind wave *measured*, in the same shape the app
  models. A pure parser in core (`Ingest/NDBCSpectral.swift`, tested
  against real rows: cardinal directions, `MM` gaps, buoys with no split at
  all), a fetcher beside `DataBuoyCenter.latest`, and a measured-beside-
  modelled block naming the buoy and its distance — because a buoy in 50 m
  of water is not the spot, and must not be presented as it.

### Tier 2 — multi-model swell

- [x] **`SwellOutlook`.** GFS-Wave, ECMWF WAM, Météo-France MFWAM and DWD
  GWAM side by side from the marine API's `models=` parameter — total
  height, period and direction per model, a blend, a spread over the next
  48 hours (waves move slower than wind; 12 would be too short), and an
  agreement sentence in metres. ECMWF's wave model publishes only total
  sea — no partitions — so the compare runs on totals, and the bands keep
  `best_match`'s partitions rather than mixing partition sets across
  models.
- [x] **The land-cell guard.** A model whose nearest marine cell is dry
  land answers 0.0 every hour, not null — averaged naively, one dry model
  halves the blend. A model that never clears 0.05 m while a sibling
  clears 0.3 m is dropped, and the compare screen says why rather than
  silently showing three lines.
- [x] **Wave model verification.** The same buoy file that verifies the
  wind models carries WVHT and DPD: score each wave model's
  previous-day calls against a buoy within 30 km, with the persistence
  baseline printed beside them — a model that cannot beat "tomorrow =
  today's reading" is not forecasting. Where per-model previous-day series
  are unavailable the scorecard degrades honestly, exactly like the wind
  screen's two flavours.

### Tier 3 — spot geometry

- [x] **`ShoreGeometry` in core.** A water-facing bearing and a swell
  window: `windRelation` says offshore/cross/onshore against the *shore*,
  `exposure` gates a swell train by direction with a cosine taper, widened
  for long period because refraction wraps long swell around corners.
  Pure, tested, and the same datum `WIND.md` Tier 3 wants for hazardous
  offshore sectors.
- [x] **Private spots know their beach.** `PrivateSpot.shoreFacingDeg`,
  optional so old spots still decode, set with a compass control at
  creation or later — never auto-derived silently.
- [x] **Guide spots can learn theirs.** The app reads an optional
  `shoreFacingDeg` from the guide when present. Populating it is a guide
  task, not an app task.
- [x] **`windEffect` prefers the shore.** With a bearing, offshore means
  offshore; without one, the swell-relative proxy stands and the UI says
  which it is using — the proxy must never be mistaken for the real thing.

### Tier 4 — the app's opinion, and the buoy's correction

- [ ] **A rating, labelled as ours.** `SurfRating` in core: 0–5 with every
  point earned or lost stated in words — "1.2 m at 14 s", "12 kn
  offshore", "swell mostly blocked at this facing". Energy after exposure
  sets the base; wind against the shore adds or subtracts; **no shore
  bearing caps the score at 3** and says so, because rating surf without
  knowing which way the beach faces is guessing. Safety is not in the
  score: alerts stay their own red row, a gate rather than a deduction.
  (`OPEN.md` called for exactly this: worth doing, worth labelling as
  ours.)
- [ ] **`SwellNowcast` in core.** The wave version of the wind nowcast,
  multiplicative where the wind's is additive — wave height is a positive
  scalar with proportional error, so the correction is a ratio, clamped to
  [0.5, 2], decaying over six hours rather than three because swell
  evolves slowly. Total height only: matching modelled trains to measured
  trains is an assignment problem the guide warns about, and the measured
  split is often absent.
- [ ] **The buoy sentence.** The nearest wave buoy within 30 km with a
  reading under two hours old corrects the next hours of the blend, said
  the way the wind nowcast says it: "Buoy 46026 read 0.4 m above the model
  25 min ago."

### Tier 5 — US extras

- [ ] **The forecaster's own words.** NWS coastal offices write a Surf Zone
  Forecast — human surf heights and rip current risk — served free from
  the same API the stations and alerts already use. A quoted card, named
  and dated, US coastal offices only, silently absent elsewhere.
- [ ] **The harmonic curve.** CO-OPS serves 6-minute predicted water levels
  from the same datagetter the tide events come from. Where a station sits
  within ~15 km, draw the harmonic prediction instead of the model sea
  level — wholesale, never mixed: the datums differ (MLLW against MSL) and
  the guide's datum-mixing warning is written in exactly this blood.

## What we are deliberately not doing

GRIB ingestion, SWAN runs, bathymetry, transfer matrices, camera vision,
ML calibration: all of it assumes a backend and an ops rota, and the
guide ranks it as its phases 2–4. If a backend ever exists, the guide is
the map. Surfline's own API is proprietary and its terms do not allow
being someone else's upstream — the pattern is reproducible, the data is
not. CDIP's THREDDS/netCDF feeds are impractical client-side, and
unnecessary: CDIP buoys are cross-listed in the NDBC realtime files the
app already reads.

## Licensing

Same note as `WIND.md` Tier 4: Open-Meteo's free tier is non-commercial,
and the marine data is CC-BY — the provenance footers that name it are
load-bearing, not decoration. NDBC, CO-OPS and api.weather.gov are US
government data, free for any use.

## Order of work

1. Tier 1 (done): the math in core, units, staleness, the single fetch,
   the measured split.
2. Tier 2 (done): the model compare, the land-cell guard, buoy-verified
   wave skill with a persistence baseline.
3. Tier 3 (done): shore bearings — core geometry, the private-spot
   compass, the guide field read.
4. Tier 4: the rating with its reasons, and the buoy nowcast.
5. Tier 5: the NWS surf zone card and the harmonic tide curve.
6. With Tier 3's bearings in hand: `WIND.md` Tier 3's hazardous offshore
   sectors — the safety words — become one small step instead of a
   project.
