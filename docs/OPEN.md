# Open work

Written 7 August 2026, at analysis version 11, 250 core tests passing.

Ordered by what I would do next, not by size. Each item says what is wrong,
what the evidence was, and what "done" looks like — so it can be picked up
cold without re-deriving the reasoning.

---

## 0. Done since this was written

**Privacy manifest** (`13a46f6`+). The upload warning was Apple's
ITMS-91053: the app had no `PrivacyInfo.xcprivacy`, which has been required
since May 2024. Added for both the phone and the watch, declaring the one
required-reason API this app touches (UserDefaults, reason CA92.1) and the
precise location a web share transmits. `scripts/testflight.sh` now fails
before upload if either manifest is missing or a declared API has no reason
code — the warning never blocked a build, which is why it went unnoticed.

Not verified against Apple's own validator: `altool --validate-app` needs the
App Store Connect key, which is not on this machine. A clean archive, export
and local verification all pass. **Confirm the warning is actually gone on
the next real upload.**

---

## 1. Ship a TestFlight build

**Riders on the current TestFlight cannot open any session.** They see
"Loading session…" for ever, on every session in their history.

The cause is fixed on `main` (`7076ae3`) and has been all day, along with
everything since. Nothing has shipped, so the fix helps nobody yet. This is
not a code change:

```bash
scripts/testflight.sh
```

Worth knowing before it goes: `analysisVersion` moved 4 → 11 today, so every
stored session re-analyses on first open. That is the intended path and
`upToDateSession` handles it, but the first open of a long session will take
a beat longer than usual.

---

## 2. Speed through water

**The one structural debt left in the analysis.**

GPS reports speed over ground. On a river or a tidal race that is
systematically wrong in one direction and right in the other, and it is the
root cause of a whole family of faults chased on 6–7 August. Three symptoms
were patched — the glide floor, shallow speed dips, the smoothness bar — but
the cause was not.

Evidence, from `testdata/Waterspeed- upwind test.gpx`:

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

## 3. A pass on a real device

Everything this week was verified in the simulator.

- **File-type registration especially.** `com.topografix.gpx` is an
  *imported* type that Strava, Garmin Connect and others also declare, and
  the system reconciles them by rules that are more forgiving in the
  simulator than on a device. Check on a real iPhone, with those apps
  installed, that tapping a GPX still offers openWater.
- Background location during a recorded session.
- The watch install path (needs Developer Mode on the watch — see README).

---

## 4. Screenshots and README are stale again

The captures predate today's work. Changed since: the Conditions card on
Summary, Runs grouped as legs, linked rides on Downwind, the Splits unit
chips, warning badges on Analysis rows.

```bash
SKIP_INSTALL=1 ./Marketing/capture-screenshots.sh <udid> Marketing/screenshots/appstore/iphone-6.9
```

`SKIP_INSTALL=1` because a fresh install clears the location grant and
`simctl privacy` has no working switch for location, so the permission alert
lands on top of the shot. Grant it once by hand, then use that flag.

The README also does not mention the Analysis tab, the adjustable
thresholds, or the bundled sample session.

---

## 5. Sport is guessed on import

A GPX that does not name its sport imports as the app's default. The three
Montauk files in `testdata/` came in as wingfoil purely because nothing said
otherwise — and sport sets the thresholds for flights, turns and glides, so
a wrong guess makes every derived number wrong.

**Done looks like:** remembering the last sport chosen for imports from the
same source, or at least defaulting to `settings.lastSport` rather than a
constant. The import sheet already lets a rider change it; the default just
needs to be less arbitrary.

---

## Smaller, known, and deliberate

**The watch shows none of the new analysis** — no shape, glides, jumps or
route. Defensible: it is a recorder, and the phone is where analysis is
read. Worth revisiting only if riders ask.

**App-layer tests are thin.** 250 core tests against ~400 lines of app
tests. The core maths is well covered; `RouteNamer`'s "don't say Viento →
Viento" rule, the Analysis row conditions and the threshold bindings have no
tests at all.

**No fixture from a previous release.** `ArchiveCompatibilityTests`
synthesises old archives by stripping keys, which is good but not the same
as a file written by a shipped build. Committing one or two real archives
from older versions would close it properly.

**Wind confidence reads 1.0** on a clean bidirectional estimate, which is
stronger than "estimated" deserves and feeds the warning logic. Cosmetic,
but it is the number a rider sees when they ask why we think the wind was
where it was.

**`flyingMask` drops rather than clamps** a flight whose `endIndex` equals
the sample count. The detector never produces one, so this is defensive code
that fails silently rather than a live bug — but it bit a test fixture, and
it should clamp.

**Jump thresholds are exposed but barely exercised.** The Airtime screen has
four sliders and has now seen exactly one real jumping session (the Rufus
parawing run, 4 jumps). Tuning advice in the notes is educated guesswork
until more sessions with motion data go through it.

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
- run granularity → now grouped into legs for point-to-point sessions

The tests that survived contact with real data are the *relative* and
*physical* ones: fast for this session, quiet for this rig, a turn that cost
speed, a landing that actually slowed you down. When adding a threshold, the
question to ask first is "relative to what?" — and if the answer is "nothing,
it is just a number", it will be wrong for somebody.

Two process rules came out of it, both learned the hard way:

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
