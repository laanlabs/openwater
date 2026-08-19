# What the wind map draws

Rules for the wind-station layer: what a pin may say, when it wears a
lock, and how to find the places it lies.

The registry's own rules — what a document may hold, how a station is
identified, what may be stored — are in
[WIND_STATIONS.md](WIND_STATIONS.md). This file governs presentation, and
every rule in it is here because the app broke it once. They are checked
by `scripts/audit-wind-stations.py`, which names them by number.

## The rules

**R1. A number on the map is a measurement.** A pin carries a wind speed
only when the app fetched that reading from that instrument and it is
under three hours old. Nothing else earns a number on the map: not a model
at the station's coordinate, not a neighbour's reading, not in grey, not
in any other styling. At arm's length on a moving map a number is a
number, and the first thing a rider does with it is decide whether to
drive. A station the app cannot read, or one that is silent, is a pin
without a number.

The model may appear in the station's own sheet — greyed, and under the
sentence that says it is a model standing where the instrument stands —
and only for a station the app can never read. A station the app *can*
read shows nothing when it is silent: for a readable instrument silence is
the honest answer, and substituting a forecast is the fallback this
document already forbids one paragraph up.

**R2. The lock means paywalled, and only that.** A pin is locked when
`requiresSubscription` is true and `guestWindVisible` is not — the
registry's classification decides it, never the provider's reputation.
Most commercial rows are not locked; on the East End roughly one in eight
is. A locked pin never carries a number, because a number reads as an
offer and the lock is there to say the opposite. An unclassified row —
neither `accessTier` nor `requiresSubscription` — is a registry bug, not a
presentation decision, and the audit reports it as one.

**R3. One instrument, one pin, free side up.** Where a curated row and a
free station are the same hardware, the free station is the pin and the
commercial page becomes a link on it. Same hardware means within 250 m, or
sharing a CWOP call sign: the guide writes "FW2389 Orient NY US" where the
weather service files `F2389`, dropping the second letter, and that one
difference is what let a single anemometer stand on the map twice at two
prices. Both doors stay — a rider who subscribes still wants their own
network's page.

**R4. Never say "not reporting" without asking, and know what counts as
an answer.** The claim that a station is silent requires a completed fetch
of that station, in this session, on every feed it appears on. A miss in
the map's own cache is a fact about our timing, not about the anemometer:
Montauk read five knots while a sheet said it was not reporting, because
the pin was tapped before its turn in the queue came round. Where one mast
appears on more than one network — NWS, NDBC and CO-OPS all carry Montauk
— a silent primary is not silence until the siblings have been tried.

Three things count as an answer, and each was once thrown away:

- **A gust on its own.** A station reading zero mean and gusting four is
  reporting; the weather service's own page writes it `0G4`, and a rider
  reads that as a puffy afternoon. Dropping it because the mean was
  missing turned the most useful number on the pin into a blank.
- **Zero.** Calm is a measurement. A station that says nothing and one
  that says nothing is blowing are different claims, and only one of them
  should leave a pin bare.
- **A record further back than the newest one.** These sensors file
  partial reports: `observations/latest` returns the newest *record*,
  which may carry only pressure and temperature. The recent history is
  walked for the newest record that actually holds wind before the station
  is called silent.

A pin shows the mean alone, or `mean`G`gust` when the gust stands three
knots or more above it — the difference between a steady five and a five
gusting eleven is the difference between a session and a swim.

**R5. Discovery is complete before it is capped, and "enough" is not
"nearest".** Follow a paginated index to its end, or to a bound stated in
the code, before filtering by distance: half of New York's stations are on
page two, including the three nearest to Sag Harbor.

Stopping early once enough stations have been found is a legitimate way to
get a map on screen and an illegitimate way to finish. The pages are
ordered by nothing useful, so an early stop keeps an arbitrary subset: of
the forty stations genuinely nearest downtown San Francisco the app once
held four, missing the closest at six hundred metres and Fort Point at
five kilometres, while reporting forty-one stations found and looking
perfectly healthy. An index that stopped early is therefore finished in
the background and written back, and it records whether it is complete so
nothing downstream has to guess. The background finish refuses cellular,
personal hotspots and Low Data Mode: California is eight megabytes, and a
rider checking the wind from a car park did not ask to spend that. It
comes back incomplete, waits ten minutes, and tries again wherever they
land — completeness is worth having, not worth taking.

Caps on how many readings are fetched are a separate decision from how
many stations are found, and neither may silently truncate the other. Any
cache whose completeness changes gets a new filename, or the fix ships to
nobody who already has the old one.

## The audit

`scripts/audit-wind-stations.py` runs the behaviour audit for any water.
It rebuilds discovery the way the app does, resolves the registry against
it, reads every station in reach, and exits non-zero with one line per
violation of R1–R5.

What it catches, in the order the rules are numbered: stations the map
would label from a model rather than an instrument; rows whose lock
disagrees with their own classification, and rows carrying no
classification at all; commercial pins standing on free hardware; masts
called silent while a sibling feed reports them; and an index truncated by
pagination. Its first run over the East End found the Montauk sibling
case, which is the one class of bug none of the earlier registry audits
could have seen, because it is not a fact about the registry.

### Running it

```
scripts/audit-wind-stations.py --centre 40.99,-72.29 --radius 60
```

`--skip-readings` does the structural checks only, without asking every
station in reach what it is doing; without it the run takes a minute and
prints the live board as well.

Run it when a rider reports a wrong pin, after any change to discovery,
classification or deduplication, and over a new region before curating it.
Exit status is the number of violations, so it can gate a release.

### What each rule cost, the first time

Kept because a rule with its incident attached is harder to argue away
than a rule without one.

| Rule | The bug | The evidence |
| --- | --- | --- |
| R1 | A silent government sensor showed a model estimate under the NWS's own name | `FW4448 East Hampton`, "not reporting" beside a 5 kn figure |
| R2 | Every commercial row drew the same pin, so 129 freely-readable stations looked paywalled | East End: 181 rows published in one import, ~1 in 8 actually locked |
| R3 | One anemometer stood on the map twice at two prices | `FW2389 Orient` and NWS `F2389`, 0 m apart |
| R4 | A mast was called silent while another feed reported it | Montauk: NWS `MTKN6` 5.2 kn, NDBC `MM`, CO-OPS 1.9 kn |
| R5 | A paginated index stopped after one page and a week-long cache kept serving it | 13 of 24 stations near Sag Harbor; East Hampton, Southold and Orient all on page two |
| R5 | Stopping on "enough stations" kept an arbitrary subset, not the nearest | 4 of the 40 nearest to downtown San Francisco; closest missed at 0.6 km |

### Regional inventory audits

The behaviour audit above answers "is the app drawing this correctly".
A registry audit answers "does the registry know about everything here",
and the procedure for one is in
[WIND_STATIONS.md](WIND_STATIONS.md#discovery-and-coverage-audits). The
[East End audit](EAST_END_WIND_STATION_AUDIT_2026-08-17.md) is the worked
example — and the source of most of the incidents in the table above.

Behaviour audit records live beside this file too. The first is
[2026-08-19](WIND_STATION_AUDIT_2026-08-19.md), a sweep of the sixteen
busiest clusters in the registry that found five bugs and closed them.
