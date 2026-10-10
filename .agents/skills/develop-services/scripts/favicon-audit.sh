#!/usr/bin/env bash

set -euo pipefail

INPUT_FILE="${1:-favicon.png}"
if [ ! -f "$INPUT_FILE" ]; then
  echo "Usage: $0 [favicon.png]" >&2
  exit 1
fi

WORK_DIR=$(mktemp -d)
RESULT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ox-favicon-audit.XXXXXX")
OUTPUT_FILE="$RESULT_DIR/preview.png"
trap 'rm -rf "$WORK_DIR"' EXIT

render() {
  local size="$1"
  local background="$2"
  local output="$3"
  local resized="$WORK_DIR/resized-${size}-${background#\#}.png"
  magick "$INPUT_FILE" -resize "${size}x${size}" "$resized"
  magick -size "${size}x${size}" "xc:$background" "$resized" -composite -filter point -resize 128x128 "$output"
}

render 128 '#f4f1ea' "$WORK_DIR/128-light.png"
render 128 '#1c1b19' "$WORK_DIR/128-dark.png"
render 20 '#f4f1ea' "$WORK_DIR/20-light.png"
render 20 '#1c1b19' "$WORK_DIR/20-dark.png"
magick "$WORK_DIR/128-light.png" "$WORK_DIR/128-dark.png" +append "$WORK_DIR/top.png"
magick "$WORK_DIR/20-light.png" "$WORK_DIR/20-dark.png" +append "$WORK_DIR/bottom.png"
magick "$WORK_DIR/top.png" "$WORK_DIR/bottom.png" -append "$OUTPUT_FILE"

status=0
dimensions=$(magick identify -format '%wx%h' "$INPUT_FILE" 2>/dev/null || true)
if [ "$dimensions" != "128x128" ]; then
  echo "[favicon] failed: image is $dimensions, expected 128x128" >&2
  status=1
fi

safe_area_opaque=$(magick "$INPUT_FILE" -crop 96x96+16+16 +repage -format '%[opaque]' info: 2>/dev/null || true)
if [ "$safe_area_opaque" != "True" ]; then
  echo "[favicon] failed: transparent pixels enter the central 96x96 safe area" >&2
  status=1
fi

echo "[favicon] preview: $OUTPUT_FILE" >&2
echo "[favicon] layout: 128px light | 128px dark; 20px light | 20px dark" >&2
exit "$status"
