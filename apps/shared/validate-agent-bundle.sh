#!/bin/sh
set -eu

resources="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/Resources/PiDurable.bundle"

for resource in harness.js harness-storage.js prompts.js default-soul.md manifest.json UPSTREAM_LICENSE.txt; do
  if [ ! -s "$resources/$resource" ]; then
    echo "error: Missing or empty PiDurable.bundle/$resource. Run bun run build:agent before building Ox." >&2
    exit 1
  fi
done
