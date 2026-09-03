# Wave rides

Written 3 September 2026, after a review of the whole feature. What a wave
ride is, why it is measured from the swell and not the wind, what a rider can
change about it, and — at the end — what is still wrong with it.

The code is `OpenWaterCore/Analysis/WaveAnalyzer.swift`, one screen at
`openWater/Views/WaveDetailView.swift`, its rules at
`openWater/Views/WaveRulesSheet.swift`, and a row on the Analysis tab. The
tests are `OpenWaterCoreTests/WaveRideTests.swift`.

---

## 1. The rule, in order

A wave ride is a stretch of track where the water was doing the work and the
board was travelling the way the swell was going. In the order the finder
applies them, a sample is *riding* when all of this holds:

1. **It is fast enough.** At or above the greater of the rider's own pace
   fraction — a share of their median speed *with the swell* that day — and an
   absolute floor. Day-relative, so the same rule means the same thing in six
   knots and in twenty.
2. **It is flying,** if the recording has flights at all. A sport with no
   flight phase records none and the test does not apply.
3. **It is not braking.** Smoothed acceleration above the glide detector's own
   deceleration limit.
4. **It points the way the waves are going.** Course within the cone of the
   swell's travel — the swell's *from* bearing plus 180.
5. **The board is quiet,** where there is an accelerometer and the rider has
   not turned the rule off.

Contiguous riding samples become a candidate ride. Then:

- **Carves are bridged.** A turn up the face points out of the cone for a
  second or two; a gap shorter than the carve tolerance is absorbed, provided
  the rider stayed flying and never turned properly away.
- **A ride never spans a gap in the fixes.** Two samples either side of a
  dropout are adjacent in the array and a minute apart on the water.
- **The wave has to have given something.** The peak must beat the lull before
  it by the rise fraction. A wave gives speed for nothing; cruising through the
  cone at one powered pace is a reach that happens to point at the beach.
- **The whole ride went that way.** Takeoff-to-kick-out bearing inside the
  cone, so a run of bridged carves cannot add up to a ride that wandered
  sideways.
- **It is long enough to name.** Anything shorter still counts in the riding
  time and the distance; it simply gets no number on the map or in the list.

## 2. Why the swell, and not the wind

A wave day is exactly the day the two disagree. A side-shore breeze over a
groundswell has the rider riding at right angles to the wind, and every
wind-anchored test in the app — the glide detector's included — calls that
riding across. The swell arrow is the rider's own statement of which way the
waves were going and it is the only signal that knows.

That is the feature's central claim and it is the one thing pinned by a test
that would fail if the anchor moved: the same track, measured against the wind
axis, finds nothing.

The cost is that everything here rests on a number a rider typed. A wrong
swell arrow produces a confident, wrong answer, which is why both screens lead
with the arrow they used and offer to change it.

## 3. What a rider can change

All six live behind **What counts as a ride** on the Wave Rides screen. Each
defaults to `nil`, which means "keep borrowing the glide detector's answer" —
so a rider who has never opened the sheet sees the rides they always saw,
their own glide tuning included.

| Rule | Default | Inherits |
| --- | --- | --- |
| How far off the wave (cone) | 65° | its own |
| Carve tolerance | 8 s | its own |
| Pace to hold | 75 % | `glideSpeedFraction` |
| The wave has to add | 12 % | the firmer of `glideMinimumGain` and 12 % |
| Board may rattle | 1.5× | `pumpEnergyFraction` |
| Shortest ride | 5 s | `glideMinimumDuration` |

Two of these are worth knowing about:

**The pace floor can stop responding.** The speed a stretch must hold is the
*greater* of the pace fraction and an absolute floor, so below the floor the
slider moves and nothing changes. The sheet prints the speed the percentage
works out to, beside the percentage, so this is visible rather than
mysterious. The floor follows the sport — 2.5 m/s for prone, SUP and downwind
SUP, 3 m/s for everything else — because a prone surfer's entire ride happens
under a wing rider's floor.

**All the way right, the accelerometer stops being consulted.** That is a real
answer and not a cop-out. On a wing in short chop the deck is never quiet, and
a bar tuned on a smooth groundswell ends a ride the rider is visibly still on.
This whole sheet exists because of one such report: a thirty-second ride cut
five seconds early at eleven knots, twenty degrees off the swell, still on the
foil, because the board was rattling.

## 4. What is measured

Per ride: distance, entry speed, peak speed, average speed, the mean degrees
off the swell's travel, and the bearing it made ground along. Per session:
every second and every metre on a wave — named ride or not, the same
population for both, so the two can be printed side by side — plus the
longest, the fastest, the typical duration, the speed floor that was applied,
and whether the accelerometer had a say.

There is no per-ride confidence, unlike glides. The inputs do not vary from
ride to ride within a session, so neither would the answer; the honest version
of that admission is the session-level one, and the screen prints it when the
reading came from position alone.

## 5. What it deliberately does not do

**It does not re-segment the session.** Runs, legs and glides are untouched.
Wave rides are another reading of the same track, and the same seconds are
counted as a glide, as part of a run, and as a wave ride. On a
wind-with-swell downwinder the wave count and the glide count are largely the
same events described twice, and nothing in the app says which to believe.

**It is not stored on the session.** Rides are found when a screen asks for
them, so they follow the swell arrow and the rules the moment either changes,
with no analysis version to bump and no recompute to offer. That is the right
trade for a reading built on a number the rider can retype at any time — but
see §6.

---

## 6. Still open

Ordered by what I would do next, not by size.

### 6.1 The test bed cannot see wave numbers

`openWaterTests/SessionExpectationTests.swift` re-measures eleven real
recordings and pins the numbers a rider reads — glides, turns, falls, legs,
runs. It pins nothing about waves, so a change to `WaveRideFinder` moves every
rider's wave count with no signal in CI. The synthetic suite is a genuine
substitute for the *rules*, but not for "this real session still reads the
same".

It cannot be fixed by editing the harness alone: **no recording in `testdata/`
carries a swell direction**, so there would be nothing to record. The recipe,
when a session with swell exists:

1. Set a swell direction on a real wave session in the app, and export it as
   `.openwater` into `testdata/`.
2. Add `waves: Int?` and `waveTime: Double?` to `Expectation`, filled from
   `WaveRideFinder.forSport(...).rides(...)` when `session.swellDirection` is
   non-nil and left nil otherwise.
3. `scripts/record-expectations.sh`, then read the diff.

A wave session from the rider is the blocking input, not the code.

### 6.2 Back-to-back waves are lost

The rise test compares a ride's peak against the lull before it, and the lull
is the minimum speed over the previous eight seconds
(`DownwindAnalyzer.riseWindow`). A wave caught straight after another has the
*previous wave's* speed sitting in that window, so it never shows a rise and
disappears.

This is visible in the tests: turn the carve tolerance off and the water after
a carve is not claimed as a second ride, for exactly this reason. It is the
most likely cause of "it missed half my waves" on a good day, and the least
safe thing here to change blind — a shorter window finds more waves and also
more not-waves. It wants a real session with a rider's own count beside it,
the way the run merge was settled.

### 6.3 Ground speed, not speed through water

Every speed here is over the ground. On a river or a tidal race that is
systematically wrong in one direction and right in the other, which matters
most to the floor and to the per-ride speeds shown without qualification. The
day-relative median cancels a steady current in the *relative* part of the
floor but not in the absolute part. This is the same debt as `docs/OPEN.md` §1
and is fixed by the same work.

### 6.4 A shared session's wave count is not reproducible

The rules live in app settings, per sport, and are not part of the session. So
"I had thirty-four waves" is not a number another copy of the app will
reproduce from the same archive — unlike every other number in it, whose whole
point is that the file *is* the export format. Either the rules used should be
stamped on the session when it is shared, or the screen should say the count
is local to this phone's settings.

### 6.5 Smaller things

- **The map badge arrow** rotates by the ride's bearing in screen space, which
  is correct only while the map is north-up.
- **The row is offered for every sport,** including a flat-water kayak session
  where the swell will never mean anything. Defensible — a row that vanishes
  reads as a missing feature — but it is a permanent nag on the wrong sports.
- **`withSwell` needs a minute of evidence** before its median is trusted, and
  the fallback is the whole session's median, which on a mostly-upwind day is
  not a wave-riding pace.
- **Noise has never been tested.** The 12 % rise exists so that GPS jitter on a
  long steady reach does not read as a wave, and no test builds a jittery
  derived-speed track to prove it.

---

## 7. What was fixed on 3 September 2026

For the record, since several of these were invisible from the screen:

- The speed floor was a flat 3 m/s for every sport, so paddle-in sessions came
  back empty and the pace slider could not rescue them. It now follows the
  sport, as the glide floor already did.
- A ride could span a gap in the fixes: a dropout produced one "wave" whose
  duration counted a minute the distance did not.
- The deceleration smoothing wrote back over its own input, making a lagging
  cascade rather than the three-sample mean it is documented as.
- The deceleration limit and the carve's angle were literals that could not
  follow the glide detector or the cone. At the widest cone, bridging had
  silently stopped working altogether.
- Session distance summed the named rides while riding time counted all of
  them, so the average a rider could work out from the pair was wrong.
- The Analysis row was keyed on the swell alone, so after a rule change it
  disagreed with the screen behind it. Both now re-find off the main actor.
- The list coloured a ride green under thirty degrees off the swell, rewarding
  pointing straight at the beach, while the same screen's footer says down the
  line at forty to sixty is what a surfer is doing. The number is a fact about
  the ride, not a mark out of ten.
- "A stretch on the foil" was stated for every sport and applies only where
  flights were recorded.
- Ten tests, covering the rules moving the answer, carving, dropouts, the
  flight gate, the quiet-board rule, the sport floor, and what the reading
  rests on.
