#!/usr/bin/env python3
"""Audit what the wind-station layer would draw for a region.

The rules this checks are in docs/WIND_STATIONS.md, "What the map draws".
Every one of them exists because the app broke it once:

  R1  a number is measured or it is grey
  R2  the lock means paywalled, and only that
  R3  one instrument is one pin, free side up
  R4  never say "not reporting" without asking
  R5  discovery is complete before it is capped

Run it against any water:

    scripts/audit-wind-stations.py --centre 40.99,-72.29 --radius 60

Exit status is the number of violations, so it can gate a release.
"""

import argparse, json, math, sys, urllib.parse, urllib.request

AGENT = "openWater-audit/1.0 (openwaterapp.com; support@openwaterapp.com)"
# Mirrors NationalWeatherService. The app stops early only to get a first
# map on screen and then finishes the state in the background, so its
# steady state is the complete index — which is what this audits. R5's job
# here is to say where the hard page bound bites.
APP_PAGE_BOUND = 16
PROJECT = "openwaterapp-2e0f7"
FIREBASE_KEY = "AIzaSyD_wieknJx9-v_nRuszJrzaNvohfl0gRq8"


def get(url, headers=None, data=None):
    request = urllib.request.Request(url, data=data)
    request.add_header("User-Agent", AGENT)
    for key, value in (headers or {}).items():
        request.add_header(key, value)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def metres(a, b, c, d):
    radius, p1, p2 = 6371000, math.radians(a), math.radians(c)
    dp, dl = math.radians(c - a), math.radians(d - b)
    x = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * radius * math.asin(math.sqrt(x))


def call_sign(name):
    """The weather service files CWOP stations without the second letter."""
    for word in (name or "").split():
        if len(word) == 6 and word[:2].isalpha() and word[2:].isdigit():
            return word[0] + word[2:]
    return None


# ---------------------------------------------------------------- discovery

def nws_stations(lat, lon):
    """Every NWS station in this state, following the cursor to the end.

    R5 lives here: the first cut of the app stopped after one page and lost
    the three stations nearest half its riders.
    """
    try:
        point = get(f"https://api.weather.gov/points/{lat:.4f},{lon:.4f}")
        state = point["properties"]["relativeLocation"]["properties"]["state"]
    except Exception:
        # Outside the United States the free networks this audit knows about
        # have nothing to say. That is a finding, not a crash: R1 and R3 are
        # unanswerable there, and the classification rules still are not.
        return [], None, 0
    url, rows, pages, ran_out = f"https://api.weather.gov/stations?state={state}&limit=500", [], 0, False
    while url and pages < APP_PAGE_BOUND:
        payload = get(url)
        for feature in payload.get("features", []):
            coordinates = feature["geometry"]["coordinates"]
            rows.append({
                "id": feature["properties"]["stationIdentifier"],
                "name": feature["properties"].get("name") or "",
                "lat": coordinates[1], "lon": coordinates[0], "source": "nws",
            })
        pages += 1
        if len(payload.get("features", [])) < 500:
            ran_out = True
            break
        url = payload.get("pagination", {}).get("next")
    return rows, state, (pages if ran_out else -pages)


def coops_stations():
    payload = get("https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json?type=met")
    return [{"id": s["id"], "name": s["name"], "lat": s["lat"], "lon": s["lng"], "source": "coops"}
            for s in payload.get("stations", [])]


_REGISTRY = []


def registry_rows():
    """The curated half, straight from Firestore. Fetched once per run."""
    if _REGISTRY:
        return _REGISTRY
    url = (f"https://firestore.googleapis.com/v1/projects/{PROJECT}"
           f"/databases/(default)/documents:runQuery?key={FIREBASE_KEY}")
    body = json.dumps({"structuredQuery": {
        "from": [{"collectionId": "windStations"}],
        "limit": 5000,
    }}).encode()
    rows = []
    for row in get(url, {"Content-Type": "application/json"}, body):
        fields = row.get("document", {}).get("fields")
        if not fields:
            continue
        point = fields.get("location", {}).get("geoPointValue", {})
        if point.get("latitude") is None:
            continue
        def string(key): return (fields.get(key) or {}).get("stringValue")
        def boolean(key): return (fields.get(key) or {}).get("booleanValue")
        rows.append({
            "name": string("name") or "", "lat": point["latitude"], "lon": point["longitude"],
            "provider": string("provider") or string("providerId"),
            "tier": string("accessTier"), "type": string("providerType"),
            "subscription": boolean("requiresSubscription"), "guest": boolean("guestWindVisible"),
            "country": string("countryId"), "region": string("adminRegionId"),
        })
    _REGISTRY.extend(rows)
    return rows


# ---------------------------------------------------------------- readings

def nws_wind(station_id):
    """R4: a gust is a reading, zero is a reading, and the newest record may
    be a partial one — so the recent history is walked before calling a
    station silent. Returns (speed, gust) in knots, or None."""
    def wind(properties):
        speed = properties.get("windSpeed", {}).get("value")
        gust = properties.get("windGust", {}).get("value")
        if speed is None and gust is None:
            return None
        return (round((speed or 0) / 1.852, 1),
                None if gust is None else round(gust / 1.852, 1))
    try:
        found = wind(get(f"https://api.weather.gov/stations/{station_id}/observations/latest")["properties"])
        if found:
            return found
    except Exception:
        pass
    try:
        for feature in get(f"https://api.weather.gov/stations/{station_id}/observations?limit=8")["features"]:
            found = wind(feature["properties"])
            if found:
                return found
    except Exception:
        pass
    return None


def coops_wind(station_id):
    try:
        payload = get("https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?"
                      + urllib.parse.urlencode({"product": "wind", "station": station_id,
                                                "date": "latest", "units": "english",
                                                "time_zone": "gmt", "format": "json"}))
        row = payload["data"][-1]
        gust = row.get("g")
        return (round(float(row["s"]), 1),
                round(float(gust), 1) if gust not in (None, "") else None)
    except Exception:
        return None


def wind(station):
    return nws_wind(station["id"]) if station["source"] == "nws" else coops_wind(station["id"])


# ---------------------------------------------------------------- the rules

def locked(row):
    """R2. The registry decides this, not the provider's reputation."""
    if row["guest"] is True:
        return False
    if row["subscription"] is not None:
        return row["subscription"]
    return row["tier"] in ("subscription", "authenticated")


def same_instrument(row, station):
    """R3. Position settles most of it; the call sign settles the rest."""
    if metres(row["lat"], row["lon"], station["lat"], station["lon"]) < 250:
        return True
    sign = call_sign(row["name"])
    return bool(sign) and sign.upper() == station["id"].upper()


def classification_sweep(rows):
    """R2 over every station in the registry, everywhere.

    The only rule that needs no geography: a row either carries a
    classification or it does not, and an unclassified row draws the same
    pin as a paywalled one.
    """
    violations = []
    unclassified = [r for r in rows if r["tier"] is None and r["subscription"] is None]
    contradictory = [r for r in rows if r["guest"] is True and locked(r)]
    print(f"R2  classification {len(rows)} rows registry-wide: "
          f"{sum(1 for r in rows if locked(r))} locked, "
          f"{sum(1 for r in rows if not locked(r))} readable")
    for row in unclassified:
        violations.append(f"R2 {row['country']}/{row['name']}: no tier, no requiresSubscription")
    for row in contradictory:
        violations.append(f"R2 {row['country']}/{row['name']}: locked but guestWindVisible")
    return violations


def clusters(rows, degrees=0.5):
    """Where the stations actually are, so the sweep audits water rather
    than a grid of empty ocean."""
    cells = {}
    for row in rows:
        key = (round(row["lat"] / degrees) * degrees, round(row["lon"] / degrees) * degrees)
        cells.setdefault(key, []).append(row)
    return sorted(cells.items(), key=lambda item: -len(item[1]))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--centre", help="lat,lon")
    parser.add_argument("--sweep", type=int, metavar="N",
                        help="audit the N busiest clusters in the registry, plus R2 everywhere")
    parser.add_argument("--radius", type=float, default=60, help="km")
    parser.add_argument("--skip-readings", action="store_true")
    arguments = parser.parse_args()

    if arguments.sweep:
        rows = registry_rows()
        violations = classification_sweep(rows)
        print()
        for (lat, lon), held in clusters(rows)[:arguments.sweep]:
            print("=" * 72)
            print(f"cluster {lat:.2f},{lon:.2f} — {len(held)} registry rows "
                  f"({held[0]['country']})")
            violations += audit(lat, lon, arguments.radius * 1000,
                                arguments.skip_readings)
            print()
        print("=" * 72)
        if violations:
            print(f"{len(violations)} violation(s) across the sweep:")
            for line in violations:
                print(f"  ✗ {line}")
        else:
            print("No violations across the sweep.")
        return len(violations)

    if not arguments.centre:
        parser.error("give --centre lat,lon or --sweep N")
    lat, lon = (float(part) for part in arguments.centre.split(","))
    return len(audit(lat, lon, arguments.radius * 1000, arguments.skip_readings))


def audit(lat, lon, reach, skip_readings):

    print(f"Auditing {reach / 1000:.0f} km around {lat:.4f},{lon:.4f}\n")

    violations = []
    free, state, pages = nws_stations(lat, lon)
    free += coops_stations()
    near = sorted((s for s in free if metres(lat, lon, s["lat"], s["lon"]) <= reach),
                  key=lambda s: metres(lat, lon, s["lat"], s["lon"]))
    complete = pages > 0
    print(f"R5  discovery      {len(near)} free stations in reach "
          f"({state} index {'complete in' if complete else 'TRUNCATED at'} "
          f"{abs(pages)} page(s), CO-OPS national)")
    if not complete:
        violations.append(f"R5 {state}: index runs past the app's {APP_PAGE_BOUND}-page "
                          f"bound — stations beyond it can never be found")

    curated = [r for r in registry_rows() if metres(lat, lon, r["lat"], r["lon"]) <= reach]
    print(f"    registry       {len(curated)} curated rows in reach")

    # R3: a curated row sitting on a free station must not be its own pin.
    merged, orphans = [], []
    for row in curated:
        twin = next((s for s in near if same_instrument(row, s)), None)
        (merged if twin else orphans).append((row, twin))
    print(f"\nR3  one pin        {len(merged)} curated rows resolve to a free station")
    for row, twin in merged:
        gap = metres(row["lat"], row["lon"], twin["lat"], twin["lon"])
        print(f"      {row['name'][:34]:34} -> {twin['source']}:{twin['id']:10} {gap:5.0f} m")

    # R2: the lock must follow the registry, and locked pins carry no number.
    # R2 x R3: a paywalled row standing on free hardware. The app draws the
    # free pin, so a rider is not harmed — but the registry is describing a
    # provider's price as if it were the instrument's, and the next reader
    # of that row (a curator, another client) will believe it.
    mislabelled = [row for row, twin in merged if locked(row)]
    print(f"\nR2  the lock       {sum(1 for r in curated if locked(r))} of {len(curated)} "
          f"curated rows are paywalled, {len(mislabelled)} of them on free hardware")
    for row in mislabelled[:10]:
        print(f"      {row['name'][:38]:38} {str(row['tier']):12} -> free sensor")
    for row in curated:
        if locked(row) and row["guest"] is True:
            violations.append(f"R2 {row['name']}: locked but guestWindVisible")
        if row["tier"] is None and row["subscription"] is None:
            violations.append(f"R2 {row['name']}: unclassified — no tier, no requiresSubscription")

    # R1/R4: what would actually carry a number, and is silence real.
    if not skip_readings:
        reporting, silent, siblings = [], [], []
        for station in near[:40]:
            found = wind(station)
            if found is None:
                # R4: before calling it silent, try the other records of this
                # mast. Only a twin the app's own merge would *not* absorb is
                # a violation — inside 150 m it becomes an alternate and the
                # sheet asks it, which is the rule working rather than failing.
                twin = next((s for s in near
                             if s is not station
                             and metres(station["lat"], station["lon"], s["lat"], s["lon"]) < 250), None)
                if twin and wind(twin) is not None:
                    gap = metres(station["lat"], station["lon"], twin["lat"], twin["lon"])
                    siblings.append((station, twin, gap))
                    continue
                silent.append(station)
            else:
                reporting.append((station, found))
        print(f"\nR1  measured       {len(reporting)} of {len(near[:40])} report wind; "
              f"{len(silent)} silent")
        for station, (speed, gust) in reporting:
            shown = f"{speed:.0f}G{gust:.0f}" if gust and gust >= speed + 3 else f"{speed:.1f}"
            print(f"      {station['source']}:{station['id']:10} {shown:>7} kn  {station['name'][:38]}")
        for station, twin, gap in siblings:
            pair = f"{station['source']}:{station['id']} silent, {twin['source']}:{twin['id']} reports"
            if gap < 150:
                print(f"      {pair} — {gap:.0f} m apart, merged as an alternate")
            else:
                violations.append(f"R4 {pair} — {gap:.0f} m apart, too far to merge: "
                                  f"two pins, one of them dead")

    print(f"\nR1  modelled       {len(orphans)} curated rows have no free equivalent "
          f"(grey number, or a lock)")
    for row, _ in orphans[:12]:
        mark = "locked" if locked(row) else "grey"
        print(f"      {row['name'][:34]:34} {str(row['tier']):12} {mark}")

    print()
    if violations:
        print(f"{len(violations)} violation(s) here:")
        for line in violations:
            print(f"  ✗ {line}")
    else:
        print("No violations here.")
    return violations


if __name__ == "__main__":
    sys.exit(main())
