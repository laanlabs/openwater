# Full-frame 1920x1080 caption overlays with alpha, Avenir Next, wrapped to stay clear of the phone.
from PIL import Image, ImageDraw, ImageFont
AV = "/System/Library/Fonts/Avenir Next.ttc"
def face(want):
    for i in range(14):
        try: f = ImageFont.truetype(AV, 10, index=i)
        except Exception: break
        if f.getname()[1] == want: return i
    return 0
DEMI, MED = face("Demi Bold"), face("Medium")
WHITE, FOAM = (255, 255, 255), (0x33, 0xC4, 0xFF)
MAXW = 540   # the phone's left edge sits near x=750 in a 1920 frame

def wrap(text, font, d, maxw):
    lines, line = [], ""
    for w in text.split(" "):
        t = (line + " " + w).strip()
        if d.textlength(t, font=font) <= maxw or not line: line = t
        else: lines.append(line); line = w
    if line: lines.append(line)
    return lines

def caption(name, head, sub=None, where="left"):
    img = Image.new("RGBA", (1920, 1080), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    hf = ImageFont.truetype(AV, 70 if where == "left" else 62, index=DEMI)
    sf = ImageFont.truetype(AV, 36 if where == "left" else 40, index=MED)
    def put(xy, text, font, fill, anchor):
        x, y = xy
        d.text((x + 3, y + 4), text, font=font, fill=(0, 0, 0, 120), anchor=anchor)
        d.text((x, y), text, font=font, fill=fill + (255,), anchor=anchor)
    if where == "left":
        hl = wrap(head.replace("\n", " "), hf, d, MAXW)
        sl = wrap(sub, sf, d, MAXW) if sub else []
        block = len(hl) * 86 + (14 + len(sl) * 46 if sl else 0)
        x, y = 130, 540 - block // 2
        d.rounded_rectangle((x, y + 2, x + 10, y + 78), radius=5, fill=FOAM + (255,))
        for i, line in enumerate(hl): put((x + 36, y + i * 86), line, hf, WHITE, "la")
        for i, line in enumerate(sl): put((x + 38, y + len(hl) * 86 + 14 + i * 46), line, sf, FOAM, "la")
    else:
        put((960, 960), head, hf, WHITE, "ms")
        if sub: put((960, 1012), sub, sf, FOAM, "ms")
    img.save(f"{name}.png")

caption("trio", "No account. No subscription.", "Every feature free", "bottom")
caption("record", "Record in one tap", "Phone or watch")
caption("watch", "Runs standalone on Apple Watch", "Water Lock on, track written continuously", "bottom")
caption("sessions", "Every session, one list", "Track, distance, best speeds")
caption("map", "The map draws what happened", "Flights bold, slow sections faded, falls marked")
caption("fullmap", "Turn the phone, full-screen map")
caption("runs", "Runs: one lane per pass", "Nothing overlaps")
caption("playback", "Replay the whole session", "Playhead, speed heatmap, live readout")
caption("analysis", "Analysis, one row per topic", "Speed categories · Foiling · Angles · Gybes")
caption("bests", "Personal bests, every category", "2 s · 10 s · 500 m · nautical mile · Alpha 500")
caption("spots", "1000+ spots, live wind on every pin", "Wind wash, three days ahead")
caption("conditions", "Tides, currents, swell, radar and cameras", "In the nearest station's own numbers", "bottom")
caption("tv", "The same picture on Apple TV", "Wind map, cameras, starred spots", "bottom")
caption("tools", "Share a pin · Shuttle planner · Race countdown", "Sync the start to the committee boat's gun")
print("captions drawn")
