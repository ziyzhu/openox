#!/bin/sh
set -eu

: "${CI_TEAM_ID:?CI_TEAM_ID is required}"
: "${OX_BUNDLE_IDENTIFIER:?OX_BUNDLE_IDENTIFIER is required}"

umask 077
configuration="$(dirname "$0")/../Local.xcconfig"
printf '%s\n' \
  "OX_DEVELOPMENT_TEAM = $CI_TEAM_ID" \
  "OX_BUNDLE_IDENTIFIER = $OX_BUNDLE_IDENTIFIER" \
  > "$configuration"
echo "Wrote Xcode Cloud configuration"
