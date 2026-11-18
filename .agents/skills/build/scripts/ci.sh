#!/usr/bin/env bash
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

workflow=portable
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --native|--native-only|--ios-only|--macos-only|--standalone-only)
      [ "$workflow" = portable ] || { echo 'Choose only one CI mode' >&2; exit 1; }
      case "$1" in
        --native) workflow=full ;;
        --native-only) workflow=native ;;
        --ios-only) workflow=ios ;;
        --macos-only) workflow=macos ;;
        --standalone-only) workflow=standalone ;;
      esac
      shift ;;
    --out)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo '--out requires a directory' >&2; exit 1; }
      output="$2"; shift 2 ;;
    -h|--help)
      echo 'Usage: bun run ci [--native | --native-only | --ios-only | --macos-only | --standalone-only [--out <directory>]]'
      echo 'Default: lint, build, and test (portable, credential-free coverage).'
      echo '--native: default checks, current-platform standalone CLI, and unsigned iOS/macOS builds.'
      echo '--native-only: agent bundle and unsigned iOS/macOS builds (macOS, Xcode, and XcodeGen required).'
      echo '--ios-only: agent bundle and unsigned iOS build.'
      echo '--macos-only: agent bundle and unsigned macOS build.'
      echo '--standalone-only: standalone CLI checks for the current platform.'
      echo 'No live Hosts, model calls, credentials, or publication.'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
if [ -n "$output" ] && [ "$workflow" != standalone ]; then
  echo '--out is only supported with --standalone-only' >&2; exit 1
fi

case "$workflow" in
  portable)
    environment=portable
    steps=(environment install lint build test drift) ;;
  standalone)
    environment=standalone
    steps=(environment install standalone) ;;
  native)
    environment=native
    steps=(environment install build:agent build:ios build:macos) ;;
  ios)
    environment=native
    steps=(environment install build:agent build:ios) ;;
  macos)
    environment=native
    steps=(environment install build:agent build:macos) ;;
  full)
    environment=full
    steps=(environment install lint build test drift standalone build:ios build:macos) ;;
esac

unset OX_HOST_ENDPOINT OX_DEBUG_ENDPOINT OX_SERVER_ROOT OX_QA_DEVICE
echo "CI workflow=$workflow environment=$environment steps=${steps[*]}"
trap '
  code=$?
  result=FAIL
  if [ "$step" = environment ]; then result=BLOCKED; fi
  echo "$result CI workflow=$workflow environment=$environment step=$step exit=$code" >&2
  exit "$code"
' ERR
for step in "${steps[@]}"; do
  echo "CI workflow=$workflow step=$step"
  case "$step" in
    environment) bun --no-env-file .agents/skills/build/scripts/ci-environment.ts "$environment" ;;
    install) bun --no-env-file install --frozen-lockfile ;;
    lint|build|test|build:agent) bun --no-env-file run "$step" ;;
    drift)
      git diff --exit-code -- apps/shared/Resources/OxServices.bundle \
        apps/shared/Resources/ModelServiceActions.json \
        packages/agent/skills/evolve/references/model-schemas.md
      echo 'PASS lint, build, and test (storage upgrades and real-provider evals not run)' ;;
    standalone)
      if [ -n "$output" ]; then
        bun --no-env-file run --cwd apps/cli standalone:check --out "$output"
      else
        bun --no-env-file run --cwd apps/cli standalone:check
      fi ;;
    build:ios)
      if [ ! -e apps/ios/Local.xcconfig ]; then
        bundle="$(bun --no-env-file -p 'require("./.github/ci.json").iosBundleIdentifier')"
        (set -o noclobber; printf 'OX_BUNDLE_IDENTIFIER = %s\n' "$bundle" > apps/ios/Local.xcconfig)
        trap 'rm -f apps/ios/Local.xcconfig' EXIT
      fi
      bun --no-env-file run build:ios CODE_SIGNING_ALLOWED=NO OX_DEVELOPMENT_TEAM= ;;
    build:macos) bun --no-env-file run build:macos CODE_SIGNING_ALLOWED=NO OX_DEVELOPMENT_TEAM= ;;
  esac
done
echo "PASS CI workflow=$workflow environment=$environment"
