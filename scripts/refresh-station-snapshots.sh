#!/bin/zsh
# Regenerates the bundled station-index snapshots in openWater/Resources/.
#
# These files are the first-launch fallback: a phone with no signal on its
# very first open still gets a working conditions sheet, because where the
# buoys and tide stations stand is identity, and identity is storable
# (docs/STATIONS.md). Each snapshot is distilled EXACTLY as the app's own
# loader distills its network answer — same fields, same filtering — so the
# loaders decode the bundle with the same decoder they use for their disk
# caches. Run this occasionally (the indexes move a few times a year),
# eyeball the diff, commit.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="openWater/Resources"
mkdir -p "$OUT"

echo "Tide stations (CO-OPS tidepredictions)…"
curl -sf "https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json?type=tidepredictions" \
  | python3 -c '
import json, sys
rows = json.load(sys.stdin)["stations"]
out = [{"id": s["id"], "name": s["name"], "latitude": s["lat"], "longitude": s["lng"]}
       for s in rows if s.get("id") and s.get("name")
       and s.get("lat") is not None and s.get("lng") is not None]
json.dump(out, open("'$OUT'/noaa-tide-stations.json", "w"), separators=(",", ":"))
print(f"  {len(out)} stations")'

echo "Current stations (CO-OPS currentpredictions)…"
curl -sf "https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json?type=currentpredictions" \
  | python3 -c '
import json, sys
rows = json.load(sys.stdin)["stations"]
# The app'"'"'s distillCurrentsIndex, mirrored: weak-and-variable dropped,
# duplicate ids keep their shallowest bin, harmonic flag preserved.
best = {}
for s in rows:
    if not (s.get("id") and s.get("name")
            and s.get("lat") is not None and s.get("lng") is not None
            and s.get("currbin") is not None):
        continue
    if s.get("type") == "W":
        continue
    row = {"id": s["id"], "name": s["name"], "latitude": s["lat"],
           "longitude": s["lng"], "bin": s["currbin"], "depth": s.get("depth"),
           "isHarmonic": s.get("type") == "H"}
    held = best.get(s["id"])
    if held is None or (row["depth"] or 0) < (held["depth"] or 0):
        best[s["id"]] = row
out = sorted(best.values(), key=lambda r: r["id"])
json.dump(out, open("'$OUT'/noaa-current-stations.json", "w"), separators=(",", ":"))
print(f"  {len(out)} stations")'

echo "NDBC platforms (activestations.xml, met feeds only)…"
curl -sf "https://www.ndbc.noaa.gov/activestations.xml" \
  | python3 -c '
import json, re, sys
xml = sys.stdin.read()
out = []
for tag in re.findall(r"<station\b[^>]*>", xml):
    def attribute(name):
        found = re.search(name + r"=\"([^\"]*)\"", tag)
        return found.group(1) if found else None
    if attribute("met") != "y":
        continue
    ident, name = attribute("id"), attribute("name")
    lat, lon = attribute("lat"), attribute("lon")
    if not (ident and name and lat and lon):
        continue
    out.append({"id": ident, "name": name,
                "latitude": float(lat), "longitude": float(lon)})
json.dump(out, open("'$OUT'/ndbc-stations.json", "w"), separators=(",", ":"))
print(f"  {len(out)} platforms")'

ls -la "$OUT"/*.json
