#!/bin/bash
# Build the macOS floating window into a self-contained .app.
#
#   ./build.sh            # build ./dsh-floating-window.app
#   ./build.sh --universal   # arm64 + x86_64 (needs the universal macOS SDK)
#
# The result is ad-hoc signed, so it runs locally without a developer account.
# Ship it inside the plugin directory: host.js launches
# dsh-floating-window.app/Contents/MacOS/dsh-floating-window directly.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="dsh-floating-window"
APP="$APP_NAME.app"
BUNDLE_ID="com.dsh.floating-window"
DEPLOYMENT="12.0"
UNIVERSAL=0
[ "${1:-}" = "--universal" ] && UNIVERSAL=1

echo "==> cleaning $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DSH 悬浮窗</string>
  <key>CFBundleDisplayName</key><string>DSH 悬浮窗</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$DEPLOYMENT</string>
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict>
</plist>
PLIST

if [ -f icon.icns ]; then
  cp icon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "   icon.icns missing: run ./make-icon.sh for a real Dock icon"
fi

SOURCES=(src/*.swift)

echo "==> compiling ($(swift --version 2>/dev/null | head -1))"
build_arch() {  # $1 = arch
  local out="build/$1/$APP_NAME"
  mkdir -p "build/$1"
  swiftc -O -swift-version 5 \
    -target "$1-apple-macosx$DEPLOYMENT" \
    -o "$out" \
    "${SOURCES[@]}" \
    -framework AppKit -framework WebKit
}

if [ "$UNIVERSAL" = "1" ]; then
  build_arch arm64
  build_arch x86_64
  lipo -create -output "$APP/Contents/MacOS/$APP_NAME" "build/arm64/$APP_NAME" "build/x86_64/$APP_NAME"
else
  build_arch "$(uname -m)"
  cp "build/$(uname -m)/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
fi
chmod +x "$APP/Contents/MacOS/$APP_NAME"

echo "==> signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   codesign skipped (not available)"

echo "==> built $APP"
file "$APP/Contents/MacOS/$APP_NAME"
