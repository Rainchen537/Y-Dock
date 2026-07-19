#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$ROOT_DIR/DockWindowPreview.xcodeproj"
SCHEME="DockWindowPreview"
APP_NAME="Y-Dock"
VERSION="$(awk -F ' = ' '/MARKETING_VERSION = / { gsub(/;/, "", $2); print $2; exit }' "$ROOT_DIR/DockWindowPreview.xcodeproj/project.pbxproj")"
WORK_ROOT="$(mktemp -d /tmp/Y-Dock-release.XXXXXX)"
DEBUG_DERIVED_DATA="$WORK_ROOT/DebugDerivedData"
RELEASE_DERIVED_DATA="$WORK_ROOT/ReleaseDerivedData"
DEBUG_APP="$DEBUG_DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
BUILT_APP="$RELEASE_DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
APP_ZIP="$WORK_ROOT/$APP_NAME.zip"
DIST_DIR="$ROOT_DIR/dist"
FINAL_DMG_PATH="$DIST_DIR/$APP_NAME-v$VERSION.dmg"
DMG_WORK="$WORK_ROOT/dmg"
DMG_PATH="$DMG_WORK/$APP_NAME-v$VERSION.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-y-dock-notary}"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
STAGE="$WORK_ROOT/stage"
VERIFY_MOUNT=""

cleanup() {
  if [[ -n "$VERIFY_MOUNT" ]]; then
    hdiutil detach "$VERIFY_MOUNT" >/dev/null 2>&1 || hdiutil detach "$VERIFY_MOUNT" -force >/dev/null 2>&1 || true
    rm -rf "$VERIFY_MOUNT"
  fi
  rm -rf "$WORK_ROOT"
}
trap cleanup EXIT
mkdir -p "$DMG_WORK" "$STAGE"

bold() { print -P "%B$1%b"; }

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '"' '/Developer ID Application.*\(A94225N8T5\)/ { print $2; exit }')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "错误：找不到 Developer ID Application 证书。" >&2
  exit 1
fi

bold "▶ 0/9 检查公证凭据…"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
找不到公证凭据 profile：$NOTARY_PROFILE

请先使用 xcrun notarytool store-credentials 存入钥匙串，或通过环境变量指定：

  NOTARY_PROFILE=你的Profile ./release.sh
EOF
  exit 1
fi
echo "  ✓ 凭据就绪：$NOTARY_PROFILE"
echo "  ✓ 签名证书就绪：$SIGN_IDENTITY"
rm -f "$FINAL_DMG_PATH"

notarize() {
  local target="$1"
  local log
  log="$(mktemp "$WORK_ROOT/notary.XXXXXX")"
  if ! xcrun notarytool submit "$target" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1 | tee "$log"; then
    echo "✗ 公证提交失败：$target" >&2
    rm -f "$log"
    return 1
  fi

  local sid
  sid="$(grep -m1 -E "^[[:space:]]*id:" "$log" | awk '{print $2}')"
  if ! grep -q "status: Accepted" "$log"; then
    echo "✗ 公证未通过：$target" >&2
    [[ -n "$sid" ]] && xcrun notarytool log "$sid" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    rm -f "$log"
    return 1
  fi

  rm -f "$log"
  return 0
}

validate_staple() {
  local target="$1"
  local output
  if ! output="$(xcrun stapler validate "$target" 2>&1)"; then
    print -u2 -- "$output"
    return 1
  fi
  print -r -- "$output"
  if [[ "$output" != *"The validate action worked!"* ]]; then
    echo "✗ 未检测到有效的 stapled ticket：$target" >&2
    return 1
  fi
}

bold "▶ 1/9 Debug 构建…"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -derivedDataPath "$DEBUG_DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build
DEBUG_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEBUG_APP/Contents/Info.plist")"
if [[ "$DEBUG_VERSION" != "$VERSION" ]]; then
  echo "✗ Debug 构建版本 $DEBUG_VERSION 与 DMG 版本 $VERSION 不一致。" >&2
  exit 1
fi

bold "▶ 2/9 Release 构建…"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$RELEASE_DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
  echo "✗ Release 构建版本 $BUILT_VERSION 与 DMG 版本 $VERSION 不一致。" >&2
  exit 1
fi

bold "▶ 3/9 签名 app…"
rm -rf "$STAGE/$APP_NAME.app"
ditto --noextattr --norsrc "$BUILT_APP" "$STAGE/$APP_NAME.app"
xattr -cr "$STAGE/$APP_NAME.app"
codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$STAGE/$APP_NAME.app"
codesign --verify --deep --strict --verbose=2 "$STAGE/$APP_NAME.app"
SIG_INFO="$(codesign -dvvv "$STAGE/$APP_NAME.app" 2>&1)"
if ! grep -q "TeamIdentifier=A94225N8T5" <<< "$SIG_INFO"; then
  echo "✗ app 签名团队不是 A94225N8T5。" >&2
  exit 1
fi
if ! grep -q "flags=.*runtime" <<< "$SIG_INFO"; then
  echo "✗ app 未启用 hardened runtime。" >&2
  exit 1
fi
echo "  ✓ app 签名校验通过"

bold "▶ 4/9 公证并装订 app…"
ditto -c -k --keepParent "$STAGE/$APP_NAME.app" "$APP_ZIP"
notarize "$APP_ZIP"
rm -f "$APP_ZIP"
xcrun stapler staple "$STAGE/$APP_NAME.app"
validate_staple "$STAGE/$APP_NAME.app"
codesign --verify --deep --strict --verbose=2 "$STAGE/$APP_NAME.app"
spctl -a -t exec -vvv "$STAGE/$APP_NAME.app"
echo "  ✓ app 已公证、装订并通过 Gatekeeper 验证"

bold "▶ 5/9 打包 DMG…"
mkdir -p "$DIST_DIR"
APP_PATH_OVERRIDE="$STAGE/$APP_NAME.app" \
VOLUME_NAME_OVERRIDE="$APP_NAME v$VERSION" \
DMG_OUTPUT_PATH_OVERRIDE="$DMG_PATH" \
  "$ROOT_DIR/make_dmg.sh"

bold "▶ 6/9 签名 DMG…"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
codesign --verify --verbose=4 "$DMG_PATH"
echo "  ✓ DMG 签名校验通过"

bold "▶ 7/9 公证 DMG…"
notarize "$DMG_PATH"
echo "  ✓ DMG 已公证"

bold "▶ 8/9 装订 DMG 票据…"
xcrun stapler staple "$DMG_PATH"
validate_staple "$DMG_PATH"
echo "  ✓ DMG 已装订"

bold "▶ 9/9 最终验证…"
spctl -a -vvv -t open --context context:primary-signature "$DMG_PATH"
VERIFY_MOUNT="$(mktemp -d /tmp/Y-Dock-verify.XXXXXX)"
hdiutil attach "$DMG_PATH" -mountpoint "$VERIFY_MOUNT" -nobrowse -noautoopen >/dev/null
codesign --verify --deep --strict --verbose=2 "$VERIFY_MOUNT/$APP_NAME.app"
validate_staple "$VERIFY_MOUNT/$APP_NAME.app"
spctl -a -t exec -vvv "$VERIFY_MOUNT/$APP_NAME.app"
hdiutil detach "$VERIFY_MOUNT" >/dev/null 2>&1 || hdiutil detach "$VERIFY_MOUNT" -force >/dev/null 2>&1
rm -rf "$VERIFY_MOUNT"
VERIFY_MOUNT=""
rm -f "$FINAL_DMG_PATH"
mv "$DMG_PATH" "$FINAL_DMG_PATH"

echo ""
bold "✅ 发布产物完成"
echo "可分发文件：$FINAL_DMG_PATH"
ls -lh "$FINAL_DMG_PATH"
