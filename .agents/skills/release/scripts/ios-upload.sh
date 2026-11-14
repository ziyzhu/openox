#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ios-upload.sh --build <number> --out <directory> [--upload]

Archives apps/ios for App Store Connect with cloud-managed signing, exports only
the app-store-connect method, verifies the signed app, and uploads with --upload.

Required environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_PATH, OX_DEVELOPMENT_TEAM, OX_BUNDLE_IDENTIFIER.
EOF
}

die() { echo "error: $*" >&2; exit 1; }

build="" out="" upload=0
while [ $# -gt 0 ]; do
  case "$1" in
    --build) build="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    --upload) upload=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$build" =~ ^[1-9][0-9]*$ ]] || die "--build must be a positive integer"
[ -n "$out" ] || die "--out is required"
: "${ASC_KEY_ID:?ASC_KEY_ID is required}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}"
: "${ASC_PRIVATE_KEY_PATH:?ASC_PRIVATE_KEY_PATH is required}"
: "${OX_DEVELOPMENT_TEAM:?OX_DEVELOPMENT_TEAM is required}"
: "${OX_BUNDLE_IDENTIFIER:?OX_BUNDLE_IDENTIFIER is required}"
[ -f "$ASC_PRIVATE_KEY_PATH" ] || die "ASC_PRIVATE_KEY_PATH is not a file"

root="$(cd "$(dirname "$0")/../../../.." && pwd -P)"
ios="$root/apps/ios"
mkdir -p "$out"
out="$(cd "$out" && pwd -P)"
archive="$out/Ox.xcarchive"
export_dir="$out/export"
auth=(-allowProvisioningUpdates
  -authenticationKeyPath "$ASC_PRIVATE_KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID")

run_logged() {
  local name="$1" log="$out/$1.log" status=0
  shift
  echo "==> $name"
  "$@" >"$log" 2>&1 || status=$?
  if [ "$status" != 0 ]; then
    grep -E "error:|\*\* .* FAILED \*\*" "$log" | sort -u | tail -40 >&2 || true
    tail -20 "$log" >&2
    die "$name failed (log: $log)"
  fi
}

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }
entitlement() { codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null || echo missing; }

umask 077
printf '%s\n' "OX_DEVELOPMENT_TEAM = $OX_DEVELOPMENT_TEAM" "OX_BUNDLE_IDENTIFIER = $OX_BUNDLE_IDENTIFIER" > "$ios/Local.xcconfig"
umask 022

rm -rf "$archive" "$export_dir"
run_logged archive xcodebuild archive \
  -project "$ios/Ox.xcodeproj" -scheme ios -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$archive" -derivedDataPath "$out/DerivedData" \
  "${auth[@]}" \
  CURRENT_PROJECT_VERSION="$build" COMPILER_INDEX_STORE_ENABLE=NO

app="$archive/Products/Applications/Ox.app"
[ -d "$app" ] || die "archive has no Ox.app"
version="$(plist "$app/Info.plist" CFBundleShortVersionString)"
for bundle in "$app" "$app"/PlugIns/*.appex; do
  [ "$(plist "$bundle/Info.plist" CFBundleVersion)" = "$build" ] || die "$(basename "$bundle") is not build $build"
  [ "$(plist "$bundle/Info.plist" CFBundleShortVersionString)" = "$version" ] || die "$(basename "$bundle") is not version $version"
done

options="$out/ExportOptions.plist"
cat > "$options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>export</string>
	<key>teamID</key><string>$OX_DEVELOPMENT_TEAM</string>
	<key>signingStyle</key><string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>uploadSymbols</key><true/>
</dict>
</plist>
EOF
run_logged export xcodebuild -exportArchive \
  -archivePath "$archive" -exportOptionsPlist "$options" -exportPath "$export_dir" \
  "${auth[@]}"

ipa="$export_dir/Ox.ipa"
[ -f "$ipa" ] || die "export wrote no Ox.ipa"
payload="$out/payload"
rm -rf "$payload" && mkdir -p "$payload"
ditto -x -k "$ipa" "$payload"
signed="$payload/Payload/Ox.app"
[ "$(plist "$signed/Info.plist" CFBundleIdentifier)" = "$OX_BUNDLE_IDENTIFIER" ] || die "unexpected bundle identifier"
codesign --verify --deep --strict "$signed" || die "code signature is invalid"
authority="$(codesign -dvv "$signed" 2>&1)"
grep -q "^Authority=Apple Distribution: " <<<"$authority" || die "app is not signed for distribution"
[ "$(entitlement "$signed" 'com\.apple\.developer\.web-browser')" = true ] || die "app signature lacks com.apple.developer.web-browser"
[ "$(entitlement "$signed" get-task-allow)" = false ] || die "app signature allows debugging"
[ "$(entitlement "$signed" beta-reports-active)" = true ] || die "app signature is not TestFlight-eligible"
security cms -D -i "$signed/embedded.mobileprovision" > "$out/profile.plist"
[ "$(plist "$out/profile.plist" Entitlements:com.apple.developer.web-browser)" = true ] || die "provisioning profile lacks com.apple.developer.web-browser"
profile="$(plist "$out/profile.plist" Name)"

echo "Verified Ox $version ($build): $profile"
echo "IPA: $ipa"

if [ "$upload" = 1 ]; then
  echo "==> upload"
  asc builds upload --app "$OX_BUNDLE_IDENTIFIER" --ipa "$ipa" --version "$version" --build-number "$build" --wait
  echo "Uploaded Ox $version ($build)"
fi
