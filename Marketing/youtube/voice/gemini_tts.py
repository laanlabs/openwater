#!/usr/bin/env python3
"""Narration with Gemini 2.5 TTS via Vertex AI, using gcloud Application Default Credentials.

  python3 gemini_tts.py --project P [--location us-central1] [--voice Charon]
                        [--model gemini-2.5-flash-preview-tts] [--only 00-intro] [--text "..."]

Writes <id>.wav (48 kHz mono, silence trimmed) per segment of narration.json and prints durations.
"""
import argparse, base64, json, subprocess, sys, urllib.request, urllib.error

ap = argparse.ArgumentParser()
ap.add_argument("--project", required=True)
ap.add_argument("--location", default="us-central1")
ap.add_argument("--voice", default="Charon")
ap.add_argument("--model", default="gemini-2.5-flash-preview-tts")
ap.add_argument("--style", default="Narrate this for a calm, confident product video, at a measured pace with natural pauses: ")
ap.add_argument("--only", default=None)
ap.add_argument("--script", default="narration.json")
ap.add_argument("--text", default=None, help="synthesise this text as test.wav instead of the script")
a = ap.parse_args()

token = subprocess.check_output(["gcloud", "auth", "application-default", "print-access-token"], text=True).strip()
url = (f"https://{a.location}-aiplatform.googleapis.com/v1/projects/{a.project}/locations/{a.location}"
       f"/publishers/google/models/{a.model}:generateContent")
if a.location == "global":
    url = f"https://aiplatform.googleapis.com/v1/projects/{a.project}/locations/global/publishers/google/models/{a.model}:generateContent"


def synth(text, out):
    body = {"contents": [{"role": "user", "parts": [{"text": a.style + text}]}],
            "generationConfig": {"responseModalities": ["AUDIO"],
                                 "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": a.voice}}}}}
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + token, "Content-Type": "application/json",
                                          "x-goog-user-project": a.project})
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            resp = json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code}: {e.read().decode()[:300]}")
    part = resp["candidates"][0]["content"]["parts"][0]["inlineData"]
    mime, data = part["mimeType"], base64.b64decode(part["data"])
    rate = 24000
    for kv in mime.split(";"):
        if kv.strip().startswith("rate="):
            rate = int(kv.split("=")[1])
    raw = out + ".pcm"
    open(raw, "wb").write(data)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "s16le", "-ar", str(rate), "-ac", "1", "-i", raw, "-ar", "48000",
                    "-af", "silenceremove=start_periods=1:start_threshold=-45dB,areverse,"
                           "silenceremove=start_periods=1:start_threshold=-45dB,areverse,apad=pad_dur=0.3",
                    out + ".wav"], check=True)
    subprocess.run(["rm", "-f", raw])
    return float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                                          "-of", "csv=p=0", out + ".wav"]))


if a.text:
    print("test.wav", round(synth(a.text, "test"), 1), "s")
    sys.exit()
total = 0.0
for seg in json.load(open(a.script)):
    if a.only and seg["id"] != a.only:
        continue
    d = synth(seg["text"], seg["id"])
    total += d
    print(f"{seg['id']:14s} {d:5.1f}s", flush=True)
print(f"total {total:.1f}s")
