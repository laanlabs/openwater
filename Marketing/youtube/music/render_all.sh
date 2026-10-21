#!/bin/bash
# Renders every explainer shot in order. Waits for the capture clips to be final first.
cd "$(dirname "$0")"
B=/Applications/Blender.app/Contents/MacOS/Blender
CFR=../capture/cfr
until [ -f $CFR/clips.ready ]; do sleep 5; done
rm -f renders/test_*.png renders/timing_*.mp4
render() {  # name kind clip seconds
  local s=$(date +%s)
  rm -f renders/"$1"_*.mp4
  "$B" -b -P build_shot.py -- "$2" "$1" "$3" "$4" 2>&1 | grep -E "Traceback|Error|^  File" | head -5
  echo "$1: $(( $(date +%s) - s ))s $(ls renders/ | grep "^$1_" | head -1)"
}
render intro    intro - 11
render trio     trio  - 9
render record   phone $CFR/record.mp4 7
render watch    watch $CFR/watch.mp4 8.5
render sessions phone $CFR/sessions.mp4 7
render map      phone $CFR/map.mp4 7
render fullmap  phone $CFR/fullmap.mp4 4.5
render runs     phone $CFR/runs.mp4 9
render playback phone $CFR/playback.mp4 5.5
render analysis phone $CFR/analysis.mp4 13
render airtime  phone $CFR/airtime.mp4 11
render tv       tv    $CFR/tv.mp4 21
render tools    phone $CFR/tools.mp4 7.5
render card     card  - 14.5
render outro    outro - 8
until [ -f $CFR/spots.ready ]; do sleep 5; done
render spots    phone $CFR/spots.mp4 9
echo ALL DONE
