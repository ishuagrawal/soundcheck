#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodegen generate
mkdir -p build/tests
xcrun clang -std=c11 -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined -g \
  scripts/test-render.c Soundcheck/Audio/RenderKernel.c -framework CoreAudio -o build/tests/test-render
build/tests/test-render
xcodebuild -project Soundcheck.xcodeproj -scheme Soundcheck -configuration Debug -derivedDataPath "${SOUNDCHECK_BUILD_DIR:-/tmp/soundcheck-derived}" \
  -destination 'platform=macOS,arch=arm64' ARCHS=arm64 CODE_SIGN_IDENTITY=- test
