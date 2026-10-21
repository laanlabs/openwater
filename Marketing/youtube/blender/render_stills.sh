#!/bin/bash
# Renders one mid-shot still per shot kind, for checking the look before the long renders.
cd "$(dirname "$0")"
B=/Applications/Blender.app/Contents/MacOS/Blender
render() {  # kind name clip seconds
  local s=$(date +%s)
  "$B" -b -P build_shot.py -- "$1" "$2" "$3" "$4" --still 2>&1 | grep -E "DONE|Error|Traceback|^  File|Saved:|movie frames" | head -8
  echo "$2: $(( $(date +%s) - s ))s"
}
render phone test_phone ../capture/cfr/sessions.mp4 7
render tv    test_tv    ../capture/cfr/tv.mp4 8
render watch test_watch ../capture/cfr/watch.mp4 8
render intro test_intro - 11
render outro test_outro - 8
render trio  test_trio  - 9
render card  test_card  - 14
ls -la renders/
