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

Today's wind meters in the guide are link rows attached to spots. The
registry promotes them to first-class station documents; the old rows keep
serving until they are migrated, the same way every guide migration here
has gone.

### Read cost

Same shape as the rest of the guide: country-scoped queries (the whole US
guide is ~434 documents across three collections today, fetched once and
cached on disk with a TTL — `SpotGuideStore`), and the registry adds tens
of documents per country, not thousands, precisely because it does not
mirror NOAA rows. A rider's normal day costs zero registry reads after the
first.

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
| NDBC station index | disk, `ndbc-stations.json` | 30 days, stale beats empty |
| CO-OPS tide index | disk, `noaa-tide-stations.json` | until iOS purges caches |
| Forecast responses | disk, `forecasts/` | per-answer TTL, 3 h stale limit |
| **Any observation** | **never cached** | — |

## Open items

- **Bundled snapshot.** A distilled copy of the NDBC and CO-OPS indexes in
  the app bundle (~100 KB) would give a first-ever launch with no signal a
  working sheet. Cheap; needs an occasional refresh committed to the repo.
- **Registry migration.** Promote the guide's existing wind-meter link rows
  to `windStations` documents, starting with the ones that are rebadged
  government sensors — they are the rows the dedup needs first.
- **Universal links.** Store the provider's web URL; iOS hands it to the
  installed app when the provider supports universal links. Verify
  iKitesurf's do before relying on it, and add an app-scheme field only if
  they do not.
