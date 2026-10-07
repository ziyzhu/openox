#!/bin/sh
set -eu

: "${CI_TEAM_ID:?CI_TEAM_ID is required}"
: "${OX_BUNDLE_IDENTIFIER:?OX_BUNDLE_IDENTIFIER is required}"

if [ "${CI_XCODE_CLOUD:-}" = "TRUE" ]; then
  git config --global lfs.fetchexclude 'prebuilt/**'
  echo "Excluded unused package Git LFS prebuilts"
fi

umask 077
configuration="$(dirname "$0")/../Local.xcconfig"
printf '%s\n' \
  "OX_DEVELOPMENT_TEAM = $CI_TEAM_ID" \
  "OX_BUNDLE_IDENTIFIER = $OX_BUNDLE_IDENTIFIER" \
  > "$configuration"
echo "Wrote Xcode Cloud configuration"

cd "$(dirname "$0")/../../.."
bun_version=1.3.13
if ! command -v bun >/dev/null 2>&1 || [ "$(bun --version)" != "$bun_version" ]; then
  export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
  installer="$(mktemp)"
  trap 'rm -f "$installer"' EXIT
  curl --fail --silent --show-error --location https://bun.sh/install --output "$installer"
  bash "$installer" "bun-v$bun_version"
  export PATH="$BUN_INSTALL/bin:$PATH"
fi
bun --no-env-file install --frozen-lockfile
bun --no-env-file run build:agent
