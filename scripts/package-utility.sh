#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Utility"
BUNDLE_ID="com.utility.app"
INITIAL_VERSION="1.0.93"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

if [ -z "$SIGNING_IDENTITY" ]; then
    echo "错误: 请设置 SIGNING_IDENTITY 环境变量"
    echo "用法: SIGNING_IDENTITY=YOUR_SHA1_HASH $0"
    echo ""
    echo "获取可用签名: security find-identity -v -p codesigning"
    exit 1
fi

echo "=== 0/6 Gateway 资源 ==="
# app 不再携带 Python 源码：扫 gateway 仓构建 wheel，prompts 同步拷入资源目录。
# 缺仓库或产物缺失一律硬失败——静默跳过会做出一个启动即崩的包。
GATEWAY_REPO="${GATEWAY_REPO:-$(cd .. && pwd)/agent-gateway}"
PYTHON="${PYTHON:-$HOME/.config/utility/mcp-venv/bin/python3}"
[ -d "$GATEWAY_REPO/src/agent_gateway" ] || { echo "错误: 未找到 agent-gateway 仓库: $GATEWAY_REPO"; exit 1; }
[ -x "$PYTHON" ] || { echo "错误: 未找到 Python: $PYTHON"; exit 1; }
rm -rf Sources/Gateway/*.whl Sources/Gateway/prompts
"$PYTHON" -m pip wheel "$GATEWAY_REPO" --no-deps -w Sources/Gateway --quiet --disable-pip-version-check
cp -R "$GATEWAY_REPO/src/agent_gateway/prompts" Sources/Gateway/prompts
ls Sources/Gateway/*.whl >/dev/null 2>&1 || { echo "错误: wheel 构建失败: Sources/Gateway/"; exit 1; }
[ -d Sources/Gateway/prompts ] || { echo "错误: prompts 未拷入 Sources/Gateway/"; exit 1; }
echo "wheel: $(ls Sources/Gateway/*.whl | xargs -n1 basename)"

echo ""
echo "=== 1/6 i18n contract ==="
python3 scripts/gen-l10n.py --check
python3 scripts/check-l10n-contract.py

echo ""
echo "=== 版本自增 ==="
# 版本唯一来源是仓库根目录的 VERSION；每次打包触发即自增 patch（失败也消耗一个版本号）
VERSION_FILE="$PWD/VERSION"
if [ -f "$VERSION_FILE" ]; then
    VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
else
    VERSION="$INITIAL_VERSION"
fi
if [[ ! "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "错误: VERSION 格式非法: ${VERSION}（期望 MAJOR.MINOR.PATCH）"
    exit 1
fi
VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
echo "$VERSION" > "$VERSION_FILE"
echo "版本: ${VERSION}（已写入 ${VERSION_FILE}）"

echo ""
echo "=== 2/6 Clean build ==="
rm -rf .build
swift build -c release

echo ""
echo "=== 3/6 Sign binary ==="
codesign -s "$SIGNING_IDENTITY" --force --options runtime .build/release/utility

echo ""
echo "=== 4/6 Build .app bundle ==="
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

# Gateway 资源必须真的进了 app：缺 wheel 时首启装不了包，app 起来但所有 AI 能力失效。
GATEWAY_IN_APP="$RES_BUNDLE/Contents/Resources/Gateway"
[ -d "$GATEWAY_IN_APP" ] || { echo "错误: 资源 bundle 内缺少 Gateway/: $RES_BUNDLE"; exit 1; }
ls "$GATEWAY_IN_APP"/*.whl >/dev/null 2>&1 || { echo "错误: app 内缺少 gateway wheel: $GATEWAY_IN_APP"; exit 1; }
[ -d "$GATEWAY_IN_APP/prompts" ] || { echo "错误: app 内缺少 prompts: $GATEWAY_IN_APP"; exit 1; }

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
echo "=== 5/6 Sign .app ==="
# 必须签 .app 本身并硬校验：签名失败被吞掉时 bundle 无 _CodeSignature/CodeResources、
# Info.plist 未绑定、identifier 退化为可执行文件名,系统将拒绝为其建立通知授权。
codesign -s "$SIGNING_IDENTITY" --force --options runtime --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo ""
echo "=== 6/6 Package .dmg ==="
DMG="${APP_NAME}-${VERSION}.dmg"
rm -f "$DMG"
diskutil image create from --format UDZO --volumeName "$APP_NAME" "$APP" "$DMG"

echo ""
echo "=== Done ==="
echo "App:  $APP"
echo "DMG:  $DMG"
echo ""
echo "Install: open $DMG → drag to /Applications"
