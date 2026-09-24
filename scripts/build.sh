#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
build_dir="${SOUNDCHECK_BUILD_DIR:-/tmp/soundcheck-derived}"
xcodebuild -project Soundcheck.xcodeproj -scheme Soundcheck -configuration Release -derivedDataPath "$build_dir" -destination 'platform=macOS,arch=arm64' ARCHS=arm64 CODE_SIGN_IDENTITY=- build
app="$build_dir/Build/Products/Release/Soundcheck.app"
codesign --verify --deep --strict "$app"
mkdir -p build
rm -rf build/Soundcheck.app build/Soundcheck.dmg
ditto --norsrc --noextattr "$app" build/Soundcheck.app
[[ "$(xcrun lipo -archs build/Soundcheck.app/Contents/MacOS/Soundcheck)" == "arm64" ]]

# Disk image with the app beside an Applications shortcut, for drag-to-install.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto --norsrc --noextattr "$app" "$staging/Soundcheck.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname Soundcheck -srcfolder "$staging" -ov -format UDZO build/Soundcheck.dmg
hdiutil verify -quiet build/Soundcheck.dmg

echo "Built: $PWD/build/Soundcheck.app"
echo "Disk image: $PWD/build/Soundcheck.dmg"
if [[ "${1:-}" == "run" ]]; then open "$app"; fi
