#!/bin/bash
#
# Build every app-icon file both targets need from one 1024×1024 master.
#
# Xcode will happily take a single 1024 for iOS and watchOS these days, but this
# project's catalogue also carries the macOS sizes and the iOS 18 dark and
# tinted variants — eleven files across two catalogues. Doing that by hand is
# how they drift: a new icon lands in the iOS set, the watch keeps the old one,
# and nobody notices until a screenshot.
#
#   Usage:
#     scripts/make-app-icon.sh path/to/icon-1024.png
#
# The master should be exactly 1024×1024 with no transparency and no rounded
# corners — iOS applies the mask itself, and a pre-rounded icon comes out with
# the corners cut twice.
#
set -euo pipefail

cd "$(dirname "$0")/.."

MASTER=${1:?Usage: scripts/make-app-icon.sh path/to/icon-1024.png}
if [ ! -f "$MASTER" ]; then
    echo "No such file: $MASTER" >&2
    exit 1
fi

IOS=openWater/Assets.xcassets/AppIcon.appiconset
WATCH="openWater Watch App/Assets.xcassets/AppIcon.appiconset"

python3 - "$MASTER" "$IOS" "$WATCH" <<'PY'
import sys, pathlib
from PIL import Image

master_path, ios, watch = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
master = Image.open(master_path).convert("RGBA")

if master.size != (1024, 1024):
    print(f"  ! master is {master.size[0]}×{master.size[1]}, resizing to 1024×1024")
    master = master.resize((1024, 1024), Image.LANCZOS)

def write(image, path):
    image.save(path, "PNG")
    print(f"  {path}  {image.size[0]}×{image.size[1]}")

# Light and dark are the same artwork. The icon is already dark-backed, and a
# separate dark variant only earns its place if it differs — an identical file
# under a second name is just something else to keep in step.
write(master, ios / "icon-1024.png")
write(master, ios / "icon-1024-dark.png")
write(master, watch / "icon-1024.png")

# Tinted mode composites a single colour through a greyscale mask, so this one
# has to be luminance. Handing it the colour artwork produces a muddy result
# that looks like a bug rather than a tint.
write(master.convert("L").convert("RGBA"), ios / "icon-1024-tinted.png")

# macOS wants real files at each size rather than one that Finder scales: the
# 16-point icon of a downsampled 1024 is mush, and these are drawn with
# LANCZOS at each step.
for size in (16, 32, 64, 128, 256, 512, 1024):
    write(master.resize((size, size), Image.LANCZOS), ios / f"mac-{size}.png")
PY

echo "==> Done. Both catalogues updated from $MASTER"
