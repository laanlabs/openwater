# Wind station registry

Firestore collection: `windStations`

`windStations` is OpenWater's canonical cross-provider station registry. It
contains both public stations (for example NOAA/NWS) and commercial stations
(for example iKiteSurf). Government and provider services remain authoritative
for current observations; the registry is authoritative for which stations
OpenWater knows about, how they are classified, and which adapter may read
them.

## Required classification

Every station must carry these fields:

- `providerId`: normalized provider key such as `noaa`, `ikitesurf`, or
  `independent`.
- `providerType`: `government`, `commercial`, or `independent`.
- `accessTier`: `free`, `subscription`, `authenticated`, `freemium`, or
  `unknown`.
- `requiresSubscription`: whether an OpenWater user needs paid provider access
  to obtain the station's useful live observations.
- `supportsLiveObservations`: whether a current observation endpoint or page
  was verified.
- `dataAccessMethod`: `government-api`, `provider-api`, `public-web`,
  `authenticated-web`, or `unknown`.
- `classificationBasis`: concise explanation of the classification.
- `classificationVerifiedAt`: ISO `YYYY-MM-DD` date.

`accessTier` describes access to useful live measurements, not whether a
station landing page can be opened without paying. A public iKiteSurf landing
page does not make its premium observations free.

## Station identity

A station document should also retain:

- Stable OpenWater document ID and provider station ID.
- Display name, provider, latitude, longitude, and geographic region.
- Canonical station or operator URL.
- Observation endpoint when it is stable and permitted to store.
- Measurements supported, when known: wind speed, direction, gust,
  temperature, pressure, waves, and water level.
- Operational status, last verification date, and attribution requirements.
- Related spot IDs only when the relationship is genuinely useful; a station
  may exist without a foil-spot backlink.

Do not create separate records for multiple views of the same physical
instrument. Do not merge distinct instruments merely because one provider page
groups them.

## Live data and storage

- Fetch changing observations from the authoritative provider at runtime or
  through a short-lived backend cache.
- Do not write every observation into Firestore unless OpenWater explicitly
  launches a historical/time-series feature with retention rules.
- Preserve observation time, retrieval time, provider attribution, and whether
  a value is measured or modeled.
- Never represent Open-Meteo or another forecast/current model value as a
  physical station observation.
- A failed or stale provider must not silently fall back to a modeled value
  under the same station identity.

## Free and premium behavior

- Free stations may be shown when their terms permit the intended use.
- Subscription stations remain discoverable in the registry, but the app must
  not bypass authentication, scrape restricted readings, or imply OpenWater
  redistributes data without permission.
- Premium access is provider-specific. `requiresSubscription` does not prove
  that an OpenWater subscription includes that provider.
- When free and premium stations share an area, keep both. Label their source
  and access clearly and choose observations according to user entitlement,
  freshness, distance, and quality.

## Discovery and coverage audits

For a regional audit:

1. Define explicit geographic bounds and the coastal/place-name scope.
2. Inventory official government sources first: NWS station discovery, NOAA
   NDBC active stations, NOAA CO-OPS/PORTS, and relevant state or municipal
   networks.
3. Inventory commercial providers through their authorized public or logged-in
   interfaces.
4. Resolve duplicates by physical station ID and coordinates.
5. Verify the latest-observation path separately from the inventory page.
6. Record missing, inactive, subscription-only, and unresolved stations rather
   than silently discarding them.
7. Compare the audited inventory with Firestore and add or correct only
   evidence-backed records.

## East End of Long Island scope

The initial focused audit covers Long Island east of approximately
`-72.65` longitude, including the North Fork, South Fork, Gardiners Bay,
Peconic Bays, Block Island Sound approaches, and nearby offshore stations that
materially serve East End riders. A station outside the bounds may be retained
when it is a practically relevant offshore observation; document that reason.

