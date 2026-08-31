#!/usr/bin/env python3
"""Build the Apple TV brand assets from the phone's 1024 app icon.

tvOS wants a layered icon rather than a flat one, and the phone's icon is
already three flat colours — a navy ground, an orange sun and the blue "ow"
wave over it — which is exactly the separation the stack needs. Keyed out by
colour and stacked, the parallax then means something: tilt the remote and the
water moves across the sun. Doing that by hand is thirteen files across four
sizes, which is how an icon drifts from the one the phone wears.

The top shelf is the app's own wash rather than decoration: a wind field
sampled through the same palette `WindPalette` uses, with the particle layer's
streaks over it. The banner should look like the thing behind it.

  Usage:
    scripts/build-tv-art.py "openWater TV/Assets.xcassets"

Run from the repo root, after changing the master icon. Needs Pillow.
"""
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import math, os, random, sys

SRC = "openWater/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
OUT = sys.argv[1]

NAVY = (5, 18, 63)
WAVE = (1, 128, 231)
SUN = (254, 160, 46)
ROUNDED = "/System/Library/Fonts/SFNSRounded.ttf"

# Straight out of WindPalette: the bands, in knots. The app's one way of saying
# how much wind, reused here so the banner and the map agree.
WASH = [
    (2, (1.00, 1.00, 1.00)), (4, (0.90, 0.88, 0.97)), (6, (0.82, 0.94, 0.97)),
    (8, (0.69, 0.92, 0.89)), (10, (0.60, 0.90, 0.68)), (12, (0.36, 0.85, 0.46)),
    (14, (0.20, 0.78, 0.36)), (16, (0.56, 0.84, 0.22)), (18, (0.95, 0.90, 0.25)),
    (20, (0.96, 0.76, 0.19)), (22, (0.96, 0.60, 0.17)), (25, (0.93, 0.42, 0.19)),
    (28, (0.85, 0.22, 0.16)), (32, (0.80, 0.13, 0.34)),
]


def wash_colour(kn):
    """The palette read as a gradient, the way `WindPalette.smooth` reads it."""
    stops, prev = [], 0.0
    for upto, c in WASH:
        stops.append(((prev + upto) / 2, c))
        prev = upto
    if kn <= stops[0][0]:
        return stops[0][1]
    if kn >= stops[-1][0]:
        return stops[-1][1]
    for i in range(1, len(stops)):
        if kn < stops[i][0]:
            a, b = stops[i - 1], stops[i]
            t = (kn - a[0]) / (b[0] - a[0])
            return tuple(a[1][j] + (b[1][j] - a[1][j]) * t for j in range(3))
    return stops[-1][1]


def key(im, target, others, tol=90):
    """Pull one flat colour out of the source as an alpha mask."""
    w, h = im.size
    src = im.load()
    mask = Image.new("L", (w, h), 0)
    mp = mask.load()
    for y in range(h):
        for x in range(w):
            r, g, b = src[x, y]
            d = abs(r - target[0]) + abs(g - target[1]) + abs(b - target[2])
            if d >= tol:
                continue
            # Nearest wins, so an edge pixel blended toward the ground does not
            # appear in two layers at once.
            if any(abs(r - o[0]) + abs(g - o[1]) + abs(b - o[2]) < d for o in others):
                continue
            mp[x, y] = 255
    return mask


def sky(size, top=(12, 38, 104), bottom=(3, 10, 34)):
    """The ground layer: a dawn gradient, so the back of the stack has
    somewhere for the light to come from."""
    w, h = size
    strip = Image.new("RGB", (1, h))
    d = ImageDraw.Draw(strip)
    for y in range(h):
        t = y / max(1, h - 1)
        d.point((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return strip.resize(size, Image.BICUBIC).convert("RGBA")


src = Image.open(SRC).convert("RGB")
sun_mask = key(src, SUN, [NAVY, WAVE])
wave_mask = key(src, WAVE, [NAVY, SUN])

# The tight box around both marks together, measured rather than guessed, so
# centring the box centres what somebody actually sees.
union = Image.new("L", src.size, 0)
union.paste(sun_mask, (0, 0), sun_mask)
union.paste(wave_mask, (0, 0), wave_mask)
BOX = union.getbbox()
BW, BH = BOX[2] - BOX[0], BOX[3] - BOX[1]


def place(mask, colour, canvas, scale, dy=0):
    """One mark, scaled and centred on a landscape canvas."""
    art = mask.crop(BOX).resize((max(1, int(BW * scale)), max(1, int(BH * scale))),
                                Image.LANCZOS)
    out = Image.new("RGBA", canvas, (0, 0, 0, 0))
    solid = Image.new("RGBA", art.size, colour + (255,))
    out.paste(solid, ((canvas[0] - art.width) // 2,
                      (canvas[1] - art.height) // 2 + dy), art)
    return out


def icon(w, h, ss=4):
    """One app icon at one size, as three parallax layers.

    The marks fill 74% of the width: tvOS crops the stack to a rounded rect and
    slides the layers against each other, so a mark that fills the frame loses
    its edges the moment somebody touches the remote.
    """
    canvas = (w * ss, h * ss)
    scale = canvas[0] * 0.74 / BW
    back = sky(canvas)
    mid = place(sun_mask, SUN, canvas, scale, dy=-int(canvas[1] * 0.015))
    front = place(wave_mask, WAVE, canvas, scale)
    return [im.resize((w, h), Image.LANCZOS) for im in (back, mid, front)]


def wind_field(size, seed=7, low=4.0, high=17.5):
    """A plausible wash: smooth blobs of wind, coloured through the palette.

    A left-to-right sweep of the whole ramp would be a colour chart. A field is
    what the map actually draws — mostly the working range, with the light air
    and the serious stuff as patches rather than as a sequence.
    """
    w, h = size
    rnd = random.Random(seed)
    gw, gh = 9, 4
    grid = Image.new("L", (gw, gh))
    gp = grid.load()
    for y in range(gh):
        for x in range(gw):
            # Windier to the right and toward the bottom, so the left stays
            # calm enough for the mark to sit on.
            bias = 0.26 * (x / (gw - 1)) + 0.30 * (y / (gh - 1))
            gp[x, y] = int(max(0, min(1, rnd.random() * 0.50 + bias)) * 255)
    grid = grid.resize((w, h), Image.BICUBIC).filter(
        ImageFilter.GaussianBlur(w * 0.022))

    field = Image.new("RGB", (w, h))
    fp, gp = field.load(), grid.load()
    for y in range(h):
        for x in range(w):
            kn = low + (high - low) * (gp[x, y] / 255)
            c = wash_colour(kn)
            fp[x, y] = tuple(int(v * 255) for v in c)
    return field, grid


def streaks(size, grid, seed=11, count=110):
    """The particle layer, held still: thin strokes running with the wind."""
    w, h = size
    rnd = random.Random(seed)
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    gp = grid.load()
    for _ in range(count):
        x = rnd.uniform(0, w)
        y = rnd.uniform(h * 0.10, h)
        speed = gp[int(min(w - 1, x)), int(min(h - 1, y))] / 255
        length = w * (0.015 + 0.05 * speed)
        drift = rnd.uniform(-0.09, 0.04)
        pts = [(x + t * length, y + t * length * drift + math.sin(t * 3.1) * h * 0.006)
               for t in (0, 0.25, 0.5, 0.75, 1.0)]
        alpha = int(18 + 46 * speed)
        d.line(pts, fill=(255, 255, 255, alpha), width=max(1, int(h * 0.0035)))
    return layer.filter(ImageFilter.GaussianBlur(h * 0.0018))


def top_shelf(w, h, ss=2):
    """The banner on the home screen: the mark on the left, the wash behind."""
    W, H = w * ss, h * ss
    im = sky((W, H), top=(9, 28, 82), bottom=(2, 7, 26)).convert("RGBA")

    field, grid = wind_field((W, H))
    field = field.convert("RGBA")
    # Held well back — this is a ground, not the subject — and faded out under
    # the mark so the wordmark keeps its contrast.
    # Two fades multiplied: out from behind the mark on the left, and down
    # from the sky at the top, so the wash sits on the water where it belongs.
    veil = Image.new("L", (W, H))
    vp = veil.load()
    for x in range(W):
        across = min(1.0, max(0.0, (x / max(1, W - 1) - 0.18) / 0.50)) ** 1.25
        for y in range(H):
            down = min(1.0, max(0.0, (y / max(1, H - 1) - 0.10) / 0.55)) ** 1.1
            vp[x, y] = int(88 * across * down)
    field.putalpha(veil)
    im.alpha_composite(field)
    im.alpha_composite(streaks((W, H), grid))

    # The mark, left, inside the 5% the top shelf is cropped to.
    pad = int(W * 0.055)
    art_h = int(H * 0.42)
    scale = art_h / BH
    marks = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    top = int(H * 0.16)
    for mask, colour, dy in ((sun_mask, SUN, -int(H * 0.012)), (wave_mask, WAVE, 0)):
        a = mask.crop(BOX).resize((int(BW * scale), int(BH * scale)), Image.LANCZOS)
        solid = Image.new("RGBA", a.size, colour + (255,))
        marks.paste(solid, (pad, top + dy), a)
    im.alpha_composite(marks)

    d = ImageDraw.Draw(im)
    f = ImageFont.truetype(ROUNDED, int(H * 0.125))
    fs = ImageFont.truetype(ROUNDED, int(H * 0.058))
    ty = top + art_h + int(H * 0.05)
    d.text((pad, ty), "openWater", font=f, fill=(255, 255, 255, 245))
    d.text((pad + 4, ty + int(H * 0.155)), "Is it on?", font=fs, fill=(150, 186, 240, 225))
    return im.convert("RGB").resize((w, h), Image.LANCZOS)


# MARK: - Writing the catalogue

def write_imageset(path, images):
    os.makedirs(path, exist_ok=True)
    stem = os.path.basename(path).split(".")[0].replace(" ", "-").lower()
    entries = []
    for img, scale in images:
        name = f"{stem}-{scale}.png"
        img.save(os.path.join(path, name))
        entries.append('    {\n      "filename" : "%s",\n      "idiom" : "tv",\n'
                       '      "scale" : "%s"\n    }' % (name, scale))
    open(os.path.join(path, "Contents.json"), "w").write(
        '{\n  "images" : [\n' + ",\n".join(entries) +
        '\n  ],\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')


def write_stack(path, layers):
    """`layers` is given back-to-front; the catalogue wants front first.

    An image stack's Contents.json lists its layers frontmost-first. Written the
    other way round the opaque sky ends up on top and the tile is a plain navy
    rectangle — which is exactly what the home screen showed.
    """
    layers = list(reversed(layers))
    os.makedirs(path, exist_ok=True)
    names = []
    for name, renders in layers:
        lp = os.path.join(path, f"{name}.imagestacklayer")
        os.makedirs(lp, exist_ok=True)
        open(os.path.join(lp, "Contents.json"), "w").write(
            '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
        write_imageset(os.path.join(lp, "Content.imageset"), renders)
        names.append('    {\n      "filename" : "%s.imagestacklayer"\n    }' % name)
    open(os.path.join(path, "Contents.json"), "w").write(
        '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n'
        '  "layers" : [\n' + ",\n".join(names) + '\n  ]\n}\n')


brand = os.path.join(OUT, "App Icon & Top Shelf Image.brandassets")
os.makedirs(brand, exist_ok=True)

b1, m1, f1 = icon(400, 240)
b2, m2, f2 = icon(800, 480)
write_stack(os.path.join(brand, "App Icon.imagestack"),
            [("Back", [(b1, "1x"), (b2, "2x")]),
             ("Middle", [(m1, "1x"), (m2, "2x")]),
             ("Front", [(f1, "1x"), (f2, "2x")])])

bs, ms, fs_ = icon(1280, 768, ss=2)
write_stack(os.path.join(brand, "App Icon - App Store.imagestack"),
            [("Back", [(bs, "1x")]), ("Middle", [(ms, "1x")]), ("Front", [(fs_, "1x")])])

write_imageset(os.path.join(brand, "Top Shelf Image.imageset"),
               [(top_shelf(1920, 720), "1x"), (top_shelf(3840, 1440, ss=1), "2x")])
write_imageset(os.path.join(brand, "Top Shelf Image Wide.imageset"),
               [(top_shelf(2320, 720), "1x"), (top_shelf(4640, 1440, ss=1), "2x")])

open(os.path.join(brand, "Contents.json"), "w").write("""{
  "assets" : [
    {
      "filename" : "App Icon - App Store.imagestack",
      "idiom" : "tv",
      "role" : "primary-app-icon",
      "size" : "1280x768"
    },
    {
      "filename" : "App Icon.imagestack",
      "idiom" : "tv",
      "role" : "primary-app-icon",
      "size" : "400x240"
    },
    {
      "filename" : "Top Shelf Image Wide.imageset",
      "idiom" : "tv",
      "role" : "top-shelf-image-wide",
      "size" : "2320x720"
    },
    {
      "filename" : "Top Shelf Image.imageset",
      "idiom" : "tv",
      "role" : "top-shelf-image",
      "size" : "1920x720"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""")
print("art box:", BOX, f"({BW}x{BH})")
print("wrote", brand)
