#!/bin/bash
# Regenerate icon.icns from make-icon.swift (only needed when the artwork changes).
set -euo pipefail
cd "$(dirname "$0")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swift make-icon.swift "$TMP/icon-1024.png"
mkdir -p "$TMP/icon.iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$TMP/icon-1024.png" --out "$TMP/icon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$TMP/icon-1024.png" --out "$TMP/icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/icon.iconset" -o icon.icns
echo "wrote $(pwd)/icon.icns"
