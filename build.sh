#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/bmslicer-clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/bmslicer-swift"
swift build --disable-sandbox --cache-path "${TMPDIR:-/tmp}/bmslicer-package-cache" -c release
APP="$PWD/dist/BMSlicer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BMSlicer "$APP/Contents/MacOS/BMSlicer"
cp Info.plist "$APP/Contents/Info.plist"
cp THIRD-PARTY.md "$APP/Contents/Resources/THIRD-PARTY.md"
cp README.ko.md "$APP/Contents/Resources/README.ko.md"
codesign --force --sign - "$APP"
echo "$APP"
