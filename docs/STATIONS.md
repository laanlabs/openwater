# Where station data lives

Three kinds of sensor reach the conditions sheet — wind stations, tide
stations and buoys — and the question of where each is stored keeps coming
up, most recently when the New York Harbor fix made the app read NOAA's buoy
centre index for wind. This document is the answer, and the rule that
generates every line of it:

> **Identity is storable. Readings are not.**
>
> *Identity* — that a station exists, where it stands, what to call it, who
> serves it, which apps can open it — changes when NOAA commissions hardware
> or a network signs a new site, which is to say a few times a year. It can
> be cached for a month, shipped in a bundle, or curated in Firestore.
>
> *Readings* — what the sensor said in the last hour — are the entire value
> of the row. They come live from the source on every look, are never
> cached beyond the session, and **never touch Firestore**. This is already
> doctrine in `ForecastCache.swift` and it does not bend here.

Applied to sources, the rule collapses to one sentence: **free APIs for
everything a government publishes; Firestore only for what has no API;
readings never stored anywhere.** NOAA's feeds are keyless, static, and
self-healing — when they commission a sensor it appears, when they retire
one it vanishes, and nobody here maintains anything. Firestore earns its
place only where no such feed exists: the iKitesurf registry, the guide,
spot-linked tide curation. Identity that a free API already serves is a
bill plus a staleness bug, redeemable for nothing.

This is not a theory; it has been tested. On the night of 2026-08-17 an
automated writer copied 689 NDBC platforms, 220 NWS stations, and a
provider's residential inventory into `windStations` — every shape this
document forbids. The app never read the mirrors for discovery, riders
paid to download them, and all 1,487 were deleted the next day. The rules
for automated writers now live in
[REGISTRY_WRITERS.md](REGISTRY_WRITERS.md).

Everything below is about identity. The reading paths are untouched.

## The decision, per kind

| | Identity comes from | Readings come from | Our Firestore role |
|---|---|---|---|
| **Wind stations** | Our registry ∪ NOAA's two free feeds | NWS / NDBC live; paid networks link out | Curated station docs with government cross-links |
| **Tide stations** | Spot-linked guide docs, then NOAA CO-OPS index | CO-OPS predictions, live | Already shipped: per-spot `tideStations` links |
| **Buoys** | NDBC `activestations.xml` | NDBC realtime files, live | **None** |

## Wind stations: the one kind that is genuinely ours

Wind is the only kind that lives in two worlds. Government stations are
free, discoverable from NOAA's feeds, and readable in-app. Network stations
— iKitesurf/WeatherFlow above all — are none of those things: there is no
free index of them, their readings are behind a subscription the app does
not resell, and their value to a rider is the *link*. A lot of our riders
pay for iKitesurf. When they see that station on our map they want to tap
it and land in the app they already own. That link, and the knowledge that
the station exists at all, has to come from somewhere we maintain — so wind
stations get a registry in Firestore.

### Mirror the identity, not the data

The registry does **not** copy NOAA's station list into Firestore. The
free feeds stay the discovery path for government stations — they are
static files and keyless endpoints, cached on-device for a month
(`DataBuoyCenter.loadIndex` in `NearbyConditions.swift`), and they update
themselves when NOAA changes hardware. Copying them buys a sync job, a
staleness bug that is ours instead of one that heals in 30 days, and a
Firestore read bill for data NOAA serves free. It is the wrong kind of
mirror.

What the registry mirrors is the *cross-link*: the fact that a station in
our list **is** a government sensor. Plenty of what a paid map shows is a
NOAA anemometer rebadged — iKitesurf lists government stations beside its
own hardware — and since the general fix started surfacing NDBC's piers and
PORTS masts, the same physical sensor can now arrive from both directions:
an orange guide pin from Firestore and a free NDBC pin from the feed. The
registry is where the two are declared to be one thing.

```
windStations/{id}
  name        "Fort Point"
  lat, lon    37.807, -122.466
  countryId   "US"                    // the query key the guide already uses
  gov         { nws: "FTPC1", ndbc: "ftpc1" }   // present ⇒ free live reading
  providers   [
    { provider: "ikitesurf", id: "…",
      web: "https://wx.ikitesurf.com/spot/…" },
    { provider: "noaa",
      web: "https://www.ndbc.noaa.gov/station_page.php?station=ftpc1" }
  ]
  status      "active" | "hidden"
```

Merge rules, applied at render time:

- Pins key on the government id, case-folded, when there is one.
- A registry row **absorbs** the free-feed row with the same id: the
  curated name wins, the provider links ride along, and the rider sees one
  pin that can open in iKitesurf *or* show the free NOAA reading.
- A free-feed row with no registry row renders exactly as today. The
  registry is an overlay, never a gate — a station NOAA commissioned last
  week appears before any of us has heard of it.
- A registry row with no `gov` block is pure network: link-out only, no
  in-app reading, which is honest about what a subscription buys.

Readings for any row with a `gov` id come through `FreeStations.latest` —
which network answers is decided by the id, and Firestore is never in that
path.

All of this is shipped, not planned. `WindStationRegistry` fetches only
the rows carrying a `gov` block (an `IS_NOT_NULL` query — a handful of
documents, cached on disk for a week), `FreeStations.near` does the
absorb, and `NearbyConditionsSheet.dedupedMeters` collapses any duplicate
rows a writer manages to create — by NOAA URL station id, by the
registry's alias table, and by same-name-within-250-m — so the screens
stay right even when the database briefly does not.

The registry's document schema, classification fields, and the audit
procedure for growing it region by region are specified in
[WIND_STATIONS.md](WIND_STATIONS.md), which is subordinate to this
document where they disagree.

### What the registry holds after curation (2026-08-18)

~990 documents, every one of which qualifies under a rule somebody can
name: the gov cross-links, six independent stations, ~827 spot-linked
iKitesurf rows (the "nearest live station to this launch" mapping riders
tap through), and ~153 guest-readable iKitesurf stations whose wind shows
without an account. What was deleted — government mirrors and the
unlinked subscription sweep — is preserved verbatim in dated backups with
the database tooling, and any specific station can be re-added
deliberately, which is what curation means.

### Read cost

Two Firestore reads exist, with different bills. The registry read
(`FreeStations`) is a handful of gov-linked documents per week — free in
practice. The guide's meters read fetches `windStations` country-wide per
session (~475 US documents after curation, memory-cached only) — this is
the number curation protects, the reason the scale rule exists, and the
place a disk cache would help next. A mirror would have pushed it back
into the thousands.

## Tide stations: already right, already shipped

This one sounds like wind — government source plus curated links — but the
paid-provider problem does not exist. CO-OPS is complete for US waters,
keyless, and its predictions are free to fetch; there is no tide equivalent
of iKitesurf that our users separately subscribe to. So the shipped
architecture stands:

- Spots that know better link `tideStations` documents in Firestore, and
  the guide's tide-chart links render beside NOAA's.
- Everywhere else, discovery is the CO-OPS index — a 2 MB document boiled
  down once and kept on disk (`TidesAndCurrents.loadIndex`).

The trigger to grow the Firestore side is **non-US coverage**: CO-OPS stops
at the border, and the day the guide wants tides for Tarifa or Maui-scale
coverage abroad, curated tide station docs are the only way to have them.
The schema above generalises — same `countryId` scoping, a `gov` block
naming the CO-OPS id where there is one.

## Buoys: leave them in the government database

No registry, no mirror, and this is a decision rather than an omission.

- NDBC's index **is** the buoy list — every hull, pier and light tower with
  a met feed, kept current by the people who own the hardware. It is one
  static 272 KB file, cached on-device for a month, shared by both the buoy
  list and the marine half of the station list through a single in-flight
  fetch.
- There is no paid buoy network our users belong to, so there is no
  cross-linking job — the one thing that justified the wind registry.
- Which list a sensor lands in — buoy or wind station — is decided by what
  its own realtime row reports (sea state → buoy, wind alone → station,
  `DataBuoyCenter.windReading`). A hand-maintained list would fight that
  partition and lose: the data self-sorts, and a mirror would need to be
  told.

If curation is ever needed — a buoy that reads wrong, a name worth fixing —
it is an overlay document keyed by NDBC id, tens of rows, added the day a
real case appears and not before.

## The cache ladder, for reference

What stands between a rider and a network request, today:

| Data | Cache | TTL |
|---|---|---|
| Guide dataset + resources | disk, `spot-guide.json` + per-region memory | TTL'd, stale-served with background refresh |
| Country-scoped meters read | disk, `guide-resources-*.json` | 7 days, stale beats empty |
| NDBC station index | disk, `ndbc-stations.json` | 30 days, stale beats empty |
| Registry cross-links | disk, `wind-station-registry.json` | 7 days, stale beats empty |
| CO-OPS tide index | disk, `noaa-tide-stations.json` | until iOS purges caches |
| CO-OPS currents index | disk, `noaa-current-stations.json` | until iOS purges caches |
| Forecast responses | disk, `forecasts/` | per-answer TTL, 3 h stale limit |
| **Any observation** | **never cached** | — |

Below the ladder sits the floor: the app bundle ships distilled snapshots
of the NDBC, CO-OPS tide and CO-OPS currents indexes
(`openWater/Resources/*.json`, ~760 KB, regenerated by
`scripts/refresh-station-snapshots.sh` in each loader's own distilled
format), so a first-ever launch with no signal still knows where every
station stands. Snapshots are identity, and identity is storable.

## Sources evaluated

Networks looked at and what they turned out to be worth, so the next
person asking "can we not just read X" gets an answer instead of a
weekend. The three the app reads today — NWS, NDBC and CO-OPS — are
covered above.

### Esri Living Atlas: NOAA METAR and buoys

`https://services9.arcgis.com/RHVPKKiFTONKtxq3/arcgis/rest/services/NOAA_METAR_current_wind_speed_direction_v1/FeatureServer`
([map viewer](https://www.arcgis.com/apps/mapviewer/index.html?layers=cb1886ff0a9d4156ba4d2fadd7e8a139))

Esri's hosted live feed over NOAA's hourly METAR and buoy data. Public,
keyless, `Query` capability, two layers — `0 Stations`, `1 Buoys` — with
`WIND_SPEED`, `WIND_GUST`, `WIND_DIRECT` and `OBS_DATETIME` on both, and
`WAVE_HEIGHT` on the buoys. Verified 2026-08-19.

Speeds are **km/h**, not knots — `WIND_SPEED` and `WIND_GUST` both, per
the layer's own field aliases.

Two things make it worth keeping in mind. It is **global**: a bounding box
over Tarifa answers Gibraltar and Algeciras, Maui answers Kahului, Sydney
answers three. And it takes a **bounding box at all**, which is the thing
the weather service's own API has never offered — the whole state-index
apparatus in `NationalWeatherService.stateIndex` exists to work around its
absence.

What it is not is dense, and the measurement matters more than the
adjective. Across the ten busiest non-United-States clusters in the
registry, METAR inside forty kilometres comes to:

| Cluster | Registry rows | METAR ≤ 40 km | Nearest |
| --- | --- | --- | --- |
| 53.5,7.0 (Frisian coast) | 5 | 1 | EDWE, 20 km |
| 56.0,10.5 (Aarhus) | 5 | 1 | EKAH, 34 km |
| 54.5,13.5 (Rügen) | 5 | 0 | — |
| -41.5,175.0 (Wellington) | 5 | 1 | NZWN, 25 km |
| 18.5,-66.0 (San Juan) | 5 | 2 | TJSJ, 8 km |
| 24.0,-110.0 (La Paz) | 5 | 0 | — |
| 53.0,5.5 (IJsselmeer) | 4 | 1 | EHLW, 30 km |
| 47.0,7.0 (Swiss lakes) | 4 | 2 | LSGC, 18 km |
| -34.0,18.5 (Cape Town) | 4 | 1 | FACT, 10 km |
| -33.5,151.5 (Sydney) | 4 | 0 | — |

One aerodrome, twenty-odd kilometres inland, for about two thirds of the
spots and nothing at all for the rest. Inside the United States it adds
nothing: METAR is the airport layer NWS already serves, and the same
`KJPX`, `KHWV`, `KMTP` and `KFOK` come back from both.

**Not adopted, and the reason is the table.** A single inland aerodrome
half an hour from the water is the reading most likely to mislead somebody
deciding whether to drive — gradient wind at an airport is not the sea
breeze at the beach, and R1 exists because a number that looks measured
gets believed. Where the app has nothing abroad it shows model wash and
curated links, which is honest about being a model.

Revisit it if destination browsing abroad becomes a feature — "what is
Tarifa doing right now" is a question one distant airport answers better
than nothing. The cheap shape for that is an on-demand lookup in the
conditions sheet for a coordinate, not a fourth source in
`FreeStations.near` with its own cache, dedup and audit surface. Its
licence wants reading either way: Living Atlas feeds are free to use but
they are Esri's hosting of public-domain data, not NOAA's own endpoint.

### WeatherFlow Tempest

[Station map](https://tempestwx.com/map/139111/40.99/-72.3202/14) ·
[developer docs](https://weatherflow.github.io/Tempest/api/)

There is a free API and it will not answer for other people's hardware.
Every documented endpoint refuses an anonymous caller — observations,
station metadata and forecast all return `401 UNAUTHORIZED` (verified
2026-08-19) — and the docs are explicit that integrations are meant for
the personal use of a single Tempest owner, with anything reading many
locations directed to contact WeatherFlow. That is a commercial
conversation, not a key.

The public station map is not a way round it. It is a Firebase-backed web
client, and using its embedded key would be bypassing authentication to
scrape restricted readings — the two things
[WIND_STATIONS.md](WIND_STATIONS.md) forbids by name.

What is free and clean is the owner path: a rider who owns a Tempest can
mint a personal access token and the app could read *their* station as a
measured pin like any other. Not built. It is the only Tempest route that
does not require somebody's permission first.

Worth remembering that the app already gets a slice of this network for
nothing. Tempest owners who opted into CWOP appear in the NWS feed, which
is why `FW2389`, `FW4448`, `FW5754` and `GW3708` resolved onto free
stations at zero metres in the
[2026-08-19 audit](WIND_STATION_AUDIT_2026-08-19.md). `EW9356 Hampton
Bays` is the counter-example: a Tempest with no CWOP feed, and the reason
it stays a commercial pin.

## Open items

- **The writer.** The rules in
  [REGISTRY_WRITERS.md](REGISTRY_WRITERS.md) only bind a bot that reads
  them. Until the database tooling's own configuration points at these
  documents, curation is a snapshot, not a state — verify the collection
  is still near ~990 before trusting anything else on this page.
  *Verified 2026-08-18 (aggregation count): exactly 990. The curation is
  holding; the bot has not regressed since the rulebook was pushed.*
- **No free stations outside the United States.** All three networks the
  app reads stop at the border, so R1 and R3 in
  [WIND_MAP_RULES.md](WIND_MAP_RULES.md) are unanswerable for 515 of the
  990 registry rows. The Esri METAR feed above is the cheapest way to
  change that, and would bring airports only.
- **Names for the spot-linked rows.** ~827 registry rows still carry
  id-shaped names ("102428 — WX") from the original import. The app
  rescues them at render time; the registry should not need rescuing.
  A bulk rename is a database-tooling job under REGISTRY_WRITERS.md's
  caps — not something the app-side ever runs.

## Closed items (2026-08-18)

- **Disk cache for the meters read.** Done — the country-scoped fetch now
  lands in `guide-resources-*.json`, seven days fresh, stale beating an
  empty answer (an empty answer is indistinguishable from a failed fetch,
  so an old copy outranks it and only a real answer overwrites one). The
  ~475-document session bill became a weekly one.
- **Bundled snapshot.** Done — see the floor under the cache ladder above.
- **Universal links.** Verified 2026-08-18: iKitesurf serves no
  `apple-app-site-association` on `wx.ikitesurf.com` (404) or the apex
  (redirects to signup), so universal links do not exist for it and the
  stored web URL opening in the browser is the correct behaviour, not a
  missed integration. An `appScheme` field joins the schema the day
  someone confirms a URL scheme the iKitesurf app actually registers —
  from a phone that has it installed, which the repository does not.
