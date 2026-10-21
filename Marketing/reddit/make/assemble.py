#!/usr/bin/env python3
"""The plainer recut: website stills first, then quick app segments with
small labels, hard cuts, flat background. No logo intro, no glow, no taglines.

    python3 assemble2.py            # build everything from plan.json
"""
import json, os, subprocess, sys
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.dirname(os.path.abspath(__file__))
SEG, DRIVE, LBL = f"{OUT}/seg2", f"{OUT}/drive", f"{OUT}/labels"
os.makedirs(SEG, exist_ok=True); os.makedirs(LBL, exist_ok=True)
W, H = 1080, 1080
BG = (14, 21, 38)
AV = "/System/Library/Fonts/Avenir Next.ttc"

def face(want):
    for i in range(14):
        try: f = ImageFont.truetype(AV, 10, index=i)
        except Exception: break
        if f.getname()[1] == want: return i
    return 0
MED, DEMI = face("Medium"), face("Demi Bold")

def run(args):
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        print(" ".join(args)); print(r.stderr[-3000:]); sys.exit(1)

def duration(path):
    return float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path]).decode().strip())

ENC = ["-an", "-c:v", "libx264", "-crf", "16", "-preset", "fast", "-pix_fmt", "yuv420p", "-r", "30", "-video_track_timescale", "30000"]

# A small label: white text in a dark pill. Top-left for phone segments,
# bottom-left over the page for website stills.
def label_png(name, text, where="top"):
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(img)
    font = ImageFont.truetype(AV, 40, index=DEMI)
    tw = d.textlength(text, font=font)
    if where == "top": x, y = (W - tw) // 2, 26
    else: x, y = 60, 133 + 813 - 60 - 56
    d.rounded_rectangle((x - 22, y - 12, x + tw + 22, y + 60), radius=14, fill=(6, 12, 26, 215))
    d.text((x, y), text, font=font, fill=(255, 255, 255, 255))
    path = f"{LBL}/{name}.png"; img.save(path); return path

# The flat backdrop, once.
bg_path = f"{LBL}/bg.png"
if not os.path.exists(bg_path): Image.new("RGB", (W, H), BG).save(bg_path)

# Phone mask, once: 460x1000, rounded.
mask_path = f"{LBL}/mask.png"
if not os.path.exists(mask_path):
    m = Image.new("L", (440, 957), 0); ImageDraw.Draw(m).rounded_rectangle((0, 0, 439, 956), radius=64, fill=255); m.save(mask_path)

# A website still, full-bleed (1440x813 → 1920x1084, cropped), held for `length`.
def still(name, path, length, text):
    lbl = label_png(name, text, "bottom")
    fc = "[0:v]crop=1080:813:180:0[pg];[2:v][pg]overlay=0:133[b];[b][1:v]overlay=0:0,format=yuv420p[v]"
    run(["ffmpeg", "-v", "error", "-y", "-loop", "1", "-i", path, "-i", lbl, "-loop", "1", "-i", bg_path,
         "-filter_complex", fc, "-map", "[v]", "-t", str(length), *ENC, f"{SEG}/{name}.mp4"])
    print(f"{name:12s} {duration(f'{SEG}/{name}.mp4'):.2f}s  {text}")

# A phone recording window: 460x1000 rounded, centred, label top-left.
def phone(name, mov, start, length, text):
    lbl = label_png(name, text, "top")
    fc = ("[1:v]scale=440:957,fps=30[ph];[ph][3:v]alphamerge[phm];"
          "[0:v][phm]overlay=320:100[b];[b][2:v]overlay=0:0,format=yuv420p[v]")
    run(["ffmpeg", "-v", "error", "-y", "-loop", "1", "-i", bg_path,
         "-ss", str(start), "-t", str(length), "-i", f"{DRIVE}/{mov}",
         "-i", lbl, "-i", mask_path,
         "-filter_complex", fc, "-map", "[v]", "-t", str(length), *ENC, f"{SEG}/{name}.mp4"])
    print(f"{name:12s} {duration(f'{SEG}/{name}.mp4'):.2f}s  {text}")

# A plain text card.
def card(name, lines, length):
    img = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(img)
    y = 420
    for i, (text, size) in enumerate(lines):
        font = ImageFont.truetype(AV, size, index=DEMI if i == 0 else MED)
        d.text((W // 2, y), text, font=font, fill=(255, 255, 255) if i == 0 else (160, 200, 255), anchor="ma")
        y += int(size * 1.5)
    path = f"{LBL}/{name}.png"; img.save(path)
    run(["ffmpeg", "-v", "error", "-y", "-loop", "1", "-i", path, "-t", str(length), "-vf", "format=yuv420p", *ENC, f"{SEG}/{name}.mp4"])
    print(f"{name:12s} {length:.2f}s  card")

def concat(names, out):
    lst = f"{SEG}/list.txt"
    with open(lst, "w") as f:
        for n in names: f.write(f"file '{SEG}/{n}.mp4'\n")
    run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", lst, "-fps_mode", "cfr", *ENC, out])
    print(f"master {duration(out):.1f}s → {out}")

def gif(master, out, width, fps, colors=256):
    vf = f"fps={fps},scale={width}:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors={colors}:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle"
    run(["ffmpeg", "-v", "error", "-y", "-i", master, "-filter_complex", vf, out])
    print(f"gif {width}px {fps}fps → {out} ({os.path.getsize(out) / 1e6:.1f} MB)")

if __name__ == "__main__":
    plan = json.load(open(f"{OUT}/plan.json"))
    order = []
    for item in plan:
        kind, name = item[0], item[1]
        if kind == "still": still(name, f"{OUT}/web2/{item[2]}", item[3], item[4])
        elif kind == "phone": phone(name, item[2], item[3], item[4], item[5])
        elif kind == "card": card(name, item[2], item[3])
        order.append(name)
    concat(order, f"{OUT}/openwater-reddit-v2.mp4")
    gif(f"{OUT}/openwater-reddit-v2.mp4", f"{OUT}/openwater-reddit-v2-800.gif", 800, 12)
    gif(f"{OUT}/openwater-reddit-v2.mp4", f"{OUT}/openwater-reddit-v2-640.gif", 640, 12, 192)
