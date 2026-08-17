#!/usr/bin/env bash
set -euo pipefail
echo "==> Checking toolchain"
command -v cargo >/dev/null || { echo "Install Rust: https://rustup.rs"; exit 1; }
command -v swift >/dev/null || { echo "Install Xcode 16+ command line tools"; exit 1; }
command -v node  >/dev/null || { echo "Install Node 20+"; exit 1; }

sw_vers -productVersion | awk -F. '$1 < 14 { print "WARN: macOS 14+ required"; }'

echo "==> Extension deps"
(cd extension && npm install)

echo "==> Resolving Swift packages"
(cd daemon && swift package resolve)

echo
echo "Ready. Next: make spike   (M0a — do not skip this)"
