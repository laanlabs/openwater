# Vertical (1080x1920) assets for the Short: backdrop, rounded masks, pop-in captions, text cards, end card.
import math, os
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageChops
AV = "/System/Library/Fonts/Avenir Next.ttc"
def face(want):
    for i in range(14):
        try: f = ImageFont.truetype(AV, 10, index=i)
        except Exception: break
        if f.getname()[1] == want: return i
    return 0
BOLD, DEMI, MED = face("Bold"), face("Demi Bold"), face("Medium")
W, H = 1080, 1920
NAVY, DEEP = (5, 18, 63), (2, 7, 28)
TIDE, FOAM, ORANGE, WHITE = (11, 107, 203), (51, 196, 255), (254, 160, 46), (255, 255, 255)
def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

# backdrop: navy gradient with a tide glow low in the frame
bg = Image.new("RGB", (W, H)); px = bg.load()
for y in range(H):
    c = lerp((10, 30, 90), DEEP, y / (H - 1))
    for x in range(W): px[x, y] = c
glow = Image.new("RGB", (W, H), (0, 0, 0)); ImageDraw.Draw(glow).ellipse((-200, 900, 1280, 2300), fill=lerp((0, 0, 0), TIDE, 0.6))
bg = ImageChops.add(bg, glow.filter(ImageFilter.GaussianBlur(260)))
bg.save("assets/backdrop.png")

# rounded masks
def mask(name, w, h, r):
    m = Image.new("L", (w, h), 0); ImageDraw.Draw(m).rounded_rectangle((0, 0, w - 1, h - 1), radius=r, fill=255); m.save(f"assets/{name}.png")
mask("mask_phone", 940, 1430, 64)
mask("mask_watch", 760, 926, 190)
mask("mask_tv", 1040, 585, 28)

# captions with a 6-frame pop-in, written as PNG sequences
def caption(name, lines, y=130, size=100, color=WHITE, accent=None):
    font = ImageFont.truetype(AV, size, index=BOLD)
    def draw(scale, alpha):
        img = Image.new("RGBA", (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(img)
        f = ImageFont.truetype(AV, int(size * scale), index=BOLD)
        for i, line in enumerate(lines):
            col = accent if (accent and i == len(lines) - 1) else color
            yy = y + i * int(size * 1.15 * scale)
            d.text((W // 2 + 4, yy + 6), line, font=f, fill=(0, 0, 0, int(140 * alpha)), anchor="ma")
            d.text((W // 2, yy), line, font=f, fill=col + (int(255 * alpha),), anchor="ma")
        return img
    os.makedirs(f"captions/{name}", exist_ok=True)
    for i in range(7):
        t = i / 6; s = 0.82 + 0.18 * (1 - (1 - t) ** 3)
        draw(s, min(1, t * 1.5)).save(f"captions/{name}/f{i:02d}.png")
    draw(1.0, 1.0).save(f"captions/{name}/static.png")
caption("c1", ["Your whole", "session."])
caption("c2", ["Every run,", "its own lane."])
caption("c3", ["Replay it."])
caption("c4", ["Every speed", "riders compare."])
caption("c5", ["Personal bests."])
caption("c6", ["1000+ spots.", "Live wind."], accent=FOAM)
caption("c7", ["From your wrist."])
caption("c8", ["Or the big screen."])

# text card and end card (opaque, full frame)
def card(name, lines, sizes, colors, y0):
    img = bg.copy().convert("RGBA"); d = ImageDraw.Draw(img); y = y0
    for line, size, col in zip(lines, sizes, colors):
        f = ImageFont.truetype(AV, size, index=BOLD if size > 90 else MED)
        d.text((W // 2 + 4, y + 6), line, font=f, fill=(0, 0, 0, 120), anchor="ma"); d.text((W // 2, y), line, font=f, fill=col + (255,), anchor="ma")
        y += int(size * 1.3)
    return img
card("free", ["No account.", "No subscription.", "Free."], [128, 128, 150], [WHITE, WHITE, FOAM], 640).convert("RGB").save("assets/card_free.png")
end = bg.copy().convert("RGBA")
icon = Image.open("../blender/assets/appicon.png").convert("RGBA").resize((420, 420), Image.LANCZOS)
end.alpha_composite(icon, (W // 2 - 210, 520))
wm = Image.open("../blender/assets/wordmark.png").convert("RGBA"); wm = wm.resize((820, int(wm.height * 820 / wm.width)), Image.LANCZOS)
end.alpha_composite(wm, (W // 2 - 410, 990))
d = ImageDraw.Draw(end)
d.text((W // 2, 1240), "openwaterapp.com", font=ImageFont.truetype(AV, 84, index=DEMI), fill=WHITE + (255,), anchor="ma")
d.text((W // 2, 1360), "Free on the App Store", font=ImageFont.truetype(AV, 60, index=MED), fill=FOAM + (255,), anchor="ma")
end.convert("RGB").save("assets/card_end.png")
print("assets ready")
