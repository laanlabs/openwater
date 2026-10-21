# Typography rendered with Pillow (Avenir Next) so Blender and the banner share one face.
from PIL import Image, ImageDraw, ImageFont
AV = "/System/Library/Fonts/Avenir Next.ttc"
def face(want):
    for i in range(14):
        try: f = ImageFont.truetype(AV, 10, index=i)
        except Exception: break
        if f.getname()[1] == want: return i
    return 0
BOLD, MED, DEMI = face("Bold"), face("Medium"), face("Demi Bold")
FOAM = (0x33, 0xC4, 0xFF); WHITE = (255, 255, 255); ORANGE = (254, 160, 46)
NAVY = (5, 18, 63)

def text_png(name, parts, size, weight, pad=40):
    font = ImageFont.truetype(AV, size, index=weight)
    d0 = ImageDraw.Draw(Image.new("RGBA", (10, 10)))
    w = sum(d0.textlength(t, font=font) for t, _ in parts)
    asc, desc = font.getmetrics()
    img = Image.new("RGBA", (int(w) + pad * 2, asc + desc + pad * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    x = pad
    for t, col in parts:
        d.text((x, pad), t, font=font, fill=col + (255,))
        x += d.textlength(t, font=font)
    img.save(f"assets/{name}.png")
    print(name, img.size)

text_png("wordmark", [("open", WHITE), ("Water", FOAM)], 420, BOLD)
text_png("tagline", [("Wind, waves and every session.", WHITE)], 150, MED)
text_png("platforms", [("iPhone  ·  Apple Watch  ·  Apple TV", FOAM)], 150, MED)
text_png("url", [("openwaterapp.com", WHITE)], 200, DEMI)
text_png("free", [("Free on the App Store", FOAM)], 150, MED)
text_png("datahead", [("Your data stays yours.", WHITE)], 300, DEMI)
text_png("formats", [("Import GPX \u00b7 TCX \u00b7 FIT \u00b7 CSV      Export GPX \u00b7 TCX \u00b7 CSV \u00b7 GeoJSON", FOAM)], 120, MED)
text_png("opensource", [("Open source  ·  No account  ·  Nothing leaves your phone", WHITE)], 120, MED)

# the icon's mark with the navy keyed to alpha, for an emissive plane in Blender
icon = Image.open("/Users/jclaan/projects/ios/openWater/openWater/Assets.xcassets/AppIcon.appiconset/icon-1024.png").convert("RGBA")
mark = icon.crop((80, 280, 950, 740))
mp = mark.load()
for yy in range(mark.height):
    for xx in range(mark.width):
        r, g, b, a = mp[xx, yy]
        dist = max(abs(r - NAVY[0]), abs(g - NAVY[1]), abs(b - NAVY[2]))
        mp[xx, yy] = (r, g, b, min(255, int(dist * 255 / 60)))
mark.save("assets/mark.png"); print("mark", mark.size)
# a rounded-square app icon for the outro
ic = icon.resize((1024, 1024), Image.LANCZOS)
mask = Image.new("L", ic.size, 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, 1023, 1023), radius=230, fill=255)
ic.putalpha(mask); ic.save("assets/appicon.png"); print("appicon", ic.size)
