#!/usr/bin/env python3
"""Fail if WeatherNext has leaked into anything Xcode compiles.

WeatherNext is Google DeepMind's forecast model. We have applied for access
and we intend to use it — offline, to find out which forecast model to trust
at a given launch. We are deliberately *not* shipping it, and the reason is
the licence rather than the engineering. See docs/WEATHERNEXT.md.

The short version, because a guard nobody understands gets deleted:

  * Every forecast is "Real-Time Experimental Data". The terms define that as
    anything under an hour old *and the entire future*, so a forecast can
    never be the CC BY 4.0 half of the licence.
  * The terms name our three renderings — colouring a field, sub-setting an
    area to one spot, combining time-steps and parameters into a chart — as
    things that are explicitly *not* a Value Added Service. They stay raw
    data, shareable only with "clearly identified and known third parties …
    for their own internal purposes". App Store customers are not that.
  * "not intended for consumer use", in those words, in the disclaimer.

So the rule this enforces is a single line: **no WeatherNext in any directory
Xcode compiles.** Not behind a build flag, not behind a feature switch, not
commented out. A runtime flag still ships the code and still ships the URL,
and "it was disabled" is not a defence anybody wants to make in writing.

That leaves scripts/ and docs/, which is where the work belongs anyway. The
Xcode project uses file-system-synchronized groups, and it syncs exactly five
directories — the ones listed in ROOTS below. Nothing outside them can reach
a build, which is why this guard only has to look there.

Run it directly, or let scripts/testflight.sh run it for you before it
archives anything:

    scripts/check-weathernext-containment.py

Exit status is the number of violations, so it gates a release.
"""

import re
import sys
from pathlib import Path

# The directories Xcode's synchronized groups pull in. Anything here is
# compiled into a shipping product (or into a test bundle built against one);
# anything outside is a file on this machine and nothing more.
ROOTS = [
    "openWater",
    "openWater Watch App",
    "openWater TV",
    "openWaterTests",
    "openWaterUITests",
]

# Also swept, because a package linked by those targets ships just as surely.
ROOTS += [
    "OpenWaterCore/Sources",
    "OpenWaterSpots/Sources",
]

SUFFIXES = {".swift", ".m", ".mm", ".h", ".c", ".plist", ".json", ".entitlements"}

# What a leak actually looks like. The bucket and dataset names are the ones
# from the access guides; the last two catch a URL built by hand.
NEEDLES = [
    re.compile(r"weathernext", re.IGNORECASE),
    re.compile(r"weather_next", re.IGNORECASE),
    re.compile(r"gcp-public-data-weathernext", re.IGNORECASE),
    re.compile(r"\bweathernext_3_0_0\w*", re.IGNORECASE),
]

# This file talks about WeatherNext constantly and lives outside ROOTS, but
# say so anyway: a future reorganisation that moves scripts/ under a synced
# group should not start by reporting the guard itself.
SELF = Path(__file__).resolve()


def offences(root: Path):
    """Every (path, line number, line) in one root that names WeatherNext."""
    if not root.is_dir():
        return
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix not in SUFFIXES:
            continue
        if path.resolve() == SELF:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            if any(needle.search(line) for needle in NEEDLES):
                yield path, number, line.strip()


def main() -> int:
    repo = Path(__file__).resolve().parent.parent
    found = []
    for name in ROOTS:
        found.extend(offences(repo / name))

    if not found:
        print("WeatherNext containment: clean — nothing in the app targets.")
        return 0

    print("WeatherNext containment: FAILED", file=sys.stderr)
    print(file=sys.stderr)
    for path, number, line in found:
        print(f"  {path.relative_to(repo)}:{number}: {line}", file=sys.stderr)
    print(file=sys.stderr)
    print(
        "These files are compiled into a shipping product. WeatherNext's\n"
        "real-time terms do not permit showing its forecasts to App Store\n"
        "customers — see docs/WEATHERNEXT.md. Move this work to scripts/,\n"
        "or get written permission from weathernext@google.com first and\n"
        "update the doc and this guard together.",
        file=sys.stderr,
    )
    return len(found)


if __name__ == "__main__":
    sys.exit(main())
