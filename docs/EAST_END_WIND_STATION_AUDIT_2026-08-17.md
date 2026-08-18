# East End Long Island wind-station audit — 2026-08-17

This audit applies the rules in [WIND_STATIONS.md](WIND_STATIONS.md). The
working bounds are `40.70–41.30 N, 72.70–71.70 W`, covering the East End,
adjacent Long Island Sound approaches, and nearby offshore stations useful to
East End riders.

## Sources checked

- NWS `/points/{lat},{lon}/stations` discovery and latest-observation API.
- NOAA NDBC active-station inventory.
- NOAA CO-OPS meteorological-station inventory.
- iKiteSurf's public East End map/inventory and anonymous station response.

## Results

- 181 iKiteSurf-listed station candidates were found inside the bounds.
- 146 currently report that useful wind speed requires paid membership.
- 25 expose some current wind through the anonymous/freemium response.
- 10 could not be assigned free versus paid from the current response and are
  explicitly `unknown`.
- Underlying iKiteSurf networks: 157 Tempest, 4 Professional, 2 HurrNet,
  2 ASOS, and 16 unspecified.
- Four authoritative free stations expose current wind observations:
  `KFOK`, `KJPX`, `KMTP`, and `MTKN6`/NOAA `8510560`.
- iKiteSurf also represents `KFOK`, `KJPX`, and `KMTP`; those entries are
  marked as alternate representations of the canonical free government
  station, not additional physical instruments.

NOAA buoys `44017` and `44039` were present in the active inventory but did
not expose a current wind observation during this audit. They remain buoy/wave
resources and were not mislabeled as wind stations.

## Notable coverage

The premium inventory adds meaningful local instruments beyond the airport and
NOAA network, including Napeague, Mecox Bay, Noyack Bay, Shinnecock Light,
Southold, Orient, Orient Point, Gull Pond Ramp, Great Gull Island, Hampton
Bays, and Fishers Island. It also includes many residential/personal Tempest
stations. Their presence improves density but does not establish marine-grade
siting, calibration, exposure, or long-term availability.

## Firestore publication

All 181 iKiteSurf inventory entries and the four free official stations were
published to `windStations` with exact provider coordinates and explicit
classification fields. Existing East End records were corrected from
foil-spot-derived coordinates to provider station coordinates.

The registry records provider coverage; it does not redistribute restricted
observation history. App presentation should deduplicate entries sharing a
`canonicalDuplicateOf`, clearly label premium access, and rank stations using
freshness, distance, instrument quality, and exposure—not proximity alone.

Machine-readable evidence is maintained with the database tooling as
`east_end_long_island_wind_station_audit_2026-08-17.json`.

