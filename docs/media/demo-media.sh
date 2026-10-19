#!/usr/bin/env bash
# Makes the README demo's video: a made-up, slowly moving landscape (flat colours, so a GIF stays small) with
# four chapters, 60 s, no audio. Everything is drawn by ffmpeg; no footage is involved.
# Usage: docs/media/demo-media.sh <output.mp4>
set -euo pipefail
out="${1:?usage: demo-media.sh <output.mp4>}"
work="$(mktemp -d "${TMPDIR:-/tmp}/manping-demo-media.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Sky from ink blue to the horizon, two ridges and the foreground (DesignSystem.md colours, darkened).
sky_r='lerp(26,64,Y/H)'; sky_g='lerp(34,118,Y/H)'; sky_b='lerp(64,150,Y/H)'
far='gt(Y,H*0.58+H*0.06*sin(6.283*1.3*X/W+0.5)+H*0.03*sin(6.283*3.7*X/W))'
near='gt(Y,H*0.70+H*0.08*sin(6.283*0.8*X/W+2)+H*0.025*sin(6.283*5*X/W))'
ground='gt(Y,H*0.86+H*0.03*sin(6.283*2.2*X/W+1))'
pick() { echo "if($ground,$4,if($near,$3,if($far,$2,$1)))"; }
ffmpeg -v error -y -f lavfi -i "color=c=black:s=1920x1080:d=1" -frames:v 1 \
  -vf "geq=r='$sky_r':g='$sky_g':b='$sky_b'" "$work/sky.png"
ffmpeg -v error -y -f lavfi -i "color=c=black:s=1920x1080:d=1" -frames:v 1 \
  -vf "format=rgba,geq=r='$(pick 0 52 30 14)':g='$(pick 0 92 54 24)':b='$(pick 0 120 80 40)':a='255*$far'" "$work/ridges.png"
# A setting sun behind the ridges and two soft clouds in front.
ffmpeg -v error -y -f lavfi -i "color=c=black:s=220x220:d=1" -frames:v 1 \
  -vf "format=rgba,geq=r=255:g=208:b=128:a='255*clip((108-hypot(X-110,Y-110))/3,0,1)'" "$work/sun.png"
ffmpeg -v error -y -f lavfi -i "color=c=black:s=420x110:d=1" -frames:v 1 \
  -vf "format=rgba,geq=r=246:g=243:b=238:a='150*clip((1-hypot((X-210)/205,(Y-55)/52))*8,0,1)'" "$work/cloud.png"
cat > "$work/chapters.txt" <<'EOF'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=13000
title=开场
[CHAPTER]
TIMEBASE=1/1000
START=13000
END=31000
title=山间
[CHAPTER]
TIMEBASE=1/1000
START=31000
END=50000
title=云海
[CHAPTER]
TIMEBASE=1/1000
START=50000
END=60000
title=归途
EOF
ffmpeg -v error -y -loop 1 -i "$work/sky.png" -loop 1 -i "$work/sun.png" -loop 1 -i "$work/ridges.png" -loop 1 -i "$work/cloud.png" -i "$work/chapters.txt" \
  -filter_complex "[0][1]overlay=x='1240-t*3':y='520+t*1.4':shortest=1[a];[a][2]overlay[b];[b][3]overlay=x='-420+mod(t*14,2400)':y=170[c];[c][3]overlay=x='1700-mod(t*9,2200)':y=300[v]" \
  -map '[v]' -map_chapters 4 -t 60 -r 30 -c:v libx264 -preset slow -crf 14 -tune animation -pix_fmt yuv420p -movflags +faststart "$out"
echo "$out"
