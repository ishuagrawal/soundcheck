#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodegen generate
build_dir="${SOUNDCHECK_BUILD_DIR:-/tmp/soundcheck-derived}"
xcodebuild -project Soundcheck.xcodeproj -scheme Soundcheck -configuration Release -derivedDataPath "$build_dir" -destination 'platform=macOS,arch=arm64' ARCHS=arm64 CODE_SIGN_IDENTITY=- build
mkdir -p build
codesign --verify --deep --strict "$build_dir/Build/Products/Release/Soundcheck.app"
ditto --norsrc --noextattr "$build_dir/Build/Products/Release/Soundcheck.app" build/Soundcheck.app
ditto --norsrc --noextattr -c -k --keepParent "$build_dir/Build/Products/Release/Soundcheck.app" build/Soundcheck.zip
[[ "$(xcrun lipo -archs build/Soundcheck.app/Contents/MacOS/Soundcheck)" == "arm64" ]]
echo "Built: $PWD/build/Soundcheck.app"
if [[ "${1:-}" == "run" ]]; then open "$build_dir/Build/Products/Release/Soundcheck.app"; fi
