#!/usr/bin/env bash
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

mode=portable
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --native|--native-only|--standalone-only)
      [ "$mode" = portable ] || { echo 'Choose only one CI mode' >&2; exit 1; }
      case "$1" in
        --native) mode=full ;;
        --native-only) mode=native ;;
        --standalone-only) mode=standalone ;;
      esac
      shift ;;
    --out)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo '--out requires a directory' >&2; exit 1; }
      output="$2"; shift 2 ;;
    -h|--help)
      echo 'Usage: bun run ci [--native | --native-only | --standalone-only [--out <directory>]]'
      echo 'Default: lint, build, and test (portable, credential-free coverage).'
      echo '--native: default checks, current-platform standalone CLI, and unsigned iOS/macOS builds.'
      echo '--native-only: agent bundle and unsigned iOS/macOS builds (macOS, Xcode, and XcodeGen required).'
      echo '--standalone-only: standalone CLI checks for the current platform.'
      echo 'No live Hosts, model calls, credentials, or publication.'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
if [ -n "$output" ] && [ "$mode" != standalone ]; then
  echo '--out is only supported with --standalone-only' >&2; exit 1
fi
for tool in bun git; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
if [ "$mode" = full ] || [ "$mode" = native ]; then
  [ "$(uname -s)" = Darwin ] || { echo 'Native CI requires macOS' >&2; exit 1; }
  for tool in xcodebuild xcodegen; do
    command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
  done
fi
if [ "$mode" = full ] || [ "$mode" = standalone ]; then
  for tool in curl tar; do
    command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
  done
fi
if [ "$mode" = portable ] || [ "$mode" = full ]; then
  command -v npm >/dev/null || { echo 'Missing prerequisite: npm' >&2; exit 1; }
fi
unset OX_HOST_ENDPOINT OX_DEBUG_ENDPOINT OX_SERVER_ROOT OX_QA_DEVICE
bun --no-env-file install --frozen-lockfile

if [ "$mode" = portable ] || [ "$mode" = full ]; then
  bun --no-env-file run lint
  bun --no-env-file run build
  bun --no-env-file run test
  git diff --exit-code -- apps/shared/Resources/OxServices.bundle \
    apps/shared/Resources/ModelServiceActions.json \
    packages/agent/skills/evolve/references/model-schemas.md
  echo 'PASS lint, build, and test (storage upgrades and real-provider evals not run)'
fi

if [ "$mode" = full ] || [ "$mode" = standalone ]; then
  if [ -n "$output" ]; then
    bun --no-env-file run --cwd apps/cli standalone:check --out "$output"
  else
    bun --no-env-file run --cwd apps/cli standalone:check
  fi
fi

if [ "$mode" = native ]; then
  bun --no-env-file run build:agent
fi

if [ "$mode" = full ] || [ "$mode" = native ]; then
  bun --no-env-file run build:ios CODE_SIGNING_ALLOWED=NO
  bun --no-env-file run build:macos CODE_SIGNING_ALLOWED=NO
  echo 'PASS unsigned iOS and macOS builds'
fi
