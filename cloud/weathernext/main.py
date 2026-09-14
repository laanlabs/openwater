#!/usr/bin/env python3
"""Publish WeatherNext 3 wind for every guide spot, twice a day.

The app cannot ask BigQuery itself — a phone holding credentials to a
project with billing attached is a phone that can run up a bill — so this
job does the asking, once per model run, for every spot at once, and leaves
one small JSON per spot in a public bucket. The app reads that like any
other forecast: no key, no token, a URL it can cache.

**One query, not a thousand.** BigQuery bills a ten-megabyte minimum per
query and the table is clustered by cell, so asking for all ~1,000 spots'
cells in one `ST_DWITHIN` against a MULTIPOINT costs 8.5 GiB and twenty
seconds (measured 2026-09-13); asking per spot would cost ten gigabytes and
an hour. Bytes scale with the columns read far more than with the cells —
833 cells billed 8.5 GiB, 1,687 billed 9.3 — so the query names only the
wind fields. Two runs a day (00Z and 12Z) is ~510 GiB a month against a
free tier of 1 TiB; four would be the whole tier, and the hourly interim
runs six times it. See docs/WEATHERNEXT.md.

**The run it asks for is the newest one that should exist.** Google's
dissemination schedule lands a main run in BigQuery about 8h10 after its
init time; Cloud Scheduler fires this at init + 8h35. If the run is not
there yet, the previous one is published instead, and the manifest says
which, so a late run is a slightly older forecast and never a blank.

Environment (all have defaults for openWater's own project):
  PROJECT         Cloud project that owns the linked dataset and the bucket
  DATASET         linked Analytics Hub dataset          (weathernext_3)
  BUCKET          public bucket the app reads           (openwater-weathernext)
  HORIZON_HOURS   how far ahead to publish              (168)
  CELL_RADIUS_M   how far a spot may be from its cell   (8000)
  LOCAL_DIR       write the files here instead of the bucket — for reading
                  them before they are public, or for a run without one
"""

import datetime as dt
import json
import math
import os
import sys
import urllib.request

from google.cloud import bigquery, storage

PROJECT = os.environ.get("PROJECT", "openwaterapp-2e0f7")
DATASET = os.environ.get("DATASET", "weathernext_3")
TABLE = f"{PROJECT}.{DATASET}.weathernext_3_0_0_0p1deg"
BUCKET = os.environ.get("BUCKET", "openwater-weathernext")
HORIZON_HOURS = int(os.environ.get("HORIZON_HOURS", "168"))
CELL_RADIUS_M = int(os.environ.get("CELL_RADIUS_M", "8000"))
LOCAL_DIR = os.environ.get("LOCAL_DIR")

# The same public, rules-limited door the app itself reads the guide
# through; see SpotGuideStore.swift → "Configuration and keys" in README.
FIRESTORE_KEY = "AIzaSyD_wieknJx9-v_nRuszJrzaNvohfl0gRq8"
FIRESTORE = f"https://firestore.googleapis.com/v1/projects/{PROJECT}/databases/(default)/documents"

# Main runs arrive in BigQuery ~8h10 after init (±15 min, occasionally ±60).
# Anything younger than this is not expected yet and not asked for.
PUBLISH_LAG = dt.timedelta(hours=8, minutes=20)

# A query's *estimate* is the whole day-partition's columns — hundreds of
# GiB — and BigQuery refuses to start a query whose cap is under its
# estimate, so this cannot be the ~2 GiB that will actually be billed. It
# is a ceiling against a query gone structurally wrong (no init filter, a
# `SELECT *`), not a budget. The budget is the project's daily quota.
MAX_BYTES_BILLED = 2 * 1024**4

KNOTS_PER_MS = 1.943844


def log(message):
    print(message, file=sys.stderr, flush=True)


# MARK: - The spots

def guide_spots():
    """Every published guide spot: (spotId, latitude, longitude)."""
    query = {"structuredQuery": {
        "from": [{"collectionId": "spots"}],
        "select": {"fields": [{"fieldPath": "spotId"}, {"fieldPath": "latitude"},
                              {"fieldPath": "longitude"}]},
        "where": {"compositeFilter": {"op": "AND", "filters": [
            {"fieldFilter": {"field": {"fieldPath": "status"}, "op": "EQUAL",
                             "value": {"stringValue": "published"}}},
            {"fieldFilter": {"field": {"fieldPath": "isTest"}, "op": "EQUAL",
                             "value": {"booleanValue": False}}},
        ]}},
    }}
    request = urllib.request.Request(
        f"{FIRESTORE}:runQuery?key={FIRESTORE_KEY}",
        data=json.dumps(query).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        rows = json.load(response)
    spots = []
    for row in rows:
        fields = row.get("document", {}).get("fields")
        if not fields:
            continue
        try:
            spots.append((
                fields["spotId"]["stringValue"],
                float(next(iter(fields["latitude"].values()))),
                float(next(iter(fields["longitude"].values()))),
            ))
        except (KeyError, StopIteration, ValueError):
            continue
    return spots


# MARK: - The run

def candidate_inits(now):
    """Main-run init times that should be in BigQuery by now, newest first."""
    latest = now - PUBLISH_LAG
    floored = latest.replace(minute=0, second=0, microsecond=0)
    floored -= dt.timedelta(hours=floored.hour % 6)
    return [floored - dt.timedelta(hours=6 * back) for back in range(4)]


def cell_centre(lat, lon):
    """The 0.1° cell a point falls in, by its centre — the grid's centres sit
    on multiples of 0.1°, so this is a rounding, not a search."""
    return round(lat, 1), round(lon, 1)


def fetch(client, init, spots):
    """One run's rows for every cell a spot stands in, keyed by cell.

    Asked for by exact centre rather than by radius: bytes scale with cells,
    and a radius wide enough to be safe at a cell's corner pulled two cells
    for most spots — 9.3 GiB a run, measured, against 4.6 for the cells
    alone. The tolerance is for floating point, not for distance."""
    centres = sorted({cell_centre(lat, lon) for _, lat, lon in spots})
    multipoint = "MULTIPOINT(" + ", ".join(f"{lon:.1f} {lat:.1f}" for lat, lon in centres) + ")"
    sql = f"""
        SELECT
          ST_Y(t.geography) AS lat, ST_X(t.geography) AS lon,
          UNIX_SECONDS(f.time) AS stamp,
          f.wind_speed_10m_p10 AS p10, f.wind_speed_10m_p50 AS p50, f.wind_speed_10m_p90 AS p90,
          f.u_component_of_wind_10m_mean AS u, f.v_component_of_wind_10m_mean AS v
        FROM `{TABLE}` AS t, UNNEST(t.forecast) AS f
        WHERE t.init_time = @init
          AND ST_DWITHIN(t.geography, ST_GEOGFROMTEXT(@points), @radius)
          AND f.hours BETWEEN 1 AND @horizon
        ORDER BY lat, lon, stamp
    """
    job = client.query(sql, job_config=bigquery.QueryJobConfig(
        maximum_bytes_billed=MAX_BYTES_BILLED,
        query_parameters=[
            bigquery.ScalarQueryParameter("init", "TIMESTAMP", init),
            bigquery.ScalarQueryParameter("points", "STRING", multipoint),
            bigquery.ScalarQueryParameter("radius", "FLOAT64", 500.0),
            bigquery.ScalarQueryParameter("horizon", "INT64", HORIZON_HOURS),
        ]))
    cells = {}
    for row in job.result():
        cells.setdefault((row.lat, row.lon), []).append(row)
    log(f"{init.isoformat()}: {len(cells)} cells, {job.total_bytes_billed / 2**30:.2f} GiB billed")
    return cells


# MARK: - The shape the app reads

def distance_m(lat1, lon1, lat2, lon2):
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = phi2 - phi1
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return 6_371_000 * 2 * math.asin(math.sqrt(a))


def nearest_cell(cells, lat, lon):
    best, best_d = None, CELL_RADIUS_M
    for (clat, clon) in cells:
        d = distance_m(lat, lon, clat, clon)
        if d < best_d:
            best, best_d = (clat, clon), d
    return best


def direction_from(u, v):
    """Meteorological direction the wind blows *from*, degrees clockwise
    from north, out of the vector it blows *towards*."""
    if u is None or v is None:
        return None
    return int(round((270 - math.degrees(math.atan2(v, u))) % 360)) % 360


def series(rows):
    kn = lambda ms: None if ms is None else round(ms * KNOTS_PER_MS, 1)
    return {
        "times": [r.stamp for r in rows],
        "p10": [kn(r.p10) for r in rows],
        "p50": [kn(r.p50) for r in rows],
        "p90": [kn(r.p90) for r in rows],
        "dir": [direction_from(r.u, r.v) for r in rows],
    }


class LocalBucket:
    """Just enough of a bucket to write files under a directory."""

    class Blob:
        def __init__(self, path):
            self.path = path
            self.cache_control = None

        def upload_from_string(self, text, content_type=None):
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            with open(self.path, "w") as handle:
                handle.write(text)

    def __init__(self, root):
        self.root = root

    def blob(self, name):
        return self.Blob(os.path.join(self.root, name))


def publish(bucket, spots, cells, init, now):
    written = 0
    for spot_id, lat, lon in spots:
        cell = nearest_cell(cells, lat, lon)
        if cell is None:
            continue
        body = {
            "spotId": spot_id,
            "model": "weathernext_3_0_0",
            "init": init.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "published": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "cell": {"lat": cell[0], "lon": cell[1]},
            "unit": {"speed": "kn", "dir": "degrees_from"},
            **series(cells[cell]),
        }
        blob = bucket.blob(f"spots/{spot_id}.json")
        # Fifteen minutes on the CDN, so a rider gets a new run within
        # minutes of it being published rather than at the next app launch.
        blob.cache_control = "public, max-age=900"
        blob.upload_from_string(json.dumps(body, separators=(",", ":")),
                                content_type="application/json")
        written += 1
    manifest = bucket.blob("manifest.json")
    manifest.cache_control = "public, max-age=300"
    manifest.upload_from_string(json.dumps({
        "model": "weathernext_3_0_0",
        "init": init.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "published": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "spots": written,
        "horizonHours": HORIZON_HOURS,
        "attribution": "Forecast data © 2024–6 Google LLC, from Google DeepMind's WeatherNext 3 model.",
    }, indent=1), content_type="application/json")
    return written


def main():
    now = dt.datetime.now(dt.timezone.utc)
    spots = guide_spots()
    log(f"{len(spots)} published spots")
    if not spots:
        raise SystemExit("no spots — refusing to publish an empty guide")

    client = bigquery.Client(project=PROJECT)
    for init in candidate_inits(now):
        cells = fetch(client, init, spots)
        if cells:
            break
        log(f"{init.isoformat()}: not in BigQuery yet, trying the run before")
    else:
        raise SystemExit("no main run in the last day — leaving the last publish in place")

    bucket = LocalBucket(LOCAL_DIR) if LOCAL_DIR else storage.Client(project=PROJECT).bucket(BUCKET)
    written = publish(bucket, spots, cells, init, now)
    log(f"published {written} spots from the {init.isoformat()} run")


if __name__ == "__main__":
    main()
