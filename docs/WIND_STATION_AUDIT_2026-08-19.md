# Wind-station audit — 2026-08-19

The first sweep under [WIND_MAP_RULES.md](WIND_MAP_RULES.md), run with
`scripts/audit-wind-stations.py --sweep 16 --radius 40`. It covers R2
across the whole registry and R1/R3/R5 over the sixteen busiest clusters
in it — the water where all but a tail of the 990 curated rows stand.

**Result: no violations.** Five bugs were found and fixed to get there,
four of them in the app and one in the audit itself.

## The registry, as it stands

990 documents across 115 countries. 475 are United States, where the free
networks the app reads have coverage; the rest are identity and links
only, because NWS, NDBC and CO-OPS stop at the border and this audit
cannot answer R1 or R3 outside it.

Registry-wide, 826 rows are paywalled and 164 readable without an account.
That ratio is not evenly spread, and the spread is the finding:

- **New York and the East End** — 16 to 25 of every 30-odd curated rows
  resolve onto a free government sensor. The 2026-08-17 bulk import was
  largely CWOP citizen stations that NOAA already publishes.
- **Everywhere else** — Oregon 0 of 17, California 0 of 14, Hawaii 0 of
  11, Alabama 0 of 12, Connecticut 1 of 83. Almost every row is a genuine
  subscription instrument with no free twin.

So the free-versus-paid problem that started this work was a New York
problem, and the fix is worth the most exactly where the riders reporting
it are.

## The sweep

| Cluster | State | Free found | Pages | Curated | Resolve to free | Locked | Reporting |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 40.50,-73.50 | NY | 32 | 1 | 66 | 25 | 7 | 27/32 |
| 41.00,-73.00 | NY | 34 | 1 | 56 | 22 | 0 | 24/34 |
| 41.00,-73.50 | CT | 33 | 1 | 83 | 1 | 1 | 25/33 |
| 40.50,-74.00 | NY | 53 | 2 | 40 | 19 | 11 | 24/40 |
| 41.00,-72.50 | NY | 19 | 2 | 36 | 16 | 3 | 14/19 |
| 45.50,-121.50 | OR | 97 | 2 | 17 | 0 | 17 | 36/40 |
| 38.00,-122.50 | CA | 41 | 3 | 14 | 0 | 14 | 38/40 |
| 28.50,-80.50 | FL | 71 | 3 | 13 | 1 | 13 | 39/40 |
| 40.50,-73.00 | NY | 22 | 2 | 32 | 16 | 3 | 19/22 |
| 30.50,-87.50 | AL | 37 | 1 | 12 | 0 | 12 | 22/37 |
| 21.00,-156.50 | HI | 99 | 1 | 11 | 0 | 11 | 29/40 |
| 41.00,-72.00 | NY | 12 | 2 | 28 | 11 | 6 | 9/12 |
| 21.50,-158.00 | HI | 140 | 1 | 8 | 0 | 8 | 17/40 |
| 41.00,-74.00 | NJ | 91 | 1 | 24 | 1 | 1 | 18/40 |
| 33.00,-117.50 | CA | 24 | 6 | 10 | 0 | 10 | 17/24 |
| 27.50,-82.50 | FL | 41 | 2 | 9 | 0 | 9 | 20/40 |

"Reporting" is capped at the forty nearest stations per cluster, which is
why it reads /40 wherever discovery found more.

## What the sweep found, and what was done

**A gust is a reading, and so is zero.** `TT587` was sending nought mean
gusting four knots, `E6131` nought gusting three-and-a-half — the weather
service writes these `0G4`, and a rider reads them as a puffy afternoon.
The app required a mean wind speed and threw the gust away, so those pins
went bare. A pin now shows the mean alone, or `mean`G`gust` when the gust
stands three knots or more above it. On the East End this moved reporting
from 13 of 26 stations to 19 of 26. **R4 rewritten to say what counts as
an answer.**

**The newest record is not always the newest reading.** These sensors file
partial reports, and `observations/latest` returns the newest *record* —
which may hold only pressure and temperature. The reader now walks the
recent history for the newest record actually carrying wind before calling
a station silent.

**A sheet said "not reporting" over a number it had just fetched.** The
access line read the map's cached observation while the reading came from
the sheet's own fetch. Both now read the same value.

**One mast, two records, one of them dead.** The weather service carries
Montauk twice, as `MTKN6` and `NDBCMTKN6`, ninety metres apart; on the
night of the audit the first read 5.2 kn and the second nothing.
Deduplication ran only *across* networks, so the silent record survived as
its own pin. Every record now goes through the same matcher, and the
loser's address is kept as an alternate the reader falls through to.

**California's index runs sixteen pages.** The app read three, so it saw a
fifth of a state whose pages are ordered by nothing useful — the station a
rider is standing beside can be on page twelve. Paging is now driven by
sufficiency rather than a fixed depth: it stops once forty stations are
found within fifty kilometres of the rider, and San Francisco settles in
three pages while a thin coast may walk to the sixteen-page bound. A
cached index is only reused for a point it still holds hardware near,
because an index that stopped early over San Francisco knows nothing about
San Diego.

**And one bug in the audit.** Its first R4 check flagged any silent
station with a reporting twin, which is a fact about NOAA's data rather
than about the app. It now mirrors the app's 150-metre merge threshold: a
twin the app absorbs prints as handled, and only an unmergeable pair
counts as a violation.

## Open

- **Outside the United States, R1 and R3 are unanswerable.** 515 of the
  990 rows sit where this audit has no free network to check them against.
  Closing that means a source with global coverage — Synoptic or MADIS,
  both key-gated — or accepting that the map abroad is curated links and
  model wash.
- **Tempest-only hardware has no free door.** `EW9356 Hampton Bays` is the
  worked example: on iKitesurf, not in CWOP, not in NWS. Those pins stay
  commercial, and correctly so.
- **826 rows are paywalled and most will stay that way.** Where a
  paywalled row turns out to stand on free hardware the audit prints it
  under R2; none did in this sweep outside a single Florida row.
