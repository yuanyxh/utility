#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Utility"
BUNDLE_ID="com.utility.app"
VERSION="1.0.87"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

if [ -z "$SIGNING_IDENTITY" ]; then
    echo "错误: 请设置 SIGNING_IDENTITY 环境变量"
    echo "用法: SIGNING_IDENTITY=YOUR_SHA1_HASH $0"
    echo ""
    echo "获取可用签名: security find-identity -v -p codesigning"
    exit 1
fi

echo "=== 1/5 Clean build ==="
rm -rf .build
swift build -c release

echo ""
echo "=== 2/5 Sign binary ==="
codesign -s "$SIGNING_IDENTITY" --force --options runtime .build/release/utility

echo ""
echo "=== 3/5 Build .app bundle ==="
APP="${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp .build/release/utility "$APP/Contents/MacOS/"

# 产物路径随 SwiftPM 版本变化（旧：.build/arm64-apple-macosx/release，新：.build/out/Products/Release）。
# 用 --show-bin-path 查询实际布局，不硬编码，否则新版下路径不存在会静默漏拷资源。
BIN_PATH="$(swift build -c release --show-bin-path)"
RES_BUNDLE="$BIN_PATH/utility_utility.bundle"
if [ ! -d "$RES_BUNDLE" ]; then
    echo "错误: 未找到资源 bundle: $RES_BUNDLE"
    echo "缺少它会让 app 启动即崩溃 (Fatal error: unable to find bundle named utility_utility)"
    exit 1
fi
# 资源 bundle 必须放进 Contents/Resources/：放 .app 根目录会被 codesign 判为
# "unsealed contents present in the bundle root" 致签名失败。Bundle.module 第一候选即此处。
cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"

# 源码目录跑过 Python 会留下 __pycache__,随 .copy 被打进资源 bundle。
# 必须在签名前清除:残留 .pyc 会被封入 CodeResources,运行时重生成即破坏签名封印。
find "$APP" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true

# bundle 内部布局同样随版本变化（旧：AppIcon.icns 在根，新：Contents/Resources/ 下）
ICON="$RES_BUNDLE/Contents/Resources/AppIcon.icns"
[ -f "$ICON" ] || ICON="$RES_BUNDLE/AppIcon.icns"
if [ ! -f "$ICON" ]; then
    echo "错误: 未找到 AppIcon.icns: $RES_BUNDLE"
    exit 1
fi
cp "$ICON" "$APP/Contents/Resources/"

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
# 必须签 .app 本身并硬校验：签名失败被吞掉时 bundle 无 _CodeSignature/CodeResources、
# Info.plist 未绑定、identifier 退化为可执行文件名,系统将拒绝为其建立通知授权。
codesign -s "$SIGNING_IDENTITY" --force --options runtime --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

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
