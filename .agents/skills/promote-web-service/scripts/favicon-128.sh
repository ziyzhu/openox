#!/usr/bin/env bash

set -euo pipefail

DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
  echo "Usage: $0 <domain> [verified-favicon-url]" >&2
  exit 1
fi

BASE_URL="https://$DOMAIN/"
CANDIDATE_URL="${2:-}"
OUTPUT_FILE="./favicon.png"
TMP_DIR=$(mktemp -d)
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
trap 'rm -rf "$TMP_DIR"' EXIT

log() {
  echo "[favicon] $*" >&2
}

fetch() {
  curl -fsSL -A "$UA" "$1" -o "$2"
}

resolve_url() {
  node -e 'process.stdout.write(new URL(process.argv[1], process.argv[2]).href)' "$1" "${2:-$BASE_URL}"
}

attr() {
  printf '%s\n' "$1" | sed -E -n "s/.*[[:space:]]$2=(\"([^\"]*)\"|'([^']*)'|([^[:space:]>]+)).*/\2\3\4/p"
}

rasterize() {
  local source="$1"
  local label="$2"
  local input="$source"
  local identify_input="$source"
  local output="$TMP_DIR/output.png"
  local mime
  mime=$(file -b --mime-type "$source")

  if [ "$mime" = "image/svg+xml" ] || head -c 512 "$source" | grep -qi '<svg'; then
    if ! magick -density 512 -background none "$source" -resize 128x128 -gravity center -extent 128x128 "PNG32:$output" 2>/dev/null; then
      log "rejected $label: SVG rasterization failed"
      return 1
    fi
  else
    local best
    local area
    local frame
    local width
    local height
    if [ "$mime" = "image/x-icon" ] || [ "$mime" = "image/vnd.microsoft.icon" ]; then
      identify_input="ico:$source"
    fi
    best=$(magick identify "$identify_input" 2>/dev/null | awk '{ split($3, d, "x"); print d[1] * d[2], NR - 1, d[1], d[2] }' | sort -rn | head -n1)
    if [ -z "$best" ]; then
      log "rejected $label: unsupported image"
      return 1
    fi
    read -r area frame width height <<< "$best"
    if (( width < 128 || height < 128 )); then
      log "rejected $label: raster source is ${width}x${height}; minimum is 128x128"
      return 1
    fi
    if [ "$frame" -gt 0 ] || [ "$(magick identify "$identify_input" 2>/dev/null | wc -l | tr -d ' ')" -gt 1 ]; then
      input="${identify_input}[$frame]"
    else
      input="$identify_input"
    fi
    if ! magick "$input" -background none -resize '128x128>' -gravity center -extent 128x128 "PNG32:$output" 2>/dev/null; then
      log "rejected $label: rasterization failed"
      return 1
    fi
  fi

  if [ "$(magick identify -format '%wx%h' "$output" 2>/dev/null)" != "128x128" ]; then
    log "rejected $label: output is not 128x128"
    return 1
  fi

  if [ "$(magick "$output" -crop 96x96+16+16 +repage -format '%[opaque]' info: 2>/dev/null)" != "True" ]; then
    log "rejected $label: transparent pixels enter the central 96x96 safe area; choose an official icon with an intentional background"
    return 1
  fi

  mv "$output" "$OUTPUT_FILE"
  log "wrote $OUTPUT_FILE from $label"
}

try_url() {
  local url="$1"
  local label="$2"
  local candidate="$TMP_DIR/candidate"
  log "trying $label: $url"
  fetch "$url" "$candidate" && rasterize "$candidate" "$label"
}

if [ -n "$CANDIDATE_URL" ]; then
  if try_url "$CANDIDATE_URL" "verified manifest faviconUrl"; then
    exit 0
  fi
fi

HTML_FILE="$TMP_DIR/index.html"
if ! fetch "$BASE_URL" "$HTML_FILE"; then
  log "failed to GET $BASE_URL"
  exit 1
fi

LINKS=$(tr -d '\n' < "$HTML_FILE" | grep -Eoi '<link[^>]+>' || true)

while IFS=$'\t' read -r size url; do
  [ -n "$url" ] || continue
  if try_url "$url" "apple-touch icon (${size}px declared)"; then
    exit 0
  fi
done < <(
  while IFS= read -r tag; do
    rel=$(attr "$tag" rel)
    href=$(attr "$tag" href)
    sizes=$(attr "$tag" sizes)
    [ -n "$href" ] || continue
    [[ "$rel" == *apple-touch-icon* ]] || continue
    size=${sizes%%x*}
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    printf '%s\t%s\n' "$size" "$(resolve_url "$href")"
  done <<< "$LINKS" | sort -t $'\t' -k1,1nr
)

if curl -fsI -A "$UA" "${BASE_URL}apple-touch-icon.png" >/dev/null 2>&1; then
  if try_url "${BASE_URL}apple-touch-icon.png" "default apple-touch icon"; then
    exit 0
  fi
fi

while IFS= read -r tag; do
  rel=$(attr "$tag" rel)
  href=$(attr "$tag" href)
  [ -n "$href" ] || continue
  [[ "$rel" == *manifest* ]] || continue
  manifest_url=$(resolve_url "$href")
  manifest_file="$TMP_DIR/manifest.json"
  log "trying web manifest: $manifest_url"
  if ! fetch "$manifest_url" "$manifest_file"; then
    continue
  fi
  while IFS=$'\t' read -r size icon_href; do
    [ -n "$icon_href" ] || continue
    icon_url=$(resolve_url "$icon_href" "$manifest_url")
    if try_url "$icon_url" "web-manifest icon (${size}px declared)"; then
      exit 0
    fi
  done < <(
    node -e '
      const fs = require("fs");
      const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      for (const icon of manifest.icons || []) {
        const sizes = String(icon.sizes || "").split(/\s+/).map(value => Number(value.split("x")[0]) || 0);
        const size = Math.max(0, ...sizes);
        process.stdout.write(`${size}\t${icon.src}\n`);
      }
    ' "$manifest_file" 2>/dev/null | sort -t $'\t' -k1,1nr || true
  )
done <<< "$LINKS"

while IFS=$'\t' read -r size url; do
  [ -n "$url" ] || continue
  if try_url "$url" "icon link (${size}px declared)"; then
    exit 0
  fi
done < <(
  while IFS= read -r tag; do
    rel=$(attr "$tag" rel)
    href=$(attr "$tag" href)
    sizes=$(attr "$tag" sizes)
    [ -n "$href" ] || continue
    [[ "$rel" == *icon* ]] || continue
    size=${sizes%%x*}
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    printf '%s\t%s\n' "$size" "$(resolve_url "$href")"
  done <<< "$LINKS" | sort -t $'\t' -k1,1nr
)

if try_url "${BASE_URL}favicon.ico" "/favicon.ico"; then
  exit 0
fi

log "no qualifying official icon found for $DOMAIN"
exit 1
