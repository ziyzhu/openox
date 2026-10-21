#!/bin/sh
set -eu

shared="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
resources="$shared/Resources/PiDurable.bundle"

for resource in harness.js harness-storage.js prompts.js manifest.json UPSTREAM_LICENSE.txt; do
  if [ ! -s "$resources/$resource" ]; then
    echo "error: Missing or empty PiDurable.bundle/$resource. Run bun run build:agent before building Ox." >&2
    exit 1
  fi
done

if [ ! -s "$shared/Host/Agent/ModelGuidance.generated.swift" ]; then
  echo "error: Missing Host/Agent/ModelGuidance.generated.swift. Run bun run build:agent before building Ox." >&2
  exit 1
fi
