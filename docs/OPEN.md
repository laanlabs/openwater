# Open work

Written 10 August 2026, at analysis version 12, 250 core tests and 49 app
tests passing.

Ordered by what I would do next, not by size. Each item says what is wrong,
what the evidence was, and what "done" looks like — so it can be picked up
cold without re-deriving the reasoning.

**Where the recordings are.** They are not in this repository and never will
be: `testdata/` is gitignored and was removed from the history on 8 August
(`9616941`). Riders' GPS traces are their home addresses. Keep your own
files in a local `testdata/` as `test-1.gpx` … `test-10.gpx`; the
expectations and the pages that describe them are committed, the recordings
are not.

**Debug builds carry the recordings; release builds must not.** They are
bundle resources, and Xcode copies resources in every configuration — the
`#if DEBUG` around `DevSeed` stops them being *loaded*, not *shipped*. A
release build was verified to contain all ten. `scripts/testflight.sh` now
strips them from the archive and fails the build if any survive, which is the
only place that check belongs: it is the seam every upload passes through.

**The test bed.** `scripts/record-expectations.sh` re-measures every
recording and writes both the JSON a build checks against and a readable
page per session. `scripts/load-simulator.sh` puts the whole set on a
simulator. A debug build carries them itself — see `openWater/DevSeed/`.

---

## 0. Blocked on somebody else

Three things are finished on this side and waiting.

**TestFlight has still not shipped.** *(The recordings-in-release problem
below is fixed — `scripts/testflight.sh` strips them and fails if any
survive.)* Riders on the current build cannot open
*any* session — fixed on `main` since 7 August, along with everything since.
`scripts/testflight.sh`. `analysisVersion` has moved 4 → 12, so every stored
session re-analyses on first open; that is the intended path.

**The recordings that were public.** Five were pushed before `9616941`
rewrote the history. Unreachable is not deleted: GitHub keeps them until it
garbage-collects, and a SHA somebody already has still resolves. Ask GitHub
Support to run GC, then confirm a known blob 404s.

**Problem reports cannot ship until the privacy answers change.** The
Firestore and Storage rules are deployed and verified live; the app side is
done and pinned by `SessionFeedbackTests`. What is missing is the
disclosure: the App Store answers describe web sharing, and uploading a
track so a bug can be reproduced is a different purpose. Location needs
listing under Diagnostics, plus a policy line saying feedback recordings are
sent only when the rider turns the toggle on, used only to reproduce the
problem, and never published. The in-app handling is careful — off every
time, never remembered, not even encoded unless the toggle is on — and that
is not a substitute for declaring it.

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

**Done looks like**, in two parts:

1. `current` (speed and direction) on the session, entered in the wind and
   swell setter as a third arrow. The dial already carries two.
2. A `speedThroughWater` series — ground velocity minus the current vector,
   per sample, using each sample's heading — and a deliberate decision per
   metric about which frame it belongs in. Takeoff, glide detection and VMG
   should move. **Speed records must not:** every speed-sailing site is
   ground-referenced and changing it would make our numbers incomparable.

Bumps `analysisVersion`. Worth doing with the test bed watching all ten
recordings, because it will move numbers on every one of them, and test-8 is
the session that proves it worked.

The same reciprocal-heading asymmetry that proves the current exists can
estimate it, so the app can offer "looks like about 1 kn from the west" and
save a rider measuring a river.

---

## 2. What a run is, on a lapping session

Settled for downwinders and still open for laps.

`GroupedRun` merges stretches on one point of sail, splits at touchdowns and
at direction reversals, and takes its kind from the wind angle with the
upwind boundary at 80° rather than `PointOfSail`'s 55°. That last change
came from test-8, where 8.2 km between 50° and 80° off the wind was being
called reaching while the Upwind screen correctly called it beating.

The guardrails hold: test-2 is 6 downwind and nothing else, test-9 is one
unbroken parawing run. Both must stay that way.

**Still unresolved:** test-5 reports 48 downwind and 51 reaching from 23
flights across 2¼ hours — 99 runs for an afternoon of laps. Nobody has said
what they would count it as, and until somebody does there is nothing to
tune towards. The pages in `openWaterTests/Expectations/` are where that
answer belongs.

---

## 3. A pass on a real device

The app runs on an iPhone 17 Pro and the radar loop was debugged on one in
Maine, but most screens have only been walked in the simulator.

- **File-type registration especially.** `com.topografix.gpx` is an
  *imported* type that Strava and Garmin Connect also declare, and the
  system reconciles them by rules more forgiving in the simulator than on a
  device. Check that tapping a GPX still offers openWater.
- Background location during a recorded session.
- The watch install path (needs Developer Mode — see README).
- **The tide and surf screens have never been seen with data in them.** The
  simulator's conditions sheet reads the map centre, which has been parked
  inland; the multi-day surf chart and the full-screen tide both render
  empty there. Port Aransas or Montauk on a device is the test.

---

## 4. The README is stale

The screenshots are current; the prose is not. It does not mention the
Analysis tab, the pinned Runs map, the Conditions, radar and surf screens,
the quiver, or the feedback path.

```bash
SKIP_INSTALL=1 ./Marketing/capture-screenshots.sh <udid> Marketing/screenshots/appstore/iphone-6.9
```

`SKIP_INSTALL=1` because a fresh install clears the location grant and
`simctl privacy` has no working switch for location, so the permission alert
lands on top of the shot.

---

## Smaller, known, and deliberate

**A drawn run is slightly longer than the sum of its stretches.** The maps
draw every track point between a run's first and last stretch, so an
absorbed reach inside a run is included in its line. Both maps use the same
rule, so they agree with each other; they just do not agree exactly with the
distance printed on the row.

**Feet are a strange unit for a run.** With imperial units a run reads
"2448 ft". The threshold in `Format.distance` where feet become miles is set
too high for this use.

**The runs map frames the whole session even when a filter is on.** At peek
height the numbered badges cluster. Framing to the visible runs would make
the small size genuinely useful.

**`showControls` on the full-screen map is now inert.** Hiding the chrome is
a reasonable feature; it needs a gesture people can find and reverse, which
tapping the map was not.

**The watch shows none of the new analysis** — no shape, glides, jumps or
route. Defensible: it is a recorder, and the phone is where analysis is
read.

**No fixture from a previous release.** `ArchiveCompatibilityTests`
synthesises old archives by stripping keys, which is not the same as a file
written by a shipped build. Committing one or two real archives would close
it — archives, not recordings, so this is compatible with keeping traces out
of the repository.

**Jump thresholds are exposed but barely exercised.** Four sliders that have
seen exactly one real jumping session (test-9, 4 jumps). Tuning advice in
the notes is educated guesswork until more sessions with motion data go
through.

**RainViewer publishes no forecast frames.** The loop is history only;
`radar.nowcast` returns an empty array on the free tier. The code already
carries forecast frames when there are any, so if that changes the loop
extends forward with no further work.

**Surf conditions are not rated.** The strip colours each band by what the
wind is doing to the swell — offshore, cross-shore, onshore — which is a
fact. A Surfline-style star rating would be our opinion, and would need the
guide to know which way each beach faces. Worth doing; worth labelling as
ours.

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
