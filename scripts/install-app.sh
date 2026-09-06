#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="智键.app"
STAGE="$ROOT/.build/app/$APP_NAME"
DEST="/Applications/$APP_NAME"
INFO="$ROOT/packaging/Info.plist"
CONF="$ROOT/smartKey.conf"

if [[ ! -f "$INFO" ]]; then
  echo "缺少 $INFO" >&2
  exit 1
fi
if [[ ! -f "$CONF" ]]; then
  echo "缺少 $CONF" >&2
  exit 1
fi

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

osascript -e 'tell application id "local.smartKey" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -x smartKey >/dev/null 2>&1 || break
  sleep 0.2
done
pkill -x smartKey >/dev/null 2>&1 || true
sleep 0.2

swift build -c release --product smartKey
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/smartKey"
if [[ ! -x "$BIN" ]]; then
  echo "未找到 release 二进制: $BIN" >&2
  exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$INFO" "$STAGE/Contents/Info.plist"
cp "$BIN" "$STAGE/Contents/MacOS/smartKey"
chmod +x "$STAGE/Contents/MacOS/smartKey"
cp "$CONF" "$STAGE/Contents/Resources/smartKey.conf"
echo -n "APPL????" > "$STAGE/Contents/PkgInfo"

codesign --force --sign - --timestamp=none "$STAGE"

if ! ditto "$STAGE" "$DEST"; then
  echo "无法写入 $DEST，请检查权限" >&2
  exit 1
fi
codesign --force --sign - --timestamp=none "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

open "$DEST"
echo "已安装到 $DEST"
