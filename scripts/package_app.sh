#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/Codex Quota Widget.app"
MODULE_CACHE="${TMPDIR:-/private/tmp}/codex-quota-widget-module-cache"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
swift build \
  --package-path "$ROOT_DIR" \
  --scratch-path "$BUILD_DIR" \
  --product CodexQuotaWidget \
  --jobs 1 \
  -c release

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$BUILD_DIR/release/CodexQuotaWidget" "$APP_DIR/Contents/MacOS/CodexQuotaWidget"
cp "$ROOT_DIR/assets/CodexQuotaWidget.icns" "$APP_DIR/Contents/Resources/CodexQuotaWidget.icns"
chmod +x "$APP_DIR/Contents/MacOS/CodexQuotaWidget"

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
