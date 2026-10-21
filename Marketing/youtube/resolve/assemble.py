# Assembles the explainer in DaVinci Resolve from the Blender renders, the narration,
# the caption overlays and the music bed, then queues an H.264 render.
# Runs inside Resolve's scripting sandbox: `resolve` and `project` are pre-injected,
# no filesystem access, so every path is spelled out.
import time
FPS = 30
BASE = "/Users/jclaan/projects/ios/openWater/Marketing/youtube/"
def fr(sec): return int(round(sec * FPS))

# (name, seconds, source offset seconds) — Blender names files <name>_0001-<frames>.mp4
shots = [("intro", 11, 0), ("trio", 9, 0), ("record", 7, 0), ("watch", 8.5, 0), ("sessions", 7, 0),
         ("map", 7, 0), ("fullmap", 4.5, 0), ("runs", 9, 0), ("playback", 5.5, 0), ("analysis", 13, 0),
         ("bests", 11, 0), ("spots", 17, 0), ("tv", 8.5, 8), ("tools", 7.5, 0),
         ("card", 14.5, 0), ("outro", 8, 0)]
render_len = {"tv": 21}
def render_file(name):
    n = fr(render_len.get(name, next(s for s in shots if s[0] == name)[1]))
    return BASE + "blender/renders/%s_0001-%04d.mp4" % (name, n)

# narration: (file, start seconds)
voice = [("00-intro", 0.8), ("01-record", 20.3), ("02-sessions", 35.8), ("03-map", 42.8), ("04-runs", 54.3),
         ("05-playback", 63.3), ("06-analysis", 68.8), ("07-spots", 92.8), ("08-tv", 109.8), ("09-tools", 118.3),
         ("10-data", 125.8), ("11-outro", 140.5)]
# captions: (file, start seconds, seconds)
caps = [("trio", 11.5, 8), ("record", 20.5, 6), ("watch", 27.5, 7.5), ("sessions", 36, 6), ("map", 43, 6),
        ("fullmap", 50, 3.5), ("runs", 54.5, 8), ("playback", 63.5, 4.5), ("analysis", 69, 12), ("bests", 82, 10),
        ("spots", 93, 8), ("conditions", 102, 7), ("tv", 110, 7.5), ("tools", 118.5, 6.5)]

pm = resolve.GetProjectManager()
proj = pm.GetCurrentProject()
mp = proj.GetMediaPool()
root = mp.GetRootFolder(); mp.SetCurrentFolder(root)
log = []

# a clean timeline each run
for t in range(1, proj.GetTimelineCount() + 1):
    tl = proj.GetTimelineByIndex(t)
    if tl and tl.GetName() in ("Explainer", "api-probe"):
        mp.DeleteTimelines([tl]); log.append("deleted " + tl.GetName()); break
tl = mp.CreateEmptyTimeline("Explainer"); proj.SetCurrentTimeline(tl)
tl.AddTrack("video"); tl.AddTrack("audio")

have = {c.GetName(): c for c in (root.GetClipList() or [])}
def clip(path):
    name = path.rsplit("/", 1)[1]
    if name in have: return have[name]
    got = mp.ImportMedia([path]) or []
    for c in got: have[c.GetName()] = c
    return have.get(name)

# V1: the shots, back to back, with a short dissolve between them
items = []
for name, secs, src in shots:
    c = clip(render_file(name))
    if not c: log.append("missing render " + name); continue
    got = mp.AppendToTimeline([{"mediaPoolItem": c, "mediaType": 1, "trackIndex": 1,
                                "startFrame": fr(src), "endFrame": fr(src) + fr(secs) - 1}])
    items.extend(got or [])
for it in items[1:]:
    ok = it.AddTransition({"type": "Cross Dissolve", "category": "simple", "position": "start", "alignment": "center", "duration": 12})
    if not ok: log.append("no dissolve on " + it.GetName())

# V2: caption overlays (ProRes 4444 with alpha, fades baked in)
for name, start, secs in caps:
    c = clip(BASE + "captions/%s_v3.mov" % name)
    if not c: log.append("missing caption " + name); continue
    mp.AppendToTimeline([{"mediaPoolItem": c, "mediaType": 1, "trackIndex": 2, "recordFrame": fr(start),
                          "startFrame": 0, "endFrame": fr(secs) - 1}])

# A1: narration, A2: music bed
for name, start in voice:
    c = clip(BASE + "voice/n-%s.wav" % name)
    if not c: log.append("missing voice " + name); continue
    mp.AppendToTimeline([{"mediaPoolItem": c, "mediaType": 2, "trackIndex": 1, "recordFrame": fr(start)}])
bed = clip(BASE + "music/bed_quiet.wav")
if bed:
    mp.AppendToTimeline([{"mediaPoolItem": bed, "mediaType": 2, "trackIndex": 2, "recordFrame": 0, "startFrame": 0, "endFrame": fr(148) - 1}])

v1 = tl.GetItemListInTrack("video", 1) or []
summary = {"v1": len(v1), "v2": len(tl.GetItemListInTrack("video", 2) or []),
           "a1": len(tl.GetItemListInTrack("audio", 1) or []), "a2": len(tl.GetItemListInTrack("audio", 2) or []),
           "end_sec": (v1[-1].GetEnd() - tl.GetStartFrame()) / FPS if v1 else None, "log": log}

# render queue: 1080p30 H.264 MP4 next to the sources
proj.SetCurrentRenderFormatAndCodec("mp4", "H264")
proj.SetRenderSettings({"SelectAllFrames": True, "TargetDir": BASE + "out", "CustomName": "openWater-explainer",
                        "FormatWidth": 1920, "FormatHeight": 1080, "FrameRate": 30.0, "ExportVideo": True, "ExportAudio": True,
                        "VideoQuality": "Best", "AudioCodec": "aac", "AudioSampleRate": 48000})
job = proj.AddRenderJob()
summary["job"] = job
result = summary
