#!/usr/bin/env python3
"""Pack Natural Earth land polygons into the binary the app memory-maps.

The current wash must not paint over land, and asking a per-coordinate
elevation endpoint where the coast is could never work: masking one bay view
at a kilometre costs about three thousand billed coordinates against an
allowance of six hundred a minute, so `WaterMask` had to fall back to eleven
kilometre samples — a brush wider than San Francisco Bay. See the history in
openWater/Spots/Coastline.swift.

A coastline is geography, not weather. It belongs in the app.

Input is Natural Earth's 1:10m land (plus minor islands, which they publish
separately and which for this sport are frequently the actual destination):

    https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_land.geojson
    https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_minor_islands.geojson

Usage:
    python3 scripts/build-coastline.py land.geojson islands.geojson \\
        openWater/Resources/coastline.bin

The format, little-endian throughout, is built to be read where it lies rather
than parsed into objects — the app maps the file and never copies it:

    magic       4 bytes, "OWLM"
    version     uint32, 1
    count       uint32, number of polygons
    bboxes      count * 4 * int32   (minLat, minLon, maxLat, maxLon)
    offsets     count * uint32      byte offset into the blob below
    blob        per polygon: uint32 ring count, then per ring
                uint32 point count and that many (lat, lon) int32 pairs

Every coordinate is micro-degrees — degrees * 1e6, which is about eleven
centimetres and comfortably inside int32. The bboxes sit together at the front
so that picking the polygons for a view touches one contiguous run of a
hundred-odd kilobytes instead of striding through the whole file.
"""

import json
import struct
import sys

MICRO = 1_000_000

# About two hundred metres at the equator. The wash draws cells roughly a
# kilometre across, so detail finer than this cannot reach the screen — but
# going much coarser starts closing narrow channels, and the Golden Gate is
# 1.6 km wide with the fastest water in the bay running through it.
TOLERANCE_DEG = 0.002


def simplify(points, tolerance):
    """Douglas-Peucker, iterative so a 100k-point continent cannot blow the stack."""
    if len(points) < 3:
        return points

    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]

    while stack:
        first, last = stack.pop()
        if last <= first + 1:
            continue
        ax, ay = points[first]
        bx, by = points[last]
        dx, dy = bx - ax, by - ay
        span = dx * dx + dy * dy

        worst, index = -1.0, -1
        for i in range(first + 1, last):
            px, py = points[i]
            if span == 0:
                d = (px - ax) ** 2 + (py - ay) ** 2
            else:
                # Squared perpendicular distance to the segment, scaled by the
                # span so no square root is needed in the inner loop.
                cross = (px - ax) * dy - (py - ay) * dx
                d = cross * cross / span
            if d > worst:
                worst, index = d, i

        if worst > tolerance * tolerance and index > 0:
            keep[index] = True
            stack.append((first, index))
            stack.append((index, last))

    return [p for p, k in zip(points, keep) if k]


def rings_of(geometry):
    """Every ring of a feature, as (polygon_index, ring) pairs."""
    kind = geometry["type"]
    if kind == "Polygon":
        polygons = [geometry["coordinates"]]
    elif kind == "MultiPolygon":
        polygons = geometry["coordinates"]
    else:
        return []
    return polygons


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    *sources, destination = sys.argv[1:]

    polygons = []          # each: list of rings, each a list of (lat, lon) micro-degrees
    raw_points = kept_points = 0

    for source in sources:
        with open(source) as handle:
            data = json.load(handle)
        for feature in data.get("features", []):
            for polygon in rings_of(feature.get("geometry") or {}):
                rings = []
                for ring in polygon:
                    raw_points += len(ring)
                    # GeoJSON is (lon, lat); everything past here is (lat, lon)
                    # because that is the order every Core Location call wants.
                    thinned = simplify([(pt[1], pt[0]) for pt in ring], TOLERANCE_DEG)
                    # Under four points there is no area left to test against,
                    # and a degenerate ring would only cost a rasterizer time.
                    if len(thinned) < 4:
                        continue
                    kept_points += len(thinned)
                    rings.append([(round(a * MICRO), round(b * MICRO)) for a, b in thinned])
                if rings:
                    polygons.append(rings)

    print(f"polygons {len(polygons)}  points {raw_points} -> {kept_points} "
          f"({kept_points / max(raw_points, 1):.1%})")

    # Blob first, so the offsets are known before the header is written.
    blob = bytearray()
    offsets, bboxes = [], []
    for rings in polygons:
        offsets.append(len(blob))
        blob += struct.pack("<I", len(rings))
        lats = [lat for ring in rings for lat, _ in ring]
        lons = [lon for ring in rings for _, lon in ring]
        bboxes.append((min(lats), min(lons), max(lats), max(lons)))
        for ring in rings:
            blob += struct.pack("<I", len(ring))
            for lat, lon in ring:
                blob += struct.pack("<ii", lat, lon)

    out = bytearray()
    out += b"OWLM"
    out += struct.pack("<II", 1, len(polygons))
    for box in bboxes:
        out += struct.pack("<iiii", *box)
    for offset in offsets:
        out += struct.pack("<I", offset)
    out += blob

    with open(destination, "wb") as handle:
        handle.write(out)
    print(f"wrote {destination}  {len(out) / 1e6:.2f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
