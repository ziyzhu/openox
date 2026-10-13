#!/usr/bin/env bash

set -euo pipefail

DOMAIN="${1:-}"
SOURCE_URL="${2:-}"
if [ -z "$DOMAIN" ] || [[ "$SOURCE_URL" != https://* ]]; then
  echo "Usage: $0 <domain> <verified-https-favicon-url>" >&2
  exit 1
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
SOURCE="$WORK_DIR/source"
OUTPUT="$WORK_DIR/favicon.png"
curl -fsSL --proto '=https' --proto-redir '=https' --max-redirs 5 --max-filesize 1048576 --connect-timeout 15 --max-time 30 "$SOURCE_URL" -o "$SOURCE"
MIME=$(file -b --mime-type "$SOURCE")

if [ "$MIME" = "image/svg+xml" ]; then
  magick -density 512 -background none "$SOURCE" -resize 128x128 -gravity center -extent 128x128 "PNG32:$OUTPUT"
else
  case "$MIME" in
    image/png|image/jpeg) INPUT="$SOURCE" ;;
    image/x-icon|image/vnd.microsoft.icon) INPUT="ico:$SOURCE" ;;
    *) echo "[favicon] unsupported source: $MIME" >&2; exit 1 ;;
  esac
  FRAMES=$(magick identify -format '%w %h %p\n' "$INPUT")
  if ! printf '%s\n' "$FRAMES" | awk 'NF != 3 || $1 > 4096 || $2 > 4096 { invalid = 1 } END { exit invalid || NR > 32 }'; then
    echo "[favicon] source exceeds dimension or frame limits" >&2
    exit 1
  fi
  read -r WIDTH HEIGHT FRAME <<< "$(printf '%s\n' "$FRAMES" | sort -k1,1nr -k2,2nr | head -n1)"
  if (( WIDTH != HEIGHT || WIDTH < 128 )); then
    echo "[favicon] expected square source at least 128x128; got ${WIDTH}x${HEIGHT}" >&2
    exit 1
  fi
  magick "${INPUT}[$FRAME]" -resize '128x128>' "PNG32:$OUTPUT"
fi

mv "$OUTPUT" ./favicon.png
echo "[favicon] wrote favicon.png for $DOMAIN from $SOURCE_URL; inspect the audit preview before upload" >&2
