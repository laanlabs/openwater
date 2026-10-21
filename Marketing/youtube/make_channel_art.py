import math
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ICON = "/Users/jclaan/projects/ios/openWater/openWater/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
icon = Image.open(ICON).convert("RGBA")
NAVY = icon.getpixel((10, 10))[:3]
print("navy", NAVY, "orange", icon.getpixel((330, 335))[:3], "blue", icon.getpixel((300, 650))[:3])

# --- avatar: 800x800, circle crop happens on YouTube's side
icon.resize((800, 800), Image.LANCZOS).save("avatar-800.png")

# --- banner 2560x1440, safe area 1546x423 centred
W, H = 2560, 1440
SAFE_W, SAFE_H = 1546, 423
sx0, sy0 = (W - SAFE_W) // 2, (H - SAFE_H) // 2   # 507, 508
sx1, sy1 = sx0 + SAFE_W, sy0 + SAFE_H             # 2053, 931

TIDE = (0x0B, 0x6B, 0xCB)
TIDE_DARK = (0x1B, 0x8F, 0xD6)
FOAM = (0x33, 0xC4, 0xFF)
ORANGE = icon.getpixel((330, 335))[:3]
if ORANGE == NAVY: ORANGE = (0xF7, 0xA2, 0x33)

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

# vertical gradient navy -> slightly deeper navy at the bottom, with a faint tide glow low right
bg = Image.new("RGB", (W, H), NAVY)
px = bg.load()
top = lerp(NAVY, (0x10, 0x25, 0x62), 0.0)
bot = lerp(NAVY, (0x04, 0x0E, 0x2C), 1.0)
for y in range(H):
    c = lerp(top, bot, y / (H - 1))
    for x in range(W):
        px[x, y] = c
glow = Image.new("RGB", (W, H), (0, 0, 0))
gd = ImageDraw.Draw(glow)
gd.ellipse((1500, 700, 2900, 1700), fill=lerp((0, 0, 0), TIDE, 0.55))
glow = glow.filter(ImageFilter.GaussianBlur(220))
bg = Image.blend(bg, Image.eval(glow, lambda v: v), 0.0)  # placeholder keep bg
bg = Image.fromarray(__import__("PIL.ImageChops", fromlist=["add"]).add(bg, glow).__array_interface__ and None) if False else bg
from PIL import ImageChops
bg = ImageChops.add(bg, glow)

# orange sun: a ring like the icon's, sitting behind the waves on the right of the safe area
sun = Image.new("RGBA", (W, H), (0, 0, 0, 0))
sd = ImageDraw.Draw(sun)
cx, cy, r = 1930, 835, 95
sd.ellipse((cx - r, cy - r, cx + r, cy + r), fill=ORANGE + (255,))
bg = Image.alpha_composite(bg.convert("RGBA"), sun)

# waves: layered sine bands across the full width, crests reaching up into the safe band on the right
def wave_layer(color, amp, period, phase, base, alpha):
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    pts = []
    for x in range(0, W + 1, 4):
        # taller on the right, flatter on the left so the text side stays calm
        taper = 0.35 + 0.65 * (x / W)
        y = base - amp * taper * math.sin(2 * math.pi * x / period + phase) - amp * 0.3 * taper * math.sin(2 * math.pi * x / (period * 0.37) + phase * 1.7)
        pts.append((x, y))
    pts += [(W, H), (0, H)]
    d.polygon(pts, fill=color + (alpha,))
    return layer

bg = Image.alpha_composite(bg, wave_layer(FOAM, 60, 900, 0.6, 935, 70))
bg = Image.alpha_composite(bg, wave_layer(TIDE_DARK, 85, 1100, 2.2, 960, 200))
bg = Image.alpha_composite(bg, wave_layer(TIDE, 95, 1300, 4.1, 1020, 255))
bg = Image.alpha_composite(bg, wave_layer(lerp(TIDE, NAVY, 0.45), 110, 1500, 5.6, 1120, 255))

# the icon's mark, lifted off its navy background (same navy, so a straight paste works)
mark = icon.crop((90, 290, 940, 730))              # the "ow" region
mp = mark.load()
for yy in range(mark.height):
    for xx in range(mark.width):
        r, g, b, a = mp[xx, yy]
        dist = max(abs(r - NAVY[0]), abs(g - NAVY[1]), abs(b - NAVY[2]))
        alpha = min(255, int(dist * 255 / 60))
        mp[xx, yy] = (r, g, b, alpha)
mark_h = 230
mark = mark.resize((int(mark.width * mark_h / mark.height), mark_h), Image.LANCZOS)

# fonts
def face(path, want):
    for i in range(0, 14):
        try:
            f = ImageFont.truetype(path, 10, index=i)
        except Exception:
            break
        if f.getname()[1] == want:
            return i
    return 0
AV = "/System/Library/Fonts/Avenir Next.ttc"
bold = ImageFont.truetype(AV, 150, index=face(AV, "Bold"))
med = ImageFont.truetype(AV, 46, index=face(AV, "Medium"))
print("faces", bold.getname(), med.getname())

d = ImageDraw.Draw(bg)
# layout inside the safe area: mark | wordmark + tagline
x = sx0 + 40
y_mid = sy0 + SAFE_H // 2 - 10
bg.alpha_composite(mark, (x, y_mid - mark_h // 2))
x += mark.width + 50
w_open = d.textlength("open", font=bold)
d.text((x, y_mid - 150), "open", font=bold, fill=(255, 255, 255, 255))
d.text((x + w_open, y_mid - 150), "Water", font=bold, fill=FOAM + (255,))
d.text((x + 6, y_mid + 40), "Wind, waves and every session.", font=med, fill=(255, 255, 255, 225))
d.text((x + 6, y_mid + 98), "iPhone  \u00b7  Apple Watch  \u00b7  Apple TV", font=med, fill=FOAM + (235,))
assert x + 6 + d.textlength("Wind, waves and every session.", font=med) < sx1 - 20

bg.convert("RGB").save("banner-2560x1440.png", optimize=True)
# a preview of what desktop viewers see
bg.crop((0, sy0, W, sy1)).convert("RGB").save("banner-desktop-preview.png")
bg.crop((sx0, sy0, sx1, sy1)).convert("RGB").save("banner-safe-preview.png")
import os
for f in ("avatar-800.png", "banner-2560x1440.png"):
    print(f, os.path.getsize(f) // 1024, "KB")
