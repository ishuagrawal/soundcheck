#!/bin/zsh
# Builds Soundcheck.app and Soundcheck.dmg in build/.
#
#   ./scripts/build.sh           Ad hoc signed build for local use
#   ./scripts/build.sh run       Same, then open the app
#   ./scripts/build.sh release   Developer ID signed, notarized, and stapled, for a GitHub release
#
# Release builds need a "Developer ID Application" certificate in the keychain and
# notary credentials saved with `xcrun notarytool store-credentials` under the
# profile name in SOUNDCHECK_NOTARY_PROFILE (default: soundcheck-notary).
set -euo pipefail
cd "${0:A:h:h}"
mode="${1:-}"
build_dir="${SOUNDCHECK_BUILD_DIR:-/tmp/soundcheck-derived}"
profile="${SOUNDCHECK_NOTARY_PROFILE:-soundcheck-notary}"

identity="-"
if [[ "$mode" == "release" ]]; then
  identity="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
  if [[ -z "$identity" ]]; then
    echo "No Developer ID Application certificate found. Create one in Xcode > Settings > Accounts > Manage Certificates." >&2
    exit 1
  fi
  xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 || {
    echo "No notary credentials for profile \"$profile\". Save them with: xcrun notarytool store-credentials $profile" >&2
    exit 1
  }
fi

xcodebuild -project Soundcheck.xcodeproj -scheme Soundcheck -configuration Release -derivedDataPath "$build_dir" \
  -destination 'platform=macOS,arch=arm64' ARCHS=arm64 CODE_SIGN_IDENTITY=- build
# Sign and package outside the repository: iCloud-synced folders add Finder
# metadata that code signing rejects. Results are copied into build/ at the end.
work="$build_dir/dist"
rm -rf "$work" && mkdir -p "$work"
ditto --norsrc --noextattr "$build_dir/Build/Products/Release/Soundcheck.app" "$work/Soundcheck.app"
app="$work/Soundcheck.app"
dmg="$work/Soundcheck.dmg"
[[ "$(xcrun lipo -archs "$app/Contents/MacOS/Soundcheck")" == "arm64" ]]

# Notarization requires the hardened runtime and a secure timestamp.
if [[ "$identity" != "-" ]]; then
  codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --deep --strict "$app"

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$profile" --wait --output-format json | tee /dev/stderr \
    | grep -q '"status" *: *"Accepted"' || { echo "Notarization failed for $1" >&2; exit 1; }
}

if [[ "$identity" != "-" ]]; then
  # Notarize and staple the app itself, so it opens offline once copied out of the disk image.
  ditto -c -k --keepParent "$app" "$work/Soundcheck-notarize.zip"
  notarize "$work/Soundcheck-notarize.zip"
  rm "$work/Soundcheck-notarize.zip"
  xcrun stapler staple "$app"
fi

# Disk image with the app beside an Applications shortcut, for drag-to-install.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto --norsrc --noextattr "$app" "$staging/Soundcheck.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname Soundcheck -srcfolder "$staging" -ov -format UDZO "$dmg"
hdiutil verify -quiet "$dmg"

if [[ "$identity" != "-" ]]; then
  codesign --timestamp --sign "$identity" "$dmg"
  notarize "$dmg"
  xcrun stapler staple "$dmg"
  spctl --assess --type execute --verbose=2 "$app"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

mkdir -p build
rm -rf build/Soundcheck.app build/Soundcheck.dmg
ditto --norsrc --noextattr "$app" build/Soundcheck.app
cp "$dmg" build/Soundcheck.dmg
echo "Built: $PWD/build/Soundcheck.app"
echo "Disk image: $PWD/build/Soundcheck.dmg"
if [[ "$mode" == "run" ]]; then open "$app"; fi
