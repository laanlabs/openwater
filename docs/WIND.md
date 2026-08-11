# Wind: where the forecast falls short, and the plan

The reference for this document is a developer guide, ["Wind Forecasting for
Wind Sports"](https://docs.google.com/document/d/1fwrP3CANVY4rodGdr7iFh4r-ZKdAXn1Q/edit),
whose thesis fits in one sentence: the most accurate practical wind forecast
built from free data is not one weather model — it is a multi-model,
observation-corrected, spot-specific, *probabilistic* forecast. The guide
lays that out as five layers: several models ingested side by side, blended
as vectors rather than as speeds-and-compass-points, corrected per spot from
observations, nudged by fresh station readings in the first hours, and
finally presented as a range with a confidence — never as "18.3 kn" said
with a straight face.

The app already believes most of this. The model-compare screen exists
precisely because one forecast line is a number with no error bar. What
follows is where the app falls short of the guide, what to do about it, and
in what order — adapted to what this app actually is: a client-side iOS app
with no backend, talking to free keyless APIs, whose unfair advantage is
that its users record GPS tracks at the exact places the forecast is trying
to describe.

## Where the app stands

What already exists, and is worth protecting:

- **Multi-model outlook.** `WindOutlook` fetches ECMWF, GFS, ICON and GEM
  side by side from Open-Meteo, with per-model hourly speeds, gusts and
  directions, a blend, a spread number and an agreement sentence
  (`openWater/Spots/NearbyConditions.swift`).
- **Real observations.** NWS stations, NWS alerts, NOAA tide predictions and
  NDBC buoys are all wired up (US-only, silently absent elsewhere).
- **Historical lookup.** `OpenMeteo.historical` fetches the hourly wind and
  swell for a past session's window and offers it on the wind dial — never
  auto-applied, because the rider was there and the model was not.
- **An honest wind estimator.** `WindEstimator` infers direction from track
  shape, refuses to invent a speed, and caps its own confidence.

And the structural gaps, in the order they hurt:

1. **One scalar wind per session.** `Wind` carries a single `directionFrom`
   for a session that can run three hours and twenty kilometres through a
   sea-breeze onset. The estimator's own comment names the failure: tidy
   reciprocals sailed in a thirty-degree shift score beautifully around a
   direction that was never true for more than a few minutes. Worse, the
   historical fetch *has* the hourly series and averages it away.
2. **Speed and direction averaged separately.** The guide's most emphatic
   correctness rule is to do wind arithmetic on the u/v components. The
   historical lookup took an unweighted circular mean of directions next to
   an arithmetic mean of speeds — so a 2 kn northerly counted as hard as a
   20 kn southerly when deciding which way the day blew.
3. **Gusts never reach the analysis.** Fetched in five different requests,
   modelled in four app-side structs, absent from `Wind`. The difference
   between steady 18 and 10–30 cycling is the difference between a session
   and a swim, and the analysis cannot see it.
4. **No probabilities.** Four deterministic models are a spread, not a
   distribution — their errors are correlated, so their disagreement
   understates the real uncertainty. Open-Meteo serves actual ensemble
   members (GEFS 31, ECMWF ENS 51) for nothing.
5. **Observations and forecasts never meet.** A buoy reading 4 kn above the
   blend an hour before launch is the single most useful correction there
   is, and the app shows both numbers without ever subtracting them.
6. **Nothing learns.** No record is kept of what was forecast against what a
   station — or the rider's own track — later showed, so the app can never
   answer "which model is right *here*, in a westerly".

## The tiers

### Tier 1 — correctness and plumbing

- [x] **`WindTimeline` in OpenWaterCore.** Wind over time as u/v vector
  samples with optional gusts: interpolation done in components (never
  across compass degrees), speed-weighted vector averaging over an
  interval, and a collapse back to the scalar `Wind` for everything that
  still wants one number. `Analysis/WindTimeline.swift`.
- [x] **Gust on `Wind`.** Optional, m/s, never inferred — same contract as
  speed.
- [x] **`Session.windTimeline`.** The model's hour-by-hour account of the
  session, stored *alongside* the rider's own call, never instead of it.
  Optional in storage so old archives still decode.
- [x] **Vector math fixed at the source.** `OpenMeteo.historical` builds a
  timeline and derives its summary from the mean vector (so direction is
  speed-weighted), and fetches gusts while it is there.
  `WindOutlook.blendDirections` weights each model's unit vector by its
  speed.
- [x] **The dial keeps the day.** Looking up a past session's conditions now
  hands the fetched timeline through to the session when the rider saves,
  so the hourly record survives instead of dying in a label.

Deliberately *not* done yet: feeding the timeline into the analyzers.
`ManeuverDetector`, `UpwindLegFinder`, `DownwindAnalyzer` and `SessionShape`
still read the one scalar. Evaluating wind at the moment of each maneuver is
the payoff of the timeline, but it changes every derived number, which means
an `analysisVersion` bump and a re-record of the expectation suite with
rider sign-off — see `docs/RUNS.md`. That lands as its own change.

### Tier 2 — what Open-Meteo will already do for us

- [x] **Real ensembles.** The [Ensemble API](https://open-meteo.com/en/docs/ensemble-api)
  serves GEFS members per hour. From members: P10/P50/P90 and
  P(speed ≥ threshold) — the numbers that turn "models roughly agree" into
  "seven in ten chance of fifteen knots at four". Fetched by
  `OpenMeteo.ensemble` and shown in the model-compare readout.
- [x] **NBM for US spots.** NOAA's [National Blend of Models](https://vlab.noaa.gov/web/mdl/nbm-documentation)
  is a statistically corrected blend of dozens of models and observations —
  an excellent benchmark line. Served by Open-Meteo as `ncep_nbm_conus`;
  null outside CONUS, so it simply does not appear elsewhere. Marked
  composite and left out of the app's own blend by default: averaging a
  blend with its own ingredients double-counts them.
- [x] **15-minute near-term.** `minutely_15` is native HRRR for North
  America (with gusts) and ICON-D2/AROME for central Europe. The
  conditions sheet's "next six hours" card asks those three models
  explicitly and does not exist anywhere else — no interpolated hourly
  data dressed up as quarter-hour precision. `OpenMeteo.nearTerm`.
- [ ] **Lead-time skill without an archive.** The
  [Previous Runs API](https://open-meteo.com/en/docs/previous-runs-api)
  exposes what each model said 1–7 days ahead of a given hour; the
  [Historical Forecast API](https://open-meteo.com/en/docs/historical-forecast-api)
  keeps the as-issued forecasts. Together they answer "how wrong is GFS at
  this spot at two days out" with API calls alone.

### Tier 3 — the app's unfair advantage

- [x] **Nowcast arithmetic in core.** `WindNowcast`: take the freshest
  quality station or buoy reading, subtract the model at that moment (in
  components), and decay the difference over lead time —
  `exp(-lead/tau)`, tau defaulting to three hours. Pure math, unit-tested.
- [x] **Nowcast in the UI.** The outlook card now carries one measured
  sentence: the nearest fresh station or buoy against the blend, with the
  corrected next hours when they disagree — `NowcastAdjustment`. Stations
  correct as vectors; a buoy has no wind vane, so it borrows the model's
  direction and corrects the strength alone.
- [ ] **Sessions as observations.** The estimator already extracts wind
  direction from track shape at the exact riding area. Keep small per-spot
  records — forecast u/v against session-estimated u/v by wind sector and
  lead — and maintain the guide's exponentially weighted bias correction.
  A few floats per spot/sector bucket, entirely on-device. This is the
  guide's "largest early accuracy gain", and no weather site can copy it.
- [ ] **Spot geometry.** A water-facing bearing and safe/hazardous sectors
  per spot turn a forecast direction into "cross-on" or "straight
  offshore" — the safety words — and the shuttle planner should sample the
  wind *along the route at transit time*, not at one point now.

### Tier 4 — hygiene the guide insists on

- [ ] **Modeled is not observed.** Open-Meteo "current" values are model
  output. Anywhere a current number is shown, say which it is, and how old.
  Stations and buoys are observations; the forecast endpoints never are.
- [x] **Cache the forecasts.** `ForecastCache`: every Open-Meteo request
  (and the astronomical tide table) now reads from a short-TTL disk cache
  keyed by the request URL, and a failed fetch serves an answer up to
  three hours old rather than a blank. Observations are deliberately not
  cached — a reading's whole value is being minutes old. Still to do:
  surface the age when a stale answer is served.
- [ ] **Distinguish failures.** Every fetcher collapses network failure,
  rate-limiting and "inland, no marine cell" into the same empty return.
  They are three different sentences to a rider.
- [ ] **One historical-wind path.** WeatherKit (`WeatherLookup`) and
  Open-Meteo both produce a session wind through unrelated code with
  contradictory confidences. Pick one canonical path with provenance.
- [ ] **Licensing is configuration.** Open-Meteo's free tier is
  non-commercial; distribution beyond personal use needs the paid tier or
  self-hosting. WeatherKit is the commercial-safe fallback and the
  entitlement already exists. Keep source identities and terms in one
  place, not scattered through call sites.

## What we are deliberately not doing

GRIB ingestion, MADIS, neural post-processing, WRF nests: all of it assumes
a backend and an ops rota, and the guide itself ranks it last. If a backend
ever exists, the guide's phase 3–4 is the map. One date to watch: NOAA's
RRFS becomes operational in late 2026 and replaces NAM/HREF/SREF — but HRRR
itself survives until RRFS v2 (~2027–28). Model names belong in
configuration, not in logic.

## Order of work

1. Tier 1 (done): the timeline type, the vector fixes, gusts, storage.
2. Tier 2 ensembles + NBM + minutely_15 (done); previous-runs skill next.
3. Nowcast UI and forecast caching (done).
4. Analyzer integration of the timeline — behind an `analysisVersion` bump
   with a full expectation re-record, per `docs/RUNS.md`.
5. Per-spot bias records once there is a place to show what they learned;
   spot geometry and route sampling alongside.
6. Remaining Tier 4 hygiene: stale/data-age labels, error surfaces, the
   one historical-wind path, the licence registry.
