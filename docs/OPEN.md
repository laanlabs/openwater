# Open work

Written 8 August 2026, at analysis version 12, 250 core tests and 27 app
tests passing.

Ordered by what I would do next, not by size. Each item says what is wrong,
what the evidence was, and what "done" looks like — so it can be picked up
cold without re-deriving the reasoning.

**Where the recordings are.** They are not in this repository and never will
be: `testdata/` is gitignored and was removed from the history on 8 August
(`9616941`). Riders' GPS traces are their home addresses. Keep your own
files in a local `testdata/` and import them through the app; anything in
this document that cites a recording names it, but you will need your own.

---

## 0. Done since this was written

**Runs and the maps that draw them.** The segmenter splits on every
meaningful change of direction, which on a lapping afternoon is sixty-seven
pieces; a rider looking at the same track says "six downwinders and five
beats back". `GroupedRun` (`openWater/Views/GroupedRuns.swift`) merges
consecutive stretches on one point of sail into the run a rider counts, and
now feeds the Runs tab, the Downwind list and both maps from one place, so
they cannot disagree. The Runs tab opens with a map of every run, numbered
and coloured by kind, filterable and tappable.

**The glide-time defect** (`43651a8`). `glideTime` discarded sub-minimum
glides *along with their time*, so a session that was 99% on foil reported
44%. Split into a `Detection` that separates nameable glides from time spent
gliding. The consistency test had been asserting the defect and was
corrected to bounds rather than equality. Version 11 → 12.

**Weather, conditions and radar.** Nearby free stations (NWS, NOAA CO-OPS
tides, NDBC buoys), multi-model Open-Meteo forecasts, marine swell, and
radar — NOAA RIDGE II stills plus an animated RainViewer loop that prefetches
and caches every frame before playing. All keyless and non-commercial.

**Screenshots re-captured** for the restructured tabs, including the new
Analysis shot.

---

## 1. Ship a TestFlight build

**Riders on the current TestFlight still cannot open any session.** They see
"Loading session…" for ever, on every session in their history.

The cause was fixed on `main` on 7 August (`7076ae3`), and everything in
sections 0 above has landed since. Nothing has shipped, so none of it helps
anybody yet. This is not a code change:

```bash
scripts/testflight.sh
```

Worth knowing before it goes: `analysisVersion` has moved 4 → 12, so every
stored session re-analyses on first open. That is the intended path and
`upToDateSession` handles it, but the first open of a long session takes a
beat longer than usual.

Also unconfirmed: the privacy manifest added on 7 August fixed Apple's
ITMS-91053 warning locally, but `altool --validate-app` needs an App Store
Connect key that is not on this machine. **Confirm the warning is gone on
the next real upload.**

---

## 2. Recordings were public before the history rewrite

Five recordings were pushed to a public GitHub repository before `9616941`
removed them and force-pushed. The history is clean now and the objects are
unreachable, but **unreachable is not deleted** — GitHub keeps them until it
garbage-collects, and a commit SHA someone already had will still resolve
until then.

**Done looks like:** asking GitHub Support to run GC on the repository, and
confirming a known blob SHA 404s afterwards. This is the only step left and
it cannot be done from the command line.

---

## 3. "Report a problem" is built and cannot send yet

Every build now has a bug button beside the ⋯ on a session. It files what
the rider says against the numbers the app was showing, and optionally — only
when they turn it on — the recording itself, so a problem can be reproduced.
`scripts/fetch-feedback.sh` pulls the reports into the expectation pages.

**Two things are missing, and both are outside this repository.**

**The rules.** Writes go to a `sessionFeedback` collection and, with consent,
to `feedback/` in Storage. Neither has a rule, so submissions come back 403 —
the sheet says so rather than failing quietly. Following `spotSuggestions`
exactly: create-only, bounded, never readable by the app.

```
match /sessionFeedback/{id} {
  allow create: if request.resource.data.keys().hasOnly([
                     'topic', 'text', 'contact', 'session', 'sport',
                     'duration', 'distance', 'analysisVersion',
                     'runsDownwind', 'runsReaching', 'runsUpwind',
                     'stretches', 'flights', 'turns', 'falls', 'jumps',
                     'foilingFraction', 'windDirection', 'windSource',
                     'recordingPath', 'appVersion', 'system', 'createdAt'])
                && request.resource.data.text is string
                && request.resource.data.text.size() <= 4000
                && request.resource.data.session.size() <= 60
                && request.resource.data.topic in ['Runs', 'Foiling',
                     'Speed & distance', 'Wind', 'Turns, falls & jumps',
                     'Something else'];
  allow read, update, delete: if false;
}
```

```
// Storage — same shape as suggestions/, never publicly readable.
match /feedback/{file} {
  allow create: if request.resource.size < 25 * 1024 * 1024;
  allow read, update, delete: if false;
}
```

**The App Store privacy answers.** This is the part that must not be skipped.
The app can now upload a rider's full GPS track for a purpose the current
disclosure does not cover — the existing answers describe web sharing, which
is a different thing a rider initiates for a different reason. Before this
ships, "Location" needs listing under Diagnostics or Product Interaction as
well, and the privacy policy needs a line saying feedback recordings are
sent only on request, used only to reproduce a problem, and never published.

The app-side handling is already deliberate: off every time the sheet opens,
never remembered, the track is not even encoded unless the toggle is on, and
the footer says in plain words what leaves the phone. None of that
substitutes for the disclosure.

Reading the collection back needs owner credentials (`gcloud auth
application-default login`); the app can only create. A report that carries a
recording says so in the page, with its Storage path — that is the rider's
personal location data, so pull it to reproduce the problem and do not keep
it afterwards.

---

## 4. Speed through water

**The one structural debt left in the analysis.**

GPS reports speed over ground. On a river or a tidal race that is
systematically wrong in one direction and right in the other, and it is the
root cause of a whole family of faults chased on 6–7 August. Three symptoms
were patched — the glide floor, shallow speed dips, the smoothness bar — but
the cause was not.

Evidence, from a Gorge upwind recording:

| | median ground speed |
| --- | --- |
| downwind (into the current) | 9.6 kn |
| upwind (with it) | 11.1 kn |
| whole session | 10.2 kn |

Reciprocal headings differ by about a knot. That is the current.

**What is still absolute ground speed:** `foilTakeoffSpeed`. A rider going
downwind against a knot of current looks a knot slower than they are flying,
which is what produced sixteen false touchdowns before the smoothness fix
papered over it.

**Done looks like:** a current vector estimated from reciprocal-heading
asymmetry, and a deliberate decision per metric about which frame it belongs
in. Speed records stay ground-referenced — that is the convention every
speed-sailing site uses, and changing it would make our numbers
incomparable. Takeoff, glide detection and VMG arguably should not.

This touches every speed-derived figure. It wants its own pass and its own
tests, not a patch.

---

## 5. A pass on a real device

The app has been built and installed on an iPhone 17 Pro, and the radar loop
was debugged on one in Maine — but most screens have only been walked in the
simulator.

- **File-type registration especially.** `com.topografix.gpx` is an
  *imported* type that Strava, Garmin Connect and others also declare, and
  the system reconciles them by rules that are more forgiving in the
  simulator than on a device. Check on a real iPhone, with those apps
  installed, that tapping a GPX still offers openWater.
- Background location during a recorded session.
- The watch install path (needs Developer Mode on the watch — see README).

---

## 6. Sport is guessed on import

A GPX that does not name its sport imports as the app's default. Three
Montauk recordings came in as wingfoil purely because nothing said otherwise
— and sport sets the thresholds for flights, turns and glides, so a wrong
guess makes every derived number wrong.

**Done looks like:** remembering the last sport chosen for imports from the
same source, or at least defaulting to `settings.lastSport` rather than a
constant. The import sheet already lets a rider change it; the default just
needs to be less arbitrary.

---

## 7. The README is stale

The screenshots are current; the prose is not. It does not mention the
Analysis tab, the Runs map, the Conditions and radar screens, the adjustable
thresholds, or the bundled sample session.

To re-capture after a UI change:

```bash
SKIP_INSTALL=1 ./Marketing/capture-screenshots.sh <udid> Marketing/screenshots/appstore/iphone-6.9
```

`SKIP_INSTALL=1` because a fresh install clears the location grant and
`simctl privacy` has no working switch for location, so the permission alert
lands on top of the shot. Grant it once by hand, then use that flag.

---

## Smaller, known, and deliberate

**The reaching band may be too wide.** The 1:24 lapping session reports 5
downwind, 12 reaching and 2 upwind. Twelve reaches on a session that is
visibly laps up and down a river is suspicious — either the 55–120° band is
catching legs a rider would call downwind, or those are genuine cross-river
transits. Worth checking against a rider's own account before touching the
thresholds.

**A run is a ride, and on a foiling session that is now literal.** Stretches
belonging to no flight are dropped from the run list — they are the swim back
out, and left in they read as runs at three knots. The cost is that the run
list no longer accounts for the whole session's distance, and that it leans
entirely on the foil detector: a missed flight is now a missing run rather
than a run with a gap in it. Sessions with no flights at all (any
non-foiling sport) keep every stretch, which is what they want.

**A drawn run is slightly longer than the sum of its stretches.** The maps
draw every track point between a run's first and last stretch, so a brief
absorbed reach inside a run is included in its line. Both maps use the same
rule, so they agree with each other; they just do not agree exactly with the
distance printed on the row.

**The watch shows none of the new analysis** — no shape, glides, jumps or
route. Defensible: it is a recorder, and the phone is where analysis is
read. Worth revisiting only if riders ask.

**App-layer tests are still thin.** 250 core tests against 27 app tests.
`GroupedRun.group` is now covered (`openWaterTests/GroupedRunTests.swift`),
which was the highest-risk piece. Nothing covers `RouteNamer`'s "don't say
Viento → Viento" rule, the Analysis row conditions, the threshold bindings,
or any of the weather and radar code added on 8 August.

**No fixture from a previous release.** `ArchiveCompatibilityTests`
synthesises old archives by stripping keys, which is good but not the same
as a file written by a shipped build. Committing one or two real archives
from older versions would close it properly — archives, not recordings, so
this is compatible with keeping traces out of the repo.

**Wind confidence reads 1.0** on a clean bidirectional estimate, which is
stronger than "estimated" deserves and feeds the warning logic. Cosmetic,
but it is the number a rider sees when they ask why we think the wind was
where it was.

**`flyingMask` drops rather than clamps** a flight whose `endIndex` equals
the sample count. The detector never produces one, so this is defensive code
that fails silently rather than a live bug — but it bit a test fixture, and
it should clamp.

**Jump thresholds are exposed but barely exercised.** The Airtime screen has
four sliders and has seen exactly one real jumping session (the Rufus
parawing run, 4 jumps). Tuning advice in the notes is educated guesswork
until more sessions with motion data go through it.

**RainViewer publishes no forecast frames.** The loop is history only.
`radar.nowcast` returns an empty array on the free tier, and the code
carries forecast frames when there are any — so if that ever changes, the
loop extends forward with no further work.

---

## The pattern worth remembering

Seven analytical bugs were found on 6–7 August by pointing the app at real
recordings. **Every one had the same shape:** an absolute threshold applied
to a quantity that varies by rider, rig or water.

- glide speed floor → now relative to the session's own downwind median
- pump energy → now relative to the session's own median
- foil smoothness → now relative, and only for a session with both quiet and
  rough phases
- turn granularity → now merged, and cross-checked against the run count
- run granularity → now grouped into runs a rider would count

The tests that survived contact with real data are the *relative* and
*physical* ones: fast for this session, quiet for this rig, a turn that cost
speed, a landing that actually slowed you down. When adding a threshold, the
question to ask first is "relative to what?" — and if the answer is "nothing,
it is just a number", it will be wrong for somebody.

Three process rules came out of it, all learned the hard way:

1. **Bump `SessionSummary.currentVersion` for any change in detector
   behaviour**, not only when a field is added. `upToDateSession` returns a
   stored summary untouched when the version matches, so a detection change
   without a bump is invisible on every session a rider already has. This
   happened three times in one day, each time looking like the fix had not
   worked.
2. **Anything added to `SessionSummary` must be optional in storage.** Swift's
   synthesised decoder throws on a missing key rather than using a property
   default, so a non-optional addition makes every existing archive
   undecodable. That shipped once and broke every session for every user.
   `ArchiveCompatibilityTests` now fails the build if it recurs.
3. **A rule that skips the first item is a rule with a hole in it.** The
   run merge absorbed a short stretch into the run already under way, which
   by construction could never reach the *first* stretch — so every session
   opened with its few seconds of getting going promoted to a run of its
   own. Found by a unit test, not by looking at the screen, after the screen
   had been checked by eye several times.

---

## Three UI traps, each found twice

Worth writing down because each cost an hour and none of them fails loudly.

**`.tint` and `.accentColor` do not resolve inside `MapPolyline`.** The same
run drew orange unselected and system blue selected. Name colours explicitly
in map content; `GroupedRun.Kind.colour` is the single source for run
colours and should stay that way.

**A horizontal `ScrollView` gives its content unbounded vertical space.**
`maxHeight: .infinity` inside one expands past the viewport and the content
below it silently vanishes. This ate the wind-arrow row twice.

**`MKTileOverlay.maximumZ` stops MapKit requesting deeper tiles but does not
upscale shallower ones** — the map is simply blank above the ceiling. The
fix is a `loadTile` override that crops the ancestor tile. RainViewer's free
tilecache publishes to z7, which is well below where anybody actually looks
at a map.
