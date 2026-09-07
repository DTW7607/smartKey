#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
BUILD_CONFIGURATION="${SMARTKEY_BUILD_CONFIGURATION:-release}"
case "$BUILD_CONFIGURATION" in release|debug) ;; *) echo "构建类型须为 release 或 debug" >&2; exit 1 ;; esac
SWIFT_OPTIONS=(-c "$BUILD_CONFIGURATION")
if [[ "${SMARTKEY_SWIFT_DISABLE_SANDBOX:-0}" == 1 ]]; then
  SWIFT_OPTIONS+=(--disable-sandbox)
fi
swift build "${SWIFT_OPTIONS[@]}" --product smartKey
BIN_DIR="$(swift build "${SWIFT_OPTIONS[@]}" --show-bin-path)"
APP="$ROOT/.build/release-app/smartKey.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/smartKey" "$APP/Contents/MacOS/smartKey"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/smartKey.conf" "$APP/Contents/Resources/smartKey.conf"
cp "$ROOT/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/smartKey"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "已构建：$APP"
