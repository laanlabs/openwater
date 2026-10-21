#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
CFR=../capture/cfr
PUNCH="crop=w='iw/(1+0.07*(1-min(t/0.35\,1)))':h='ih/(1+0.07*(1-min(t/0.35\,1)))',scale=1080:1920,setsar=1,format=yuv420p"
for spec in "06a-spots 5.8" "06b-spots 13.0"; do
  set -- $spec
  ffmpeg -v error -y -ss "$2" -t 2.3 -i "$CFR/spots.mp4" -loop 1 -i assets/backdrop.png -i assets/mask_phone.png -filter_complex \
    "[0:v]scale=940:-2,crop=940:1430:0:200,format=rgba[s];[s][2:v]alphamerge[rs];[1:v][rs]overlay=70:430:shortest=1,$PUNCH[v]" -map "[v]" -r 30 -c:v libx264 -crf 15 -preset fast -an "shots/$1.mp4"
  echo "$1 $(ffprobe -v error -show_entries format=duration -of csv=p=0 shots/$1.mp4)"
done
