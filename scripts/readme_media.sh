#!/usr/bin/env bash
# README animations in one command (docs/media/README.md): builds the Debug app, records each scene from its
# offline samples, then composes and encodes docs/images/<scene>.gif.
#
#   scripts/readme_media.sh                  # all scenes
#   scripts/readme_media.sh hero mini        # only these
#   scripts/readme_media.sh --no-build hero  # reuse .build/ui/满屏 Debug.app
#   scripts/readme_media.sh --render-only    # compose and encode existing recordings
#
# Recording opens the Debug app's windows on this Mac for about 15 s per scene (the windows ignore the real
# pointer). Needs ffmpeg, node and pnpm, Xcode, and Screen Recording permission for the terminal.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDIA="$ROOT/docs/media"
OUT="$MEDIA/.out"
APP="$ROOT/.build/ui/满屏 Debug.app"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

build=1
record=1
scenes=()
for arg in "$@"; do
  case "$arg" in
    --no-build) build=0 ;;
    --render-only) build=0; record=0 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) echo "unknown option $arg" >&2; exit 2 ;;
    *) scenes+=("$arg") ;;
  esac
done
[[ ${#scenes[@]} -gt 0 ]] || scenes=(hero danmaku mini live settings)

for tool in ffmpeg node pnpm; do
  command -v "$tool" >/dev/null || { echo "$tool is required (see docs/media/README.md)" >&2; exit 1; }
done
mkdir -p "$OUT"

if [[ $build == 1 ]]; then
  python3 "$ROOT/scripts/build_debug_app.py"
fi

if [[ $record == 1 ]]; then
  [[ -x "$APP/Contents/MacOS/Manping" ]] || { echo "No Debug app at $APP; run without --no-build" >&2; exit 1; }
  [[ -f "$OUT/demo-media.mp4" ]] || "$MEDIA/demo-media.sh" "$OUT/demo-media.mp4"
  swiftc -O -swift-version 5 "$MEDIA/record.swift" -o "$OUT/record"
  for scene in "${scenes[@]}"; do
    "$OUT/record" --app "$APP" --scenes "$MEDIA/scenes.json" --out "$OUT" --media "$OUT/demo-media.mp4" "$scene"
  done
fi

pnpm --dir "$MEDIA/remotion" install --frozen-lockfile
pnpm --dir "$MEDIA/remotion" render "${scenes[@]}"
