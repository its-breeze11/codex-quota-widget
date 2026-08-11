#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/Codex Quota Widget.app"
MODULE_CACHE="${TMPDIR:-/private/tmp}/codex-quota-widget-module-cache"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

# ── 版本号自动生成 ──────────────────────────────────────────
# 完整版本格式: {MAJOR.MINOR.PATCH}-{YYYYMMDD}-{developer}
#   MAJOR.MINOR.PATCH  手动维护（在 Info.plist 的 CFBundleShortVersionString 中）
#   YYYYMMDD           构建日期，自动生成
#   developer          开发者标识，优先级: $DEVELOPER > .developer 文件 > git user.name
# CFBundleVersion      自动 = git commit 总数
# GitCommitHash        构建时注入，用于排障
BASE_VERSION=$(grep -A1 CFBundleShortVersionString "$ROOT_DIR/Info.plist" | tail -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
GIT_COMMIT_COUNT=$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo "0")
GIT_HASH=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE=$(date +%Y%m%d)

# 解析开发者标识: $DEVELOPER > .developer 文件 > git user.name
if [[ -n "${DEVELOPER:-}" ]]; then
  DEV_NAME="$DEVELOPER"
elif [[ -f "$ROOT_DIR/.developer" ]]; then
  DEV_NAME=$(tr -d '[:space:]' < "$ROOT_DIR/.developer")
else
  DEV_NAME=$(git -C "$ROOT_DIR" config user.name 2>/dev/null || echo "unknown")
fi
# 清理: 小写，非字母数字替换为连字符，合并连续连字符，去首尾连字符
DEV_NAME=$(echo "$DEV_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//')
[[ -z "$DEV_NAME" ]] && DEV_NAME="unknown"

FULL_VERSION="${BASE_VERSION}-${BUILD_DATE}-${DEV_NAME}"

echo "Building version $FULL_VERSION (build $GIT_COMMIT_COUNT, $GIT_HASH)"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
swift build \
  --package-path "$ROOT_DIR" \
  --scratch-path "$BUILD_DIR" \
  --product CodexQuotaWidget \
  --jobs 1 \
  -c release

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

# 复制 Info.plist 并注入自动生成的版本字段
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
PLIST="$APP_DIR/Contents/Info.plist"
"$PLIST_BUDDY" -c "Set :CFBundleVersion $GIT_COMMIT_COUNT" "$PLIST"
"$PLIST_BUDDY" -c "Delete :GitCommitHash" "$PLIST" 2>/dev/null || true
"$PLIST_BUDDY" -c "Add :GitCommitHash string $GIT_HASH" "$PLIST"
"$PLIST_BUDDY" -c "Delete :FullVersionString" "$PLIST" 2>/dev/null || true
"$PLIST_BUDDY" -c "Add :FullVersionString string $FULL_VERSION" "$PLIST"

cp "$BUILD_DIR/release/CodexQuotaWidget" "$APP_DIR/Contents/MacOS/CodexQuotaWidget"
cp "$ROOT_DIR/assets/CodexQuotaWidget.icns" "$APP_DIR/Contents/Resources/CodexQuotaWidget.icns"
chmod +x "$APP_DIR/Contents/MacOS/CodexQuotaWidget"

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
