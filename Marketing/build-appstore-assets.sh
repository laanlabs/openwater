#!/bin/bash
#
# Build every App Store screenshot size from the raw captures.
#
# App Store Connect's required iPhone size depends on which display slot the
# app record uses, and it rejects anything that is not an exact match — so all
# three accepted sizes are produced rather than guessing which slot applies.
#
# Usage: Marketing/build-appstore-assets.sh

set -euo pipefail
cd "$(dirname "$0")/.."

RAW=Marketing/screenshots/raw
OUT=Marketing/screenshots/appstore

compose() {
    local src="$1" dst="$2" w="$3" h="$4" device="$5"
    [ -d "$src" ] || { echo "skip $dst (no raw captures in $src)"; return; }
    rm -rf "$dst"
    swift Marketing/Compose.swift "$src" "$dst" "$w" "$h" "$device" >/dev/null
    echo "$dst  ${w}x${h}  ($(ls "$dst"/*.png 2>/dev/null | wc -l | tr -d ' ') files)"
}

# iPhone — all three sizes App Store Connect accepts for the phone slot.
compose "$RAW/iphone" "$OUT/iphone-6.9" 1320 2868 iphone   # 16/17 Pro Max
compose "$RAW/iphone" "$OUT/iphone-6.7" 1284 2778 iphone   # 12–14 Pro Max
compose "$RAW/iphone" "$OUT/iphone-6.5" 1242 2688 iphone   # 11 Pro Max / XS Max

# iPad — 13" is the only size required; Apple scales it for smaller iPads.
compose "$RAW/ipad" "$OUT/ipad-13" 2064 2752 ipad

# Apple Watch — plain screenshots, no marketing frame.
#
# A watch screenshot is 410 points wide on the store listing. Headline text
# composited onto something that small is illegible, so these ship as captures
# of the app itself, resized to the exact required dimensions.
watch_resize() {
    local ww="$1"
    local hh="$2"
    local dst="$OUT/watch-${ww}x${hh}"
    [ -d "$RAW/watch" ] || { echo "skip watch (no raw captures)"; return; }
    rm -rf "$dst"; mkdir -p "$dst"
    for f in "$RAW"/watch/*.png; do
        sips -z "$hh" "$ww" "$f" --out "$dst/$(basename "$f")" >/dev/null 2>&1
    done
    echo "$dst  ${ww}x${hh}  ($(ls "$dst"/*.png 2>/dev/null | wc -l | tr -d ' ') files)"
}

watch_resize 410 502   # Ultra / Ultra 2 (49mm)
watch_resize 416 496   # Series 10 (46mm)

echo
echo "Verifying dimensions"
fail=0
for dir in "$OUT"/*/; do
    expected=$(basename "$dir")
    for f in "$dir"*.png; do
        [ -e "$f" ] || continue
        actual="$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/{printf "%s", $2} END{print ""}')"
        # Compare against the size encoded in the directory name where present.
        case "$expected" in
            watch-*) want="${expected#watch-}"; want="${want/x/}" ;;
            *) continue ;;
        esac
        if [ "$actual" != "$want" ]; then
            echo "  MISMATCH $f: $actual (want $want)"
            fail=1
        fi
    done
done
[ "$fail" -eq 0 ] && echo "  all watch sizes exact"
echo "Done."
