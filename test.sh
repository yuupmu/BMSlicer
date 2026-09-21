#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/bmslicer-clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/bmslicer-swift"
swift run --disable-sandbox --cache-path "${TMPDIR:-/tmp}/bmslicer-package-cache" -c release BMSlicerCheck "$@"
