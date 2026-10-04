#!/usr/bin/env bash
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v bun >/dev/null || { echo 'Missing prerequisite: bun' >&2; exit 1; }
exec bun tools/qa/ios-ci.ts "$@"
