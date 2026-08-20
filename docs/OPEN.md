# Open work

Written 10 August 2026; reconciled 19 August against the nine days of
commits since, and again the day the app went public. Analysis version 15,
with 325 core tests and 74 app tests passing — both suites run today, one
app test skipped.

The section that used to stand at the top of this page — three things
waiting on App Review, on GitHub and on the store's own privacy answers —
is gone: the app is on the App Store. What is left is work of ours.

Ordered by what I would do next, not by size. Each item says what is wrong,
what the evidence was, and what "done" looks like — so it can be picked up
cold without re-deriving the reasoning.

**Where the recordings are.** They are not in this repository and never will
be: `testdata/` is gitignored and was removed from the history on 8 August
(`9616941`). Riders' GPS traces are their home addresses. Keep your own
files in a local `testdata/` as `test-1` … `test-11`; the
expectations and the pages that describe them are committed, the recordings
are not.

**Debug builds carry the recordings; release builds must not.** They are
bundle resources, and Xcode copies resources in every configuration — the
`#if DEBUG` around `DevSeed` stops them being *loaded*, not *shipped*. A
release build was verified to contain all ten.

`EXCLUDED_SOURCE_FILE_NAMES = "*.openwater"` on the app target's Release
configuration keeps them out at the source, so it holds however the build is
made — `xcodebuild`, Product ▸ Archive, or a CI runner. `scripts/testflight.sh`
still strips and still fails on a stray, which is now belt-and-braces rather
than the only line of defence: a script can be bypassed by anybody archiving
from Xcode's own menu, and that is exactly the path somebody takes in a
hurry.

Verified both ways after the change: Release 0, Debug 10, and a clean debug
install seeds all ten sessions.

**The test bed.** `scripts/record-expectations.sh` re-measures every
recording and writes both the JSON a build checks against and a readable
page per session. `scripts/load-simulator.sh` puts the whole set on a
simulator. A debug build carries them itself — see `openWater/DevSeed/`.

---

## 1. Speed through water

**The one structural debt left in the analysis, and a rider has now hit it
from the front.**

GPS reports speed over ground. On a river or a tidal race that is
systematically wrong in one direction and right in the other. Measured on
test-8:

| | median ground speed |
| --- | --- |
| downwind (into the current) | 9.6 kn |
| upwind (with it) | 11.1 kn |
| whole session | 10.2 kn |

About a knot of current. `foilTakeoffSpeed` is compared against absolute
ground speed, and a turn is where speed is lowest anyway — so a gybe on the
slow tack dips under the threshold and reads as a touchdown that never
happened. That is exactly what a rider reported on test-8's upwind gybes.

**Done looks like**, in two parts. The first landed on 19 August; the second
is the whole point and is still open.

1. ~~`current` (speed and direction) on the session, entered in the wind and
   swell setter as a third arrow.~~ **Done.** `Session.currentSpeed` and
   `Session.currentDirectionToward` — *toward*, the chart convention the
   currents screens already use, and deliberately the opposite of the wind's,
   said out loud under the dial every time the arrow changes. The Conditions
   sheet grew a third segment and a third arrow in orange, pointing outward
   because a current is the one arrow there that means "this way", and its
   sliders now follow the segment rather than stacking — three at once turned
   a one-screen sheet into a scroll — and a segment whose tab is still empty
   wears `AnalysisRow`'s orange triangle, since two of the three answers are a
   tap away and a rider who never taps never learns they were asked. That mark
   is why the picker is hand-drawn: `Picker(.segmented)` renders a segment's
   words and drops an interpolated image, which was measured on screen rather
   than assumed. A legend at the foot of the sheet decodes the mark and names
   the tabs still waiting — it appears only while one does. Look up
   fills it from the same marine request that already fetched the swell
   (`ocean_current_velocity` rides in the same `hourly` list, so it costs no
   second call), averaged **as a vector** — a session spanning the turn of
   the tide ran both ways, and the honest answer is the net set, not a mean
   speed pointing at the circular mean of two opposed bearings. It shows on
   the map dial's rim, in the summary card under the swell, and in the
   post-session review. Nothing in the analysis reads it: it forces no
   recompute and bumps no version.
2. A `speedThroughWater` series — ground velocity minus the current vector,
   per sample, using each sample's heading — and a deliberate decision per
   metric about which frame it belongs in. Takeoff, glide detection and VMG
   should move. **Speed records must not:** every speed-sailing site is
   ground-referenced and changing it would make our numbers incomparable.

Part 2 bumps `analysisVersion`. Worth doing with the test bed watching all
ten recordings, because it will move numbers on every one of them, and test-8
is the session that proves it worked — and now that part 1 is stored, test-8
can carry the knot it has always had.

The same reciprocal-heading asymmetry that proves the current exists can
estimate it, so the app can offer "looks like about 1 kn from the west" and
save a rider measuring a river.

---

## 2. ~~Flights break on dips that were never landings~~ — done

**Fixed 10 August 2026, in `analysisVersion` 13.** Kept here because the
design point cost two attempts to find and is easy to undo by accident.

The rider's ground truth: on test-11 they were on the foil continuously, and
the app reported thirty-five flights and, on the trimmed version they sent
back, twenty-seven runs. Twenty-four of the twenty-nine gaps between those
"flights" were under twenty seconds. The physical argument is theirs — coming
off the foil and getting going again takes twenty to thirty seconds — so a
shorter gap was a dip through the threshold, not a landing.

**The design point, which the first attempt got wrong.** Joining the flights
outright made `flyingMask` claim the rider was up during the gaps, and a gybe
that dipped to 1.8 m/s started scoring as dry. At three and a half knots
nobody is flying. **How many rides** and **were you up at this instant** are
two different questions, and they were reading one mask.

So the join keeps both answers. `FoilDetector.minimumRecovery` (per sport,
`SportThresholds.foilMinimumRecovery`, 20 s) merges flights across gaps too
short to be a fall, and the gap is kept on `Flight.dips`. `flyingMask`
subtracts the dips; `summarise` subtracts their seconds from time on foil;
`ManeuverDetector` requires a flight to span the turn *and* not dip inside
it. Anything asking about a moment still gets the literal answer.

What it moved: test-11 35 flights to 10 and 34 runs to 16, the reported
trim 30 flights to 6, test-4 33 to 4, test-5 23 to 7. Time on foil is
unchanged everywhere, which is the check that the dips are being subtracted.
The two guardrails held — test-2 still six downwind runs, test-9 still one
unbroken ride at 99%.

---

## 2b. ~~A single-leg downwinder shows its stretches instead of itself~~ — done

Same report, same day. `RibbonView.showsLegs` required `legs.count > 1`, on
the grounds that one leg spans the session and repeats the header. But a
downwinder *is* one leg, and that rule threw away a correct answer the shape
analysis had already worked out — `downwinder`, one leg, two degrees off dead
downwind — in favour of counting stretches on a course that never changed
tack. Repeating the header is a much smaller sin than inventing twenty-six
runs. The row now expands into what is inside it when it is the only one, so
nothing is lost.

---

## 2c. ~~Jumps invented from ordinary foiling~~ — done

Same report: "no jumps", against nine. `JumpDetector` used a fixed free-fall
bar of 2.5 m/s², and **982 of that session's 1,345 samples were under it** —
the median while flying was 1.62. The free-fall clause was therefore true for
most of the session, and the only thing making a stretch a "jump" was the
landing spike at the end, which chop supplies all day. One of them claimed
nineteen metres of air.

Same fault and same fix as `FoilDetector.smoothnessBar`: a foil in the air is
not quiet in absolute terms, it is quiet compared to this rider on this rig
today. `freeFallBar(for:)` takes the session's own quiet quartile and halves
it, never rising above the sport's ceiling. test-11 10 jumps to 0, test-9
4 to 0, and `JumpDetectorTests` pins both directions — a silent window
ending in a landing is still found.

---

## 3. What a run is, on a lapping session

Settled for downwinders and still open for laps.

`GroupedRun` merges stretches on one point of sail, splits at touchdowns and
at direction reversals, and takes its kind from the wind angle with the
upwind boundary at 80° rather than `PointOfSail`'s 55°. That last change
came from test-8, where 8.2 km between 50° and 80° off the wind was being
called reaching while the Upwind screen correctly called it beating.

The guardrails hold: test-2 is 6 downwind and nothing else, test-9 is one
unbroken parawing run. Both must stay that way.

**Still unresolved, and the numbers have moved under it.** The flight merge
of 10 August recut test-5: 7 flights where there were 23, and 235 runs where
the page argued about 113 — 48 downwind, 31 reaching and **156 upwind**,
from 246 stretches across 2¼ hours. Fewer flights and more runs is not a
contradiction; it is one session cut by two different rules, and 156 upwind
runs for an afternoon of laps is now the figure nobody would recognise.
Nobody has yet said what they would count it as, so there is still nothing
to tune towards. The pages in `openWaterTests/Expectations/` are where that
answer belongs — and test-5's own page still reasons from the old figures
below its "yours" line, so whoever answers should correct that too.

---

## 4. A pass on a real device

The app runs on an iPhone 17 Pro and the radar loop was debugged on one in
Maine, but most screens have only been walked in the simulator.

- **File-type registration especially.** `com.topografix.gpx` is an
  *imported* type that Strava and Garmin Connect also declare, and the
  system reconciles them by rules more forgiving in the simulator than on a
  device. Check that tapping a GPX still offers openWater.
- Background location during a recorded session.
- The watch install path (needs Developer Mode — see README).
- **The tide, surf and currents screens have data in them now — in the
  simulator.** The Spots rebuild made the map centre the question, so
  parking inland is no longer the default, and those screens were worked
  hard enough over real water to find their own bugs: an empty hour axis
  left the previous region's water painted over dry land, and the Golden
  Gate's own station answers hourly requests in a dialect that drew a blank
  chart under a working scrubber. What is still owed is the same pages on a
  device, on real coastline — Port Aransas or Montauk.

---

## 5. The README is stale

The screenshots are current — the App Store set was re-shot on 14 August and
an iPad 13-inch family joined it. The prose is nine days staler than it was:
it still does not mention the Analysis tab, the pinned Runs map, the quiver
or the feedback path, and now misses the whole Spots rebuild as well — the
map centre as the question, saved routes, private spots, currents, the
harmonic tide curve, the surf rating, and the wind wash with its model
picker and its hour clock.

```bash
SKIP_INSTALL=1 ./Marketing/capture-screenshots.sh <udid> Marketing/screenshots/appstore/iphone-6.9
```

`SKIP_INSTALL=1` because a fresh install clears the location grant and
`simctl privacy` has no working switch for location, so the permission alert
lands on top of the shot.

---

## Where the other open lists live

Nine days of Spots, surf and station work landed after this page was
written, and it brought open items of its own. They are kept where the work
is rather than copied here, because a copy is a thing that goes stale:

- [`WIND.md`](WIND.md) — six unticked boxes. The two worth doing next are
  **sessions as observations** (per-spot bias correction from the rider's
  own tracks: the guide's largest early accuracy gain, and the one thing no
  weather site can copy) and **spot geometry** (a water-facing bearing per
  guide spot — private spots got one on 11 August, which is exactly why
  `SurfRating` caps an unknown facing at 3). Beside them: the older wind
  screens still owe the "modelled, not observed" line the currents layer
  ships with; every fetcher still collapses no-network, rate-limited and
  no-marine-cell into the same empty answer; WeatherKit and Open-Meteo
  still produce a session wind through two unrelated paths with
  contradictory confidences; and Open-Meteo's free tier is non-commercial,
  which is a shipping decision rather than a coding one.
- [`STATIONS.md`](STATIONS.md) — the registry writer is the item that can
  undo the others: the rules bind only a bot that reads them, so the
  document count (990 on 18 August) wants checking before anything else on
  that page is trusted. Then: no free stations outside the United States,
  and ~827 rows still carrying id-shaped names that the app rescues at
  render time.
- [`WIND_STATION_AUDIT_2026-08-19.md`](WIND_STATION_AUDIT_2026-08-19.md) —
  no violations, five bugs found and fixed to get there, and 515 of the 990
  rows still sitting where R1 and R3 cannot be answered at all. Xweather
  was measured for exactly that gap and turned down at home — 18 stations
  where the free networks hold 24 over Sag Harbor, 225 against 282 over San
  Francisco — and abroad it waits on two decisions that are not code: a
  proxy, because a key shipped inside the app is extractable, and its
  display terms.
- [`SURF.md`](SURF.md) — nothing open. Tiers 1 to 5 all closed on 18
  August, the last of them in the forecaster's own words.

---

## Smaller, known, and deliberate

**A drawn run is slightly longer than the sum of its stretches.** The maps
draw every track point between a run's first and last stretch, so an
absorbed reach inside a run is included in its line. Both maps use the same
rule, so they agree with each other; they just do not agree exactly with the
distance printed on the row.

**Feet are a strange unit for a run.** With imperial units a run reads
"2448 ft". The threshold in `Format.distance` where feet become miles is set
too high for this use — `Units.swift:158`, where imperial stays in feet all
the way to a statute mile.

**The runs map frames the whole session even when a filter is on.** At peek
height the numbered badges cluster. Framing to the visible runs would make
the small size genuinely useful.

**`showControls` on the full-screen map is now inert.** Hiding the chrome is
a reasonable feature; it needs a gesture people can find and reverse, which
tapping the map was not. Still true — `FullScreenMapView.swift:113` keeps
the state and the comment, and nothing sets it.

**The watch shows none of the new analysis** — no shape, glides, jumps or
route. Defensible: it is a recorder, and the phone is where analysis is
read.

**No fixture from a previous release.** `ArchiveCompatibilityTests`
synthesises old archives by stripping keys, which is not the same as a file
written by a shipped build. Committing one or two real archives would close
it — archives, not recordings, so this is compatible with keeping traces out
of the repository.

**Jump thresholds are exposed but barely exercised.** Four sliders that have
seen two real jumping sessions (test-9 with 4, test-11 with 10). Tuning advice in
the notes is educated guesswork until more sessions with motion data go
through.

**RainViewer publishes no forecast frames.** The loop is history only;
`radar.nowcast` returns an empty array on the free tier. The code already
carries forecast frames when there are any, so if that changes the loop
extends forward with no further work.

---

## Resolved since this was written

Kept briefly, because each one was a real fault and the shape of it is worth
remembering.

- **The glide clock lost time.** `glideTime` discarded sub-minimum glides
  along with their seconds, so a 99%-on-foil session reported 44%.
- **Runs ignored touchdowns**, so a session with seven swims read as one
  thirty-six-minute reach.
- **Isolating a run drew nothing.** A `StateSegment` is tagged with a run
  only when it sits entirely inside one; on test-8 that is 38 of 98
  segments. The maps isolate a range of samples now, clipped to it.
- **The Runs list and its own map disagreed** about what a run was, twice.
- **The upwind band was a sailboat number** — 55°, where a wing beats at 60
  to 80.
- **`flyingMask` dropped rather than clamped** a flight ending on the last
  sample, erasing the whole flight from the mask. Now clamped; no
  expectation moved, which confirms it was defensive.
- **Wind confidence read 1.0** on a clean estimate. Capped at 0.9: a perfect
  score means the *track* is unambiguous, not that the wind is known.
- **Imports defaulted to a constant sport.** They take the rider's last
  choice now, and remember what they pick.

**And in the nine days since,** each of these found by pointing the app at
live data rather than at a test:

- **Flights broke on dips, single-leg downwinders showed their stretches,
  and jumps were invented from ordinary foiling** — items 2, 2b and 2c above,
  all three out of one rider's afternoon.
- **The centre pill shimmered at a forecast nobody was fetching.** Picking
  a new wind model forgets every cached wind, but the centre point's task
  was keyed on the scrub state and the coordinate alone, so it never re-ran
  and sat waiting on a series that would never be asked for. The model
  joins that key; an hour with genuinely no wind now shows a dash rather
  than shimmering for ever.
- **The comets lied about how hard it was blowing.** Pace was normalised by
  the field's own strongest node, so six knots and thirty crossed the glass
  at the same rate. Measured against a fixed reference wind now — eighteen
  knots crosses the visible span in six seconds, everything else by its own
  true speed.
- **A gust is a reading, and so is zero.** The weather service writes calm
  gusting four as `0G4`; the app required a mean and threw the gust away,
  so those pins went bare. East End reporting went from 13 of 26 stations
  to 19 of 26.
- **The newest record was not the newest reading** — these sensors file
  partial reports — and a station sheet said "not reporting" over a number
  it had just fetched.
- **Enough stations was never the same claim as the nearest ones.** The
  state walk stopped at forty within fifty kilometres, which fills a map
  without answering the question: of the forty nearest downtown San
  Francisco the app held four, missing the closest at six hundred metres.
  The rest of the state is walked in the background now — 41 to 282 — and
  no longer over cellular data.
- **The backup failed quietly at both ends**, and the share sheet could
  open blank.

---

## The pattern worth remembering

Every analytical bug found by pointing the app at real recordings has had
the same shape: **an absolute threshold applied to a quantity that varies by
rider, rig or water.**

- glide speed floor → relative to the session's own downwind median
- pump energy → relative to the session's own median
- foil smoothness → relative, and only for a session with both quiet and
  rough phases
- turn granularity → merged, and cross-checked against the run count
- run granularity → grouped into runs a rider would count
- the upwind boundary → 80° for a wing, not 55° for a keelboat

The tests that survived contact with real data are the *relative* and
*physical* ones. When adding a threshold, ask "relative to what?" — and if
the answer is "nothing, it is just a number", it will be wrong for somebody.

Four process rules, all learned the hard way:

1. **Bump `SessionSummary.currentVersion` for any change in detector
   behaviour**, not only when a field is added. `upToDateSession` returns a
   stored summary untouched when the version matches, so a detection change
   without a bump is invisible on every session a rider already has.
2. **Anything added to `SessionSummary` must be optional in storage.**
   Swift's synthesised decoder throws on a missing key rather than using a
   property default, so a non-optional addition makes every existing archive
   undecodable. That shipped once and broke every session for every user.
3. **A rule that skips the first item is a rule with a hole in it.** The run
   merge absorbed a short stretch into the run already under way, which by
   construction could never reach the *first* stretch.
4. **Measure before believing the comment.** The NDBC column index, the
   forecast horizon, the segment-to-run tagging and the upwind band were all
   things the code claimed and the live data contradicted.

---

## Four UI traps, each found twice

Worth writing down because each cost an hour and none of them fails loudly.

**`.tint` and `.accentColor` do not resolve inside `MapPolyline`.** The same
run drew orange unselected and system blue selected. Name colours explicitly;
`GroupedRun.Kind.colour` is the single source for run colours.

**A horizontal `ScrollView` gives its content unbounded vertical space.**
`maxHeight: .infinity` inside one expands past the viewport and the content
below it silently vanishes.

**`MKTileOverlay.maximumZ` stops MapKit requesting deeper tiles but does not
upscale shallower ones** — the map is simply blank above the ceiling. The fix
is a `loadTile` override that crops the ancestor tile.

**`.offset` moves a view visually but not in layout,** so `ScrollViewReader`
sees every offset anchor at zero and can only ever scroll to the first one.
Scroll to a raw offset instead.
