#!/bin/bash
# Synthesises the narration segments with ElevenLabs, one file per segment, as 48 kHz mono WAV.
# Usage: ELEVENLABS_API_KEY=... ./elevenlabs.sh [voice_id]   (default voice: George, British storyteller)
# The key is read from the environment only; never write it into this folder.
set -euo pipefail
cd "$(dirname "$0")"
: "${ELEVENLABS_API_KEY:?set ELEVENLABS_API_KEY}"
VOICE="${1:-JBFqnCBsd6RMkjVDRZzb}"
MODEL="${MODEL:-eleven_multilingual_v2}"
python3 - "$VOICE" "$MODEL" <<'PY'
import json, os, subprocess, sys, urllib.request
voice, model = sys.argv[1], sys.argv[2]
key = os.environ["ELEVENLABS_API_KEY"]
total = 0.0
for seg in json.load(open("narration.json")):
    body = json.dumps({"text": seg["text"], "model_id": model,
                       "voice_settings": {"stability": 0.5, "similarity_boost": 0.8, "style": 0.15, "use_speaker_boost": True}}).encode()
    req = urllib.request.Request(f"https://api.elevenlabs.io/v1/text-to-speech/{voice}?output_format=mp3_44100_128", data=body,
                                 headers={"xi-api-key": key, "Content-Type": "application/json", "Accept": "audio/mpeg"})
    with urllib.request.urlopen(req) as r:
        open(f"{seg['id']}.mp3", "wb").write(r.read())
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", f"{seg['id']}.mp3", "-ar", "48000", "-ac", "1",
                    "-af", "silenceremove=start_periods=1:start_threshold=-45dB,areverse,silenceremove=start_periods=1:start_threshold=-45dB,areverse,apad=pad_dur=0.3",
                    f"{seg['id']}.wav"], check=True)
    d = float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", f"{seg['id']}.wav"]))
    total += d
    print(f"{seg['id']:14s} {d:5.1f}s")
print(f"total {total:.1f}s")
PY
