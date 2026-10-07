#!/bin/sh
set -eu

for resource in harness.js harness-storage.js prompts.js default-soul.md manifest.json UPSTREAM_LICENSE.txt; do
  if [ ! -s "$SRCROOT/Ox/Resources/PiDurable.bundle/$resource" ]; then
    echo "error: Missing or empty PiDurable.bundle/$resource. Run bun run build:agent before building Ox." >&2
    exit 1
  fi
done
