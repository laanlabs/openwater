# What a run is

The Runs tab exists to answer one question a map cannot: **what did I
actually do out there?** A GPS track of a lapping afternoon is spaghetti —
two hundred crossings of the same water, and no way to see that forty
minutes of it was beating upwind and eight minutes was the one long reach
you remember. The tab turns the track into a list a rider can read in five
seconds:

- how many downwind runs, and how long each was
- where you were tacking or gybing upwind, and how many legs that took
- where you were reaching across the wind
- and, between all of it, exactly how long you spent off the foil

Every rule below exists because a rider looked at a real session and said
the app was wrong. Where that happened, the session and the correction are
named — they are the evidence, and no rule here should be changed without
new evidence of the same kind.

---

## 1. The unit: a run

A **run** is one continuous stretch on one point of sail, ridden on one
side of the wind, between two interruptions.

The segmenter first cuts the track into **stretches** at every change of
direction. That is accurate and useless — test-5 is 246 stretches. Runs
are stretches grouped back up by the rules below.

`GroupedRun.group(_:flights:absorb:touchdown:reversal:)` in
`openWater/Views/GroupedRuns.swift`.

---

## 2. Which way you were going

Measured as the **true wind angle**: the angle between your course and the
wind, 0° being straight into it and 180° dead downwind. It is symmetric —
50° off to port and 50° off to starboard are both "50° upwind".

| | angle off the wind | |
|---|---|---|
| **Upwind** | 0° – 90° | you are making ground to windward |
| **Reaching** | 90° – 120° | across the wind, making ground neither way |
| **Downwind** | 120° – 180° | the wind is behind you |

**90° is the line because that is where windward progress stops.** Above a
beam reach you gain ground upwind; below it you do not. Both numbers live
in `UpwindLegFinder.upwindLimit` / `.downwindLimit` and are read from
there by the run list, so the Runs tab and the Upwind screen cannot drift
apart.

> **Learned the hard way, twice.** `PointOfSail` puts the upwind boundary
> at 55°, which is a sailboat number — a wing points nowhere near that. On
> test-8 the rider covered 8.2 km between 50° and 80° off the wind, every
> metre of it working upwind, and the run list called all of it reaching.
> Moving the boundary to 80° fixed the direction but not the bug: the
> Upwind screen still used 90°, so the two screens disagreed about every
> leg sailed between 69° and 78°. One word now means one number.

---

## 3. What ends a run

A run ends at the first of these.

### 3.1 The point of sail changes
Upwind becomes reaching, reaching becomes downwind. That is a different
kind of riding and belongs on a different row.

### 3.2 A tack — **upwind only**
Beating, a tack is a real change of course, and the legs either side of it
are the thing a rider counts. A beat tacks through about 100°, so this
does not fall out of the reversal rule below; it is checked explicitly on
the sign of the true wind angle, exactly as the Upwind screen does it.

**Upwind only, deliberately.** Downwind, weaving across the bumps crosses
the wind constantly and none of it is a change of course. Splitting there
would cut one river crossing into dozens of rows.

> **From test-8.** Nineteen upwind runs came back as one row. The Upwind
> screen found twenty-four legs on the same beat because it splits at every
> tack and the run list never did.

### 3.3 A touchdown — coming off the foil
A run is a ride. Landing ends it. See §4 for what counts as landing.

### 3.4 A reversal
A heading change of more than **120°** against the run's own
distance-weighted mean heading. This catches a turn the point-of-sail rule
misses.

### 3.5 Nothing else
A stretch shorter than **60 m** is absorbed into the run it interrupts
rather than ending it. That is the turn itself, not a change of course.

---

## 4. Off the foil

Time off the foil is a first-class row in the list, not an absence. Every
second between the first fix and the last belongs to exactly one row — a
run or an off-foil break — and they sum to the session duration.

Off-foil rows appear **before the first run, between every pair of runs,
and after the last**, and inside a run when you open it. Each one is
tappable and shows on the map where it happened.

### 4.1 Flying
Two signals, because neither alone is enough:

- **Speed** above the sport's takeoff speed — 4.5 m/s (8.7 kn) for
  wingfoil and parawing. Below it you cannot be flying.
- **Vertical acceleration.** A board on the water slams through chop; a
  board in the air does not. Where the watch recorded motion, this
  dominates.

`FoilDetector`, `OpenWaterCore/Sources/OpenWaterCore/Analysis/FoilDetector.swift`.

### 4.2 What is *not* a landing

| | |
|---|---|
| under **1.5 s** | clipping a wingtip |
| under **5 s** and never below 70% of takeoff speed | a lull, not a landing |
| never fell through the exit band at all | roughness, not a landing |
| **gaps shorter than 20 s** between two flights | see below |

**Twenty seconds is the rider's number, not ours:**

> a person would not fall for just a second or two — it takes like at least
> 20 - 30 seconds to fall and get back up

`SportThresholds.foilMinimumRecovery`. Flights separated by less than this
are joined into one ride for counting and for splitting runs. The gap is
kept on the flight as a **dip**, so the speed chart still shades it, a gybe
through it still counts as wet, and it is still subtracted from time on
foil. *How many rides* and *were you up at this instant* are different
questions and are answered from the same data without contradicting each
other.

> **From test-11.** Thirty-five flights on a session the rider describes as
> one continuous ride, with twenty-four of the twenty-nine gaps under
> twenty seconds. Joined: ten.

---

## 5. What ends a *leg* — point-to-point sessions

On a downwinder or a crossing the top level is not the run but the **leg**:
the whole descent, with the runs inside it. A leg ends where the rider
**stopped** — their speed fell below the sport's moving speed — or where
they were **carried** (a transport jump of 800 m, or a two-minute silence
and a 400 m jump: the drive back up the road on a shuttle day).

**Stopping is about how slow, not how long.** On test-11 the rider dropped
off the foil nine times; eight of those bottomed out at 3–6 knots, still on
the board, sinking off the foil and pumping back on. The ninth bottomed out
at **0.2 knots**, which is a person in the water — and it is the only one
the rider counted.

**And the seconds below the bar count in total, not in a row.** A swimmer
in open water does not read as still: on test-1 — 28 knots and nine feet of
swell — every one of eight swims bottomed out between 0.3 and 1.7 knots,
but the bobbing spiked the GPS over the bar every few seconds, and a rule
that wanted twenty consecutive quiet seconds found one swim in eight and
called a session of nine rides two runs. The floor is
`SessionShapeAnalyzer.stopDip` — three seconds below the bar in total,
enough to rule out one bad fix and nothing more. The pumping rider it must
not catch never touches the bar at all: 2.9 knots was the slowest moment in
any of test-11's nine gaps.

Two consequences keep the sharper stop test honest, both found on test-6,
the shuttle day:

- **A leg never splits inside a flight.** The flights arrive already joined
  across gaps too short to be a fall — the rider's own twenty seconds, §4.2
  — so a dip below the moving floor with the ride carrying on either side
  of it is a moment inside one ride, not one row ending and another
  beginning.
- **A leg that never flew is not a leg.** Splitting at stops leaves the
  drift between two swims standing on its own — 57 m at three knots. Real
  time, real distance, and the *between* of the session: it belongs to the
  off-foil gap separating the legs either side, not to a row of its own.

---

## 6. Every test session against these rules

Recorded by `scripts/record-expectations.sh`; the machine-checked copies
are in `openWaterTests/Expectations/`.

| | sport | duration | km | shape | legs | downwind | reaching | upwind | flights | on foil | falls | stretches |
|---|---|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| test-1 | wingfoil | 50:05 | 13.66 | Downwinder | **9** | 9 | 6 | 0 | 9 | 78% | 2 | 38 |
| test-2 | wingfoil | 23:27 | 6.19 | Downwinder | 6 | **6** | 0 | 0 | 6 | 78% | 1 | 11 |
| test-3 | wingfoil | 1:30:24 | 29.87 | At one spot | 3 | 8 | 49 | 64 | 4 | 96% | 0 | 141 |
| test-4 | wingfoil | 2:38:15 | 44.91 | At one spot | 3 | 11 | 59 | 117 | 4 | 92% | 2 | 202 |
| test-5 | wingfoil | 2:15:11 | 46.21 | At one spot | 7 | 48 | 31 | 156 | 7 | 94% | 2 | 246 |
| test-6 | wingfoil | 1:49:02 | 24.45 | Downwinder | 14 | 20 | 6 | 1 | 17 | 59% | 3 | 82 |
| test-7 | wingfoil | 1:25:58 | 29.88 | At one spot | 5 | 5 | 43 | 67 | 8 | 93% | 0 | 117 |
| test-8 | wingfoil | 1:24:13 | 17.30 | At one spot | 6 | 5 | 2 | **26** | 8 | 77% | 2 | 67 |
| test-9 | parawing | 8:50 | 3.24 | Downwinder | **1** | 1 | 0 | 0 | 1 | 100% | 0 | 18 |
| test-10 | wingfoil | 1:01:18 | 16.94 | At one spot | 7 | 1 | 19 | 21 | 7 | 91% | 3 | 43 |
| test-11 | parawing | 45:19 | 10.79 | Downwinder | **2** | 13 | 3 | 0 | 10 | 67% | 1 | 71 |

### What each session is, and what it proves

**test-1** — *The ocean reference.* A downwinder in nine rides — seven
downwind rows and two brief reaches on the tab — with a swim between every
pair: all eight gaps bottom out between 0.3 and 1.7 knots, a person in the
water every time. In 28 knots and nine feet of swell none of those swims
read as *still*, which is the session §5's total-not-consecutive stop rule
was written from; before it, this reported as two rows. The rider's own
count from the map was "probably six or seven".

**test-2** — *Guardrail.* The cleanest downwinder in the set: straightness
0.91, 0° off dead downwind, six downwind runs and **nothing else**. If a
change makes this anything other than six downwind, the change is wrong.

**test-3, test-4, test-5, test-7** — Long lapping afternoons, 1½ to 2½
hours. These are the spaghetti the tab exists for: 141 to 246 stretches
collapsing to a readable list dominated by upwind legs, which is what a
rider working back and forth across a river actually does.

**test-5** is the extreme case — 246 stretches, 46 km, 235 runs. The
grouping and the cluster rows are what keep it usable.

**test-6** — Shuttle day. Fourteen rides, 59% on foil: the lowest in the
set, because the drives back up the road are in the recording — they are
the longest of the off-foil gaps between rows. Both of §5's consequences
were found here: the stop test alone tried to split legs at eight-second
dips inside a ride, and to give the drift between two swims — 57 m at
three knots — a row of its own.

**test-8** — *The upwind reference.* Twenty-six upwind runs against the
Upwind screen's twenty-four legs. The remaining two are the run list also
breaking at touchdowns, which the leg finder does not do. Both §2 and §3.2
were written from this session.

**test-9** — *Guardrail.* One parawing run down the river, 100% on foil,
one flight, no falls. **One leg, one run.** Anything that fragments this
is wrong.

**test-11** — *Signed off by the rider* (see `testdata/test-11.md`). Two
rows on the tab — the legs, §5 — both downwind: a short first ride, a swim,
then 9.55 km down the river. Off-foil rows of 12:33, 1:00 and 2:53 either
side of them, summing with the runs to exactly 45:19. Inside those two
rows the 71 stretches still group into 13 downwind and 3 reaching runs,
which is what the run columns above count. Zero jumps.

---

## 6.1 Made good: toward the wind, or toward where you were going

VMG is progress along an axis, and the default axis is the wind's — the
number a rider compares across sessions. The Upwind screen also lets them
change two things about it, both stored on the session and both re-running
the analysis.

**A course** (`Session.courseDirection`, degrees *toward*). On a river the
wind's bearing is a bank: at Rufus the wind comes from 258° and the Columbia
runs at about 240°, so a rider working up the gorge is not trying to reach
258°. With a course set, the beat, the run and every leg's made-good are net
displacement toward the course instead of toward the wind. Which samples
*are* upwind, and which tack, stay measured to the wind — a course changes
what counts as progress, not what counts as a leg. `nil` means the wind.

**A chosen stretch.** The best beat is the finder's pick: the best kilometre
with real distance on both tacks. Tapping one leg and then another measures
the stretch between them the same way — net displacement over elapsed time,
tacks and wobbles included (`PolarAnalysis.BothTacksVMG.measured`). The
selection is always contiguous, because a beat is a stretch of time and a
stretch skips nothing: legs 10 to 21 on test-8 straddle a run back down the
river and read as 0.4 kn, and the card says why rather than hiding it.
Legs 14 to 18, sailed back to back, read as 4.9 kn toward 240°.

## 7. Where the rules live

| rule | code |
|---|---|
| Upwind / reaching / downwind bands | `UpwindLegFinder.upwindLimit`, `.downwindLimit` |
| Run grouping, tack split, absorb, reversal | `GroupedRun.group` |
| Flying, touchdowns, dips, recovery | `FoilDetector` |
| Legs, stops, transport jumps | `SessionShapeAnalyzer` |
| Per-sport speeds and floors | `SportThresholds.forSport` |
| Best beat, and a chosen stretch measured the same way | `BothTacksVMGFinder`, `PolarAnalysis.BothTacksVMG.measured` |
| The made-good axis (the wind, or a course) | `Session.courseDirection`, `Wind.madeGoodAxis` |

An analysis change means bumping `SessionSummary.currentVersion` and
re-running `scripts/record-expectations.sh`, then reading the diff on
`openWaterTests/Expectations/` — that diff is the change, stated in the
numbers a rider reads.
