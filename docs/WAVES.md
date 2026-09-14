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
- **The wave has to have given something, and given it at the catch.** The
  candidate is scanned for the moment the typical speed over the next few
  seconds beats the typical speed over the eight seconds before by the rise
  fraction, and the ride *begins there*. The cruise in the cone before the
  wave arrived was riding by the per-sample rule; it was not the wave. A
  candidate with no such moment — a steady powered pace, or jitter — is not a
  wave at all. Both ends are medians, not single samples, and the rise also
  has to be worth four of the trace's own sample-to-sample speed steps, so a
  jittery trace sets itself a higher bar. On a trace whose speed was derived
  from positions rather than measured by Doppler, the catch is judged more
  slowly still: the lower quartile over the whole rise window.
- **Unless the lull never came.** A wave caught straight off the back of the
  one before — inside the rise window of its kick-out, with no hole in the
  recording between — is measured against the lull the *previous* wave rose
  out of, and marked **linked**. The speed was that wave's gift and the rider
  never gave it back.
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
off the swell's travel, the bearing it made ground along, and whether it was
linked off the ride before. Per session:
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

### 6.1 The test bed can see wave numbers, but has nothing to look at

`openWaterTests/SessionExpectationTests.swift` now carries `waves`,
`waveTime` and `wavesLinked`, filled when a recording has a swell direction
and left nil otherwise — so a session with one pins its wave count in CI the
way it pins its glides. **No wind-sport recording in `testdata/` carries a
swell direction yet**, so those are still nil; test-12, the SUP-foil session,
pins its three waves through the inferred swell (§7). The recipe for the
rest: set a swell direction
on a real wave session in the app — or tap *Bumps with the wind* on a
downwinder — export it as `.openwater` into `testdata/`, run
`scripts/record-expectations.sh`, and read the diff. A wave session from the
rider is the blocking input, not the code.

Until then the numbers below are the reference, measured on 4 September 2026
with the wind as the swell, the way the new button would set it:

| session | before | after |
| --- | --- | --- |
| test-11 (parawing, Columbia) | 27 waves · 16:42 | 25 waves · 15:30 · 5 linked |
| test-9 (parawing) | 5 · 7:52 | 5 · 7:44 · 2 linked |
| test-2 (wing) | 7 · 15:35 | 7 · 15:35 |
| test-1 (wing, ocean) | 15 · 31:26 | 15 · 29:58 |

The riding time that went was cruise before a catch, no longer counted as the
wave.

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

- **The row is offered for every sport,** including a flat-water kayak session
  where the swell will never mean anything. Defensible — a row that vanishes
  reads as a missing feature — but it is a permanent nag on the wrong sports.
- **`withSwell` needs a minute of evidence** before its median is trusted, and
  the fallback is the whole session's median, which on a mostly-upwind day is
  not a wave-riding pace.
- **Heavy position jitter can still make a wave.** At two and three metres of
  white jitter every second — worse than any receiver — one seed in eight
  still slips a ride through on a derived-speed trace. Pinned in the test so a
  change that makes it worse is noticed; not worth the sensitivity it would
  cost on real bumps to close.
- **The catch is found a sample or two early.** The scan takes the first
  moment the window ahead is already lifted, which is one or two fixes before
  the first fast one. Entry speeds read a touch low because of it.

---

## 7. SUP foil — 13 September 2026

The first paddle-in sport, `Sport.supFoil` ("SUP Foil"), and with it the
first real surf recording in `testdata/` — test-12, Montauk, forty-two
minutes, two long waves and one short one, recorded by the rider as plain
"SUP" because the sport did not exist yet. The finder above found **nothing**
in it. Four of its rules are written for a wing, and each is the wrong way
round for a surfer. They are now sport-aware through `Sport.paddlesIntoWaves`
(`.supFoil` and `.prone`), and every one still reads exactly as it did for
everything else:

**The swell is read off the rides.** A paddled board reaches riding speed on
a wave face and nowhere else, so the direction the fast, flying samples went
*is* the way the waves were going. `WaveRideFinder.inferredSwell` takes the
speed-weighted circular mean of course over flying samples and needs twenty
seconds of evidence; `swellFrom(for:)` prefers the rider's arrow when there
is one. Every screen that needed the arrow now takes the inferred value on
these sports and says so in its footer. Never for a wing: a wing's fast
samples point wherever the wind sent them.

**The deck is rougher on a wave than off it.** Measured on test-12, the
vertical-acceleration spread was 2–5 m/s² paddling and 6–13 riding — the
quiet-board rule threw out every wave. `ridesAreRough` turns the rule off for
these sports; the flights already used the accelerometer where it answers
well. The same fact reached the foil detector: its roughness veto stopped
the second wave's flight from *starting* for twenty seconds at six and seven
metres a second. `FoilDetector.motionVetoesFlight` is off for these sports,
because a paddled foil has no displacement-planing case to guard against.

**Slowing down is not the wave letting go.** A bottom turn scrubs a knot and
a half in two seconds and the next section gives it back; the
deceleration gate fired on every one. `ridesSlowAndRecover` drops it. What
still ends a ride is the floor and the turn back out.

**Direction does not decide what a ride is.** A first version kept a cone
— widened to 120°, with cutbacks bridged — and it found test-12's waves
only because the inferred swell happened to point along them. The moment
the rider set the real swell, from the south-south-east, the same two
long waves came out as four pieces of five to seven seconds: a surfer
rides *across* the face, down the line, and cuts back through every point
of the compass. The rider's own rule is the right one — *"we're just
trying to measure the rides they have while they're on foil with the
increased speed"* — so `ignoresDirection` drops the per-sample cone, the
bridge angle and the net-bearing test as conditions for riding.
(`bridgesAnyTurn` stays for the gap-bridging inside the carve tolerance.)

**Direction has one job: telling the pump from the ride.** The rider's
map of test-12's first wave showed what a link looks like on this foil:
a catch ridden north for four seconds, a turn, **fifteen seconds
south-south-east at six metres a second — straight back into a swell from
the south-south-east — and a second wave ridden north**. The pump never
slowed down, so no speed rule could see it; its heading is the whole tell.
`splitsAtPumps` therefore cuts a riding run in two places: where a
five-sample median of speed sits below `pumpFraction` (0.7) of the wave's
own typical speed for `minimumPump` (4 s), and where the course sits
within `againstSwellAngle` (60°) of the swell's *from* bearing for
`minimumPumpAgainst` (8 s), two-second wobbles allowed. A cutback swings
through the same arc for two or three seconds and is left as the wave.
What comes out of a pump is the next ride, **linked**, and its catch is
measured against the lull the previous wave rose out of — on a paddled
foil the carry lasts as long as the flight, because a wave caught off a
fifteen-second pump at ride speed shows no rise over the pump. The
shortest named ride is three seconds on these sports, because that first
catch was ridden for four, and every wave is a row on the Runs tab
however short (the ribbon's fifty-metre lane floor is off for them).

With the rider's swell (from 157°) test-12 reads: wave 1 → ride 974–978,
pump 979–995 (105 m), ride 996–1038 linked; wave 3 → ride, a nine-second
pump east-south-east, ride, a twelve-second pump south, ride — 6 rides, 3
linked, 3 pumps, 35 s / 230 m pumping. The rider confirmed the first
wave's shape; the second pump in wave 3 is the one to ask about. With the
swell inferred (see below) it reads 5 rides, 2 linked, 2 pumps, and that
is what the expectation record pins.

**So the swell direction matters again, and the inference had to get
better.** The old reading — every fast flying sample, speed-weighted —
said the swell came from 240° on test-12, eighty degrees off the truth,
because the rides ran along the beach. `inferredSwell` now reads the
**drop-ins**: the first four seconds of each ride found by a direction-free
pass, when the board is going with the wave before the rider turns down
the line, weighted by each ride's length. On test-12 that says 199°, and
finds the first wave's pump on its own. The old reading stands in when
there are no rides. The Wave Rides footer says the swell was "read from
the way you dropped in" and tells the rider to set it if the pumping
looks wrong.

**The ride is the unit; the waves are how it breaks down.** "Ideally, a
user wants to see that they caught a wave, pumped back out to another
wave, and then caught another one" — as *one* thing. `WaveChain` groups
each wave with the linked waves after it and the pumps between; the Runs
tab and the Wave Rides screen show chains by default ("3 rides · 5
waves") and a shared toggle (`waves.together`, Rides / Waves) breaks them
into the waves, with the pumping shown as an orange break between two
waves of one ride. On the Runs tab a ride row says "2 waves · pumped
14s"; on Wave Rides a ride row says what was ridden, how many waves, and
how far and long the pumping was. The expectation record's `runsWave`
counts rides (the default), `waves` counts waves.

**Pumping is drawn and added up.** Every stretch on the foil that was not
a wave — between two linked waves, or out to one that never came, up to
the touchdown — is a `PumpStretch` on the summary, only for these sports
(on a wing, flying without a wave is sailing). The Wave Rides map draws
them in orange under the teal rides; they run the opposite way, which is
what makes the two read apart. The summary card adds them up as distance
and time on the foil between waves, and the expectation record carries
`pumpTime` where there was any. Two seconds is the shortest pump named.

**And on these sports a run is a wave.** `SessionAnalyzer.waveRuns` replaces
the heading segmenter — which had cut each long wave into five "runs" at the
carves — with one `Run` per wave, marked `isWave`, so the ribbon, the map
and the Runs tab describe the same water as this screen. The Runs tab lists
them as **Wave · n**, never merges two waves that share a flight, and the
expectation record carries `runsWave`. test-12 pins it: 3 waves, 3 runs,
2:41 riding. Sign-off from the rider is pending in `testdata/test-12.md`.

## 8. What was fixed on 4 September 2026

- **Back-to-back waves were lost.** A wave caught inside the rise window of
  the last one's kick-out is now measured against the lull that wave rose out
  of, and marked *linked* on the card, the list and the footer. Five of
  test-11's twenty-five are linked; before, they were the ones missing.
- **A ride began at the cruise, not the catch,** and a steady jittery run read
  as one long wave. The rise is now judged at the catch, on medians, against
  a bar that scales with the trace's own noise — and more conservatively when
  the speed was derived from positions. Tested on synthetic jitter at four
  levels and on six real recordings.
- **The downwinder had no way in.** The wave finder needs a swell arrow, and
  on a river the swell is the wind. *Bumps with the wind* on the empty screen
  sets the swell direction to the wind's in one tap, with no re-analysis.
- **The map badge pointers** now turn against the map's heading, so they keep
  pointing at the world when the map is rotated. The Upwind screen's wind and
  course badges got the same fix.
- **The expectation harness** records wave counts for any recording with a
  swell direction. Six tests added.

## 9. What was fixed on 3 September 2026

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
