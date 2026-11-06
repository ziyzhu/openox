#!/usr/bin/env bash
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

standalone=false
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --standalone-only) standalone=true; shift ;;
    --out)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo '--out requires a directory' >&2; exit 1; }
      output="$2"; shift 2 ;;
    -h|--help)
      echo 'Usage: bun run ci [--standalone-only [--out <directory>]]'
      echo 'Default: lint, build, and test (portable, credential-free coverage).'
      echo 'No iOS, live Hosts, model calls, credentials, or publication. Standalone mode tests only the current platform.'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
if [ -n "$output" ] && [ "$standalone" = false ]; then
  echo '--out is only supported with --standalone-only' >&2; exit 1
fi
for tool in bun git; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
unset OX_HOST_ENDPOINT OX_DEBUG_ENDPOINT OX_SERVER_ROOT OX_QA_DEVICE
bun --no-env-file install --frozen-lockfile

if [ "$standalone" = true ]; then
  for tool in curl tar; do
    command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
  done
  if [ -n "$output" ]; then
    bun --no-env-file run --cwd apps/cli standalone:check --out "$output"
  else
    bun --no-env-file run --cwd apps/cli standalone:check
  fi
  exit 0
fi
command -v npm >/dev/null || { echo 'Missing prerequisite: npm' >&2; exit 1; }
bun --no-env-file run lint
bun --no-env-file run build
bun --no-env-file run test
git diff --exit-code -- apps/shared/Resources/OxServices.bundle \
  apps/shared/Resources/ModelServiceActions.json \
  packages/agent/skills/evolve/references/model-schemas.md
echo 'PASS lint, build, and test (storage upgrades and real-provider evals not run)'
