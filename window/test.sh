#!/bin/bash
# Offline checks of the window's pure logic (arguments, settings, appearance,
# cache maintenance). No window server or Host needed.
set -euo pipefail
cd "$(dirname "$0")"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx12.0" -o "$OUT/logic-test" \
  src/Log.swift src/WindowSettings.swift src/Theme.swift src/CacheMaintenance.swift src/LaunchOptions.swift \
  test/logic-test/main.swift -framework AppKit
"$OUT/logic-test"
