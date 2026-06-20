#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Utility"
BUNDLE_ID="com.utility.app"
VERSION="1.0.0"

echo "=== 1/5 Clean build ==="
rm -rf .build
swift build -c release

echo ""
echo "=== 2/5 Sign binary ==="
codesign --sign - --force --options runtime .build/release/utility

echo ""
echo "=== 3/5 Build .app bundle ==="
APP="${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp .build/release/utility "$APP/Contents/MacOS/"
RES_BUNDLE=".build/arm64-apple-macosx/release/utility_utility.bundle"
if [ -d "$RES_BUNDLE" ]; then
    cp "$RES_BUNDLE/menubar-icon.png" "$APP/Contents/Resources/"
    cp "$RES_BUNDLE/menubar-icon@2x.png" "$APP/Contents/Resources/"
    cp "$RES_BUNDLE/AppIcon.icns" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>utility</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

echo ""
echo "=== 4/5 Sign .app ==="
codesign --sign - --force --deep "$APP" 2>/dev/null || true

echo ""
echo "=== 5/5 Package .dmg ==="
DMG="${APP_NAME}-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG"

echo ""
echo "=== Done ==="
echo "App:  $APP"
echo "DMG:  $DMG"
echo ""
echo "Install: open $DMG → drag to /Applications"
