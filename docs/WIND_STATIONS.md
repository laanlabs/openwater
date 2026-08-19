# Wind station registry

Firestore collection: `windStations`

This document specifies the registry's schema, classification rules, and
audit procedure. [STATIONS.md](STATIONS.md) governs the larger question —
where station data lives at all, and why — and where the two disagree,
STATIONS.md wins.

## What the registry is, and is not

- It is the identity store for wind stations the free feeds cannot
  describe: commercial network stations (iKiteSurf/WeatherFlow, and
  whatever comes next) and independent hardware. Their existence, their
  location, and the link a subscribed rider taps to open them in the app
  they pay for — none of that can come from anywhere but us.
- It is the cross-link store that declares when a listed station **is** a
  government sensor, so the app can draw one pin carrying both the
  provider's page and the free live reading.
- It is **not** a mirror of NOAA's station lists. Government stations are
  discovered client-side from the free feeds (`FreeStations` in the app),
  which are static, keyless, cached on-device, and self-healing when NOAA
  changes hardware. A government station earns a registry document only
  when there is something to say about it that the feed cannot: a
  provider cross-link, a curated name, a hide.
- Providers remain authoritative for observations. The registry stores
  identity only; readings never touch Firestore.

## Identity: one document per physical instrument

One anemometer, one document. A provider's view of that anemometer is an
entry in `providers`, never a second document — a rider choosing between
two pins that are secretly one sensor is the exact failure this registry
exists to prevent.

```
windStations/{id}
  name        "Fort Point"           // rider-readable; never a provider id
  location    GeoPoint
  countryId   "united-states"        // the query key the app already uses
  gov         { nws: "FTPC1", ndbc: "ftpc1" }  // present ⇒ free live reading in-app
  providers   [
    { providerId: "ikitesurf", stationId: "…", url: "https://wx.ikitesurf.com/spot/…" },
    { providerId: "noaa", url: "https://www.ndbc.noaa.gov/station_page.php?station=ftpc1" }
  ]
  status      "active" | "hidden"
```

Do not merge distinct instruments merely because one provider page groups
them.

**Legacy:** the 2026-08-17 East End publication predates this rule and
wrote one row per provider view, linked by `canonicalDuplicateOf`. That
field is read as a migration marker only — the app must collapse rows
sharing it into one station — and no new write may create a per-provider
duplicate. Migrating those rows into the shape above is open work.

Display names are for riders: "Fort Point", never "102428 — WX". The
provider's internal id belongs in `providers[].stationId`. The app rescues
id-shaped names today; the registry should not need rescuing.

## Required classification

Every station document carries:

- `providerId`: normalized key of the primary provider — `noaa`,
  `ikitesurf`, `independent`.
- `providerType`: `government`, `commercial`, or `independent`.
- `accessTier`: `free`, `subscription`, `authenticated`, `freemium`, or
  `unknown`.
- `requiresSubscription`: whether a rider needs paid provider access to
  obtain the station's useful live observations.
- `supportsLiveObservations`: whether a current observation endpoint or
  page was verified.
- `dataAccessMethod`: `government-api`, `provider-api`, `public-web`,
  `authenticated-web`, or `unknown`.
- `classificationBasis`: concise explanation of the classification.
- `classificationVerifiedAt`: ISO `YYYY-MM-DD` date.

`accessTier` describes access to useful live measurements, not whether a
station landing page can be opened without paying. A public iKiteSurf
landing page does not make its premium observations free.

A document with a `gov` block is `free` by definition — the government
path serves the reading whatever a commercial provider charges for its
view of the same instrument — and per-provider access rides in the
provider entries.

## Scale and read cost

The registry is read the way the rest of the guide is read: country-scoped
queries, cached on disk with a TTL, costing a rider approximately zero
reads on a normal day. That works because the registry is curated — tens
to hundreds of documents per country, stations somebody chose to describe.
Bulk-importing a provider's full inventory is not curation and not a
default; it is a decision to argue for in STATIONS.md terms — what does
holding the copy buy that holding the link does not? Rows already
published in bulk stand until curated, but they set no precedent.

## Live data and storage

- Fetch changing observations from the authoritative provider at runtime,
  or through a short-lived cache.
- Do not write observations into Firestore unless OpenWater explicitly
  launches a historical/time-series feature with retention rules.
- Preserve observation time, retrieval time, provider attribution, and
  whether a value is measured or modeled.
- Never represent Open-Meteo or another model value as a physical station
  observation.
- A failed or stale provider must not silently fall back to a modeled
  value under the same station identity.

## Free and premium behavior

- Free stations may be shown when their terms permit the intended use.
- Subscription stations remain discoverable in the registry, but the app
  must not bypass authentication, scrape restricted readings, or imply
  OpenWater redistributes data without permission.
- Premium access is provider-specific. `requiresSubscription` does not
  prove that an OpenWater subscription includes that provider.
- When free and premium sources share an area, keep both, label their
  source and access clearly, and choose observations by entitlement,
  freshness, distance, and quality.

## What the map draws

The presentation rules — what a pin may say, when it wears a lock, and the
audit that checks both — live in
[WIND_MAP_RULES.md](WIND_MAP_RULES.md).

## Discovery and coverage audits

For a regional audit:

1. Define explicit geographic bounds and the coastal/place-name scope.
2. Inventory official government sources first: NWS station discovery,
   NOAA NDBC active stations, NOAA CO-OPS/PORTS, and relevant state or
   municipal networks.
3. Inventory commercial providers through their authorized public or
   logged-in interfaces.
4. Resolve duplicates by physical station ID and coordinates.
5. Verify the latest-observation path separately from the inventory page.
6. Record missing, inactive, subscription-only, and unresolved stations
   rather than silently discarding them.
7. Compare the audited inventory with Firestore and add or correct only
   evidence-backed records, in the one-document-per-instrument shape
   above.

Networks considered, with the reasons and the dates they were checked, are
in [STATIONS.md](STATIONS.md#sources-evaluated) — read that before adding
a fourth source.

### Option on the table: Xweather, outside the United States

The three networks above are American. Everywhere else the app has no free
stations at all, which leaves 515 of the registry's 990 rows on a map that
can only offer model wash — and leaves R1 and R3 of
[WIND_MAP_RULES.md](WIND_MAP_RULES.md) unanswerable there.

[Xweather](https://www.xweather.com/products/weather-api) is the option,
not a decision. Measured 2026-08-19: one `observations/closest` call
returns every station in a radius with its reading attached — eighteen
stations, 32 KB, 0.14 s over Sag Harbor — so the free tier's 15,000
accesses a month are 15,000 map refreshes rather than 15,000 readings.
Abroad it holds about four stations to a spot and none at all at some
(Rügen, La Paz, Cape Town). At home it is beaten by NOAA outright and
should never be called.

Which is the shape if it is ever taken: **only where `state(at:)` comes
back nil** — the app already computes that, and already means "outside the
United States" by it. A domestic rider never spends a call; the ceiling
stops being a product risk; and the single radius call is the spatial
query this API family has never offered.

Two things to settle first, neither of them code. The key cannot ship
inside the app — it is extractable, and somebody else spending the
allowance is the whole risk — so it wants a proxy, which is a server this
app has so far done without. And the free tier's attribution and display
terms want reading before anything it returns is in front of a rider.

Audit records live beside this file —
[the East End audit](EAST_END_WIND_STATION_AUDIT_2026-08-17.md) is the
first.
