#!/bin/bash
# Composites each Short shot at 1080x1920: backdrop + rounded screen + a quick punch-in on the cut.
set -euo pipefail
cd "$(dirname "$0")"
CFR=../capture/cfr
PUNCH="crop=w='iw/(1+0.07*(1-min(t/0.35\,1)))':h='ih/(1+0.07*(1-min(t/0.35\,1)))',scale=1080:1920,setsar=1,format=yuv420p"
phone() {  # out src start dur
  ffmpeg -v error -y -ss "$3" -t "$4" -i "$CFR/$2" -loop 1 -i assets/backdrop.png -i assets/mask_phone.png -filter_complex \
    "[0:v]scale=940:-2,crop=940:1430:0:200,format=rgba[s];[s][2:v]alphamerge[rs];[1:v][rs]overlay=70:430:shortest=1,$PUNCH[v]" -map "[v]" -r 30 -c:v libx264 -crf 15 -preset fast -an "shots/$1.mp4"
  echo "$1 $(ffprobe -v error -show_entries format=duration -of csv=p=0 shots/$1.mp4)"
}
other() {  # out src start dur scaleW scaleH mask x y
  ffmpeg -v error -y -ss "$3" -t "$4" -i "$CFR/$2" -loop 1 -i assets/backdrop.png -i "assets/$7.png" -filter_complex \
    "[0:v]scale=$5:$6,format=rgba[s];[s][2:v]alphamerge[rs];[1:v][rs]overlay=$8:$9:shortest=1,$PUNCH[v]" -map "[v]" -r 30 -c:v libx264 -crf 15 -preset fast -an "shots/$1.mp4"
  echo "$1 $(ffprobe -v error -show_entries format=duration -of csv=p=0 shots/$1.mp4)"
}
card() {  # out png dur
  ffmpeg -v error -y -loop 1 -t "$3" -i "assets/$2.png" -vf "$PUNCH" -r 30 -c:v libx264 -crf 15 -preset fast -an "shots/$1.mp4"
  echo "$1 $(ffprobe -v error -show_entries format=duration -of csv=p=0 shots/$1.mp4)"
}
phone 01-fullmap  fullmap.mp4  0.6  3.4
phone 02-runs     runs.mp4     1.0  2.3
phone 03-playback playback.mp4 0.0  3.4
phone 04-analysis analysis.mp4 2.5  2.3
phone 05-bests    bests.mp4    2.0  2.3
phone 06-spots    spots.mp4    7.5  4.5
other 07-watch    watch.mp4    3.5  2.3  760 926 mask_watch 160 520
other 08-tv       tv.mp4       4.0  2.3  1040 585 mask_tv 20 700
card  09-free     card_free    4.5
card  10-end      card_end     4.5
# captions: 7 pop frames then a static hold, as ProRes 4444 with alpha
cap() {  # name dur
  ffmpeg -v error -y -framerate 30 -i "captions/$1/f%02d.png" -loop 1 -framerate 30 -t "$2" -i "captions/$1/static.png" -filter_complex \
    "[0:v][1:v]concat=n=2:v=1:a=0,format=yuva444p10le,fade=t=out:st=$(python3 -c "print($2+7/30-0.2)"):d=0.2:alpha=1[v]" -map "[v]" -c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le "captions/$1.mov"
  echo "$1.mov $(ffprobe -v error -show_entries format=duration -of csv=p=0 captions/$1.mov)"
}
cap c1 2.9; cap c2 1.9; cap c3 2.9; cap c4 1.9; cap c5 1.9; cap c6 4.0; cap c7 1.9; cap c8 1.9
# audio levels: narration to -1 dBFS peak, beat under it
for f in voice/nostyle/s*.wav; do n=$(basename "$f" .wav); ffmpeg -v error -y -i "$f" -af "volume=-1dB:precision=fixed,dynaudnorm=f=150:g=15:p=0.9" "voice/n-$n.wav"; done
ffmpeg -v error -y -i assets/beat.wav -af "volume=0.42" assets/beat_mix.wav
echo "audio ready"; ls shots | wc -l
