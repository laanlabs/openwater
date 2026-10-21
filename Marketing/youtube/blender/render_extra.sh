#!/bin/bash
# Spots at its final 17 s length, then the intro with its text lines raised.
cd "$(dirname "$0")"
B=/Applications/Blender.app/Contents/MacOS/Blender
render() {  # name kind clip seconds
  local s=$(date +%s)
  rm -f renders/"$1"_*.mp4
  "$B" -b -P build_shot.py -- "$2" "$1" "$3" "$4" 2>&1 | grep -E "Traceback|Error|^  File" | head -5
  echo "$1: $(( $(date +%s) - s ))s $(ls renders/ | grep "^$1_" | head -1)"
}
render spots phone ../capture/cfr/spots.mp4 17
render intro intro - 11
echo EXTRA DONE
