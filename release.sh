#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$ROOT_DIR/DockWindowPreview.xcodeproj"
SCHEME="DockWindowPreview"
APP_NAME="Y-Dock"
APP_BUNDLE_IDENTIFIER="com.lixingchen.DockWindowPreview"
APP_TEAM_IDENTIFIER="A94225N8T5"
ARCHITECTURES=(arm64 x86_64)
VERSION="$(awk -F ' = ' '/MARKETING_VERSION = / { gsub(/;/, "", $2); print $2; exit }' "$ROOT_DIR/DockWindowPreview.xcodeproj/project.pbxproj")"
BUILD_NUMBER="$(awk -F ' = ' '/CURRENT_PROJECT_VERSION = / { gsub(/;/, "", $2); print $2; exit }' "$ROOT_DIR/DockWindowPreview.xcodeproj/project.pbxproj")"
WORK_ROOT="$(mktemp -d /tmp/Y-Dock-release.XXXXXX)"
DIST_DIR="$ROOT_DIR/dist"
PUBLISH_STATE_DIR="$WORK_ROOT/publish-state"
RELEASE_LOCK_DIR="$DIST_DIR/.$APP_NAME-v$VERSION.release.lock"
NOTARY_PROFILE="${NOTARY_PROFILE:-y-dock-notary}"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
CURRENT_VERIFY_MOUNT=""
RELEASE_SUCCEEDED=0
LOCK_ACQUIRED=0
SOURCE_FINGERPRINT=""
mkdir -p "$PUBLISH_STATE_DIR"

final_dmg_path() {
  local architecture="$1"
  print -r -- "$DIST_DIR/$APP_NAME-v$VERSION-$architecture.dmg"
}

new_dmg_path() {
  local architecture="$1"
  print -r -- "$DIST_DIR/.$APP_NAME-v$VERSION-$architecture.new.$$.dmg"
}

backup_dmg_path() {
  local architecture="$1"
  print -r -- "$DIST_DIR/.$APP_NAME-v$VERSION-$architecture.backup.$$.dmg"
}

cleanup() {
  local exit_status=$?
  local architecture final_dmg new_dmg backup_dmg
  if [[ -n "$CURRENT_VERIFY_MOUNT" ]]; then
    hdiutil detach "$CURRENT_VERIFY_MOUNT" >/dev/null 2>&1 || hdiutil detach "$CURRENT_VERIFY_MOUNT" -force >/dev/null 2>&1 || true
    rm -rf "$CURRENT_VERIFY_MOUNT"
  fi

  for architecture in "${ARCHITECTURES[@]}"; do
    final_dmg="$(final_dmg_path "$architecture")"
    new_dmg="$(new_dmg_path "$architecture")"
    backup_dmg="$(backup_dmg_path "$architecture")"

    if (( RELEASE_SUCCEEDED == 0 )); then
      if [[ -f "$PUBLISH_STATE_DIR/$architecture.published" ]]; then
        rm -f "$final_dmg"
      fi
      if [[ -f "$PUBLISH_STATE_DIR/$architecture.backed-up" && ( -e "$backup_dmg" || -L "$backup_dmg" ) ]]; then
        mv -f "$backup_dmg" "$final_dmg" || echo "✗ 无法恢复原有 $architecture DMG；备份保留在：$backup_dmg" >&2
      fi
      rm -f "$new_dmg"
    else
      rm -f "$new_dmg" "$backup_dmg"
    fi
  done

  if (( LOCK_ACQUIRED == 1 )); then
    rm -rf "$RELEASE_LOCK_DIR"
  fi

  if (( exit_status == 0 )); then
    rm -rf "$WORK_ROOT"
  else
    for architecture in "${ARCHITECTURES[@]}"; do
      rm -rf "$WORK_ROOT/$architecture/DerivedData" "$WORK_ROOT/$architecture/stage"
      rm -f "$WORK_ROOT/$architecture/$APP_NAME-$architecture.zip"
    done
    rm -rf "$WORK_ROOT/tests"
    echo "发布失败，已回滚本轮 dist 切换、清理构建缓存，并保留本次 DMG/公证日志：$WORK_ROOT" >&2
  fi
}
trap cleanup EXIT

bold() { print -P "%B$1%b"; }

retry_apple_service_operation() {
  local label="$1"
  shift
  local attempt
  for attempt in {1..4}; do
    if "$@"; then
      return 0
    fi
    if (( attempt == 4 )); then
      echo "✗ $label 连续 4 次失败。" >&2
      return 1
    fi
    echo "  ! $label 暂时失败，$((attempt * 5)) 秒后重试（$attempt/4）…" >&2
    sleep "$((attempt * 5))"
  done
}

codesign_with_timestamp_retry() {
  retry_apple_service_operation "Apple 签名时间戳服务" codesign "$@"
}

staple_with_retry() {
  local target="$1"
  retry_apple_service_operation "Apple 公证票据装订（${target:t}）" xcrun stapler staple "$target"
}

assert_vendored_release_inputs() {
  local framework_dir="$ROOT_DIR/Y-Framework/DMG"
  local -a symlinks

  if [[ ! -d "$ROOT_DIR/Y-Framework" || -L "$ROOT_DIR/Y-Framework" ]]; then
    echo "✗ 正式发布要求仓库内非符号链接 Y-Framework 根目录。" >&2
    return 1
  fi
  if [[ ! -d "$framework_dir" || -L "$framework_dir" ]]; then
    echo "✗ 正式发布要求仓库内非符号链接 DMG 框架目录：$framework_dir" >&2
    return 1
  fi
  symlinks=("$framework_dir"/**/*(N@))
  if (( ${#symlinks[@]} != 0 )); then
    echo "✗ 正式发布的 vendored DMG 框架不得包含符号链接：${symlinks[1]}" >&2
    return 1
  fi
  if [[ ! -f "$framework_dir/YDMGFramework.zsh" ||
        -L "$framework_dir/YDMGFramework.zsh" ||
        ! -f "$framework_dir/DmgBackgroundGenerator.swift" ||
        -L "$framework_dir/DmgBackgroundGenerator.swift" ]]; then
    echo "✗ 正式发布缺少仓库内 vendored DMG 框架脚本或背景生成器。" >&2
    return 1
  fi
}

release_source_fingerprint() {
  local file file_path list_file manifest_file repo_root hash_output content_hash fingerprint

  repo_root="$(/usr/bin/git -C "$ROOT_DIR" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "✗ 无法确认发布源码仓库。" >&2
    return 1
  }
  if [[ "${repo_root:A}" != "${ROOT_DIR:A}" ]]; then
    echo "✗ 发布源码目录不是独立 Git 仓库根目录：$ROOT_DIR" >&2
    return 1
  fi

  list_file="$(mktemp "$WORK_ROOT/source-files.XXXXXX")" || return 1
  manifest_file="$(mktemp "$WORK_ROOT/source-manifest.XXXXXX")" || {
    rm -f "$list_file"
    return 1
  }

  if ! {
    /usr/bin/git -C "$ROOT_DIR" ls-files -z &&
      /usr/bin/git -C "$ROOT_DIR" ls-files --others --exclude-standard -z
  } > "$list_file"; then
    echo "✗ 无法完整枚举发布源码文件。" >&2
    rm -f "$list_file" "$manifest_file"
    return 1
  fi

  if ! : > "$manifest_file"; then
    echo "✗ 无法初始化发布源码清单。" >&2
    rm -f "$list_file" "$manifest_file"
    return 1
  fi
  while IFS= read -r -d '' file; do
    case "$file" in
      .claude/*|dist/*|build/*|build-*/*|.DS_Store) continue ;;
    esac

    file_path="$ROOT_DIR/$file"
    if ! /usr/bin/printf '%s\0' "$file" >> "$manifest_file"; then
      echo "✗ 无法写入发布源码清单：$file" >&2
      rm -f "$list_file" "$manifest_file"
      return 1
    fi
    if [[ -L "$file_path" ]]; then
      if ! /usr/bin/printf 'symlink:' >> "$manifest_file"; then
        echo "✗ 无法写入发布源码符号链接标记：$file" >&2
        rm -f "$list_file" "$manifest_file"
        return 1
      fi
      if ! /usr/bin/readlink -n "$file_path" >> "$manifest_file"; then
        echo "✗ 无法读取或记录发布源码符号链接：$file" >&2
        rm -f "$list_file" "$manifest_file"
        return 1
      fi
      if ! /usr/bin/printf '\0' >> "$manifest_file"; then
        echo "✗ 无法写入发布源码符号链接分隔符：$file" >&2
        rm -f "$list_file" "$manifest_file"
        return 1
      fi
    elif [[ -f "$file_path" ]]; then
      hash_output="$(/usr/bin/shasum -a 256 < "$file_path")" || {
        echo "✗ 无法计算发布源码文件摘要：$file" >&2
        rm -f "$list_file" "$manifest_file"
        return 1
      }
      content_hash="${hash_output%% *}"
      if [[ ! "$content_hash" =~ '^[0-9a-f]{64}$' ]]; then
        echo "✗ 发布源码文件摘要格式异常：$file" >&2
        rm -f "$list_file" "$manifest_file"
        return 1
      fi
      if ! /usr/bin/printf 'file:%s\0' "$content_hash" >> "$manifest_file"; then
        echo "✗ 无法写入发布源码文件摘要：$file" >&2
        rm -f "$list_file" "$manifest_file"
        return 1
      fi
    elif [[ ! -e "$file_path" ]]; then
      if ! /usr/bin/printf 'deleted\0' >> "$manifest_file"; then
        echo "✗ 无法写入发布源码删除标记：$file" >&2
        rm -f "$list_file" "$manifest_file"
        return 1
      fi
    else
      echo "✗ 发布源码包含不支持的对象类型：$file" >&2
      rm -f "$list_file" "$manifest_file"
      return 1
    fi
  done < "$list_file"

  hash_output="$(/usr/bin/shasum -a 256 "$manifest_file")" || {
    echo "✗ 无法计算发布源码清单摘要。" >&2
    rm -f "$list_file" "$manifest_file"
    return 1
  }
  fingerprint="${hash_output%% *}"
  rm -f "$list_file" "$manifest_file"
  if [[ ! "$fingerprint" =~ '^[0-9a-f]{64}$' ]]; then
    echo "✗ 发布源码指纹格式异常。" >&2
    return 1
  fi
  print -r -- "$fingerprint"
}

assert_release_source_unchanged() {
  local phase="$1"
  local current_fingerprint
  current_fingerprint="$(release_source_fingerprint)" || {
    echo "✗ 无法在 $phase 复核发布源码指纹。" >&2
    return 1
  }
  if [[ "$current_fingerprint" != "$SOURCE_FINGERPRINT" ]]; then
    echo "✗ $phase 检测到仓库源码发生变化，拒绝混合不同源码生成双架构发布包。" >&2
    return 1
  fi
}

assert_version() {
  local app_path="$1"
  local label="$2"
  local app_version app_build
  app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
  app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")"
  if [[ "$app_version" != "$VERSION" || "$app_build" != "$BUILD_NUMBER" ]]; then
    echo "✗ $label 版本 $app_version ($app_build) 与项目版本 $VERSION ($BUILD_NUMBER) 不一致。" >&2
    exit 1
  fi
}

assert_app_architecture() {
  local app_path="$1"
  local expected_architecture="$2"
  local label="$3"
  local executable="$app_path/Contents/MacOS/$APP_NAME"
  local actual_architectures
  if [[ ! -f "$executable" ]]; then
    echo "✗ $label 缺少可执行文件：$executable" >&2
    exit 1
  fi
  actual_architectures="$(/usr/bin/lipo -archs "$executable" | xargs)"
  if [[ "$actual_architectures" != "$expected_architecture" ]]; then
    echo "✗ $label 架构应严格为 $expected_architecture，实际为：$actual_architectures" >&2
    exit 1
  fi
  echo "  ✓ $label 为 thin $expected_architecture"
}

notarize() {
  local target="$1"
  local log
  local sid=""
  log="$(mktemp "$WORK_ROOT/notary.XXXXXX")"

  if xcrun notarytool submit "$target" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1 | tee "$log"; then
    sid="$(awk '/^[[:space:]]*id:/ { print $2; exit }' "$log")"
    if grep -q "status: Accepted" "$log"; then
      rm -f "$log"
      return 0
    fi
  else
    sid="$(awk '/^[[:space:]]*id:/ { print $2; exit }' "$log")"
    if [[ -n "$sid" ]]; then
      echo "  ! 公证等待连接中断，继续等待已提交任务。"
      if xcrun notarytool wait "$sid" \
            --keychain-profile "$NOTARY_PROFILE" \
            2>&1 | tee -a "$log" && \
          grep -q "status: Accepted" "$log"; then
        rm -f "$log"
        return 0
      fi
    fi
  fi

  if [[ -z "$sid" ]]; then
    echo "✗ 公证提交失败且没有返回 submission ID：$target" >&2
  else
    echo "✗ 公证未通过或等待失败：$target" >&2
    xcrun notarytool info "$sid" \
      --keychain-profile "$NOTARY_PROFILE" >&2 || true
    xcrun notarytool log "$sid" \
      --keychain-profile "$NOTARY_PROFILE" >&2 || true
  fi
  return 1
}

validate_staple() {
  local target="$1"
  local output
  local attempt

  for attempt in {1..4}; do
    if output="$(xcrun stapler validate "$target" 2>&1)" &&
        [[ "$output" == *"The validate action worked!"* ]]; then
      print -r -- "$output"
      return 0
    fi

    print -u2 -- "$output"
    if (( attempt == 4 )); then
      echo "✗ Apple 公证票据验证（${target:t}）连续 4 次失败。" >&2
      return 1
    fi
    echo "  ! Apple 公证票据验证（${target:t}）暂时失败，$((attempt * 5)) 秒后重试（$attempt/4）…" >&2
    sleep "$((attempt * 5))"
  done
}

run_standalone_tests() {
  local sdk test_dir architecture selector_test_binary policy_test_binary actual_architecture
  sdk="$(xcrun --sdk macosx --show-sdk-path)"
  test_dir="$WORK_ROOT/tests"
  mkdir -p "$test_dir"

  for architecture in "${ARCHITECTURES[@]}"; do
    selector_test_binary="$test_dir/UpdateAssetSelectorTests-$architecture"
    xcrun swiftc \
      -target "$architecture-apple-macos13.0" \
      -sdk "$sdk" \
      "$ROOT_DIR/DockWindowPreview/UpdateAssetSelector.swift" \
      "$ROOT_DIR/Tests/UpdateAssetSelectorTests.swift" \
      -o "$selector_test_binary"
    actual_architecture="$(/usr/bin/lipo -archs "$selector_test_binary" | /usr/bin/xargs)"
    if [[ "$actual_architecture" != "$architecture" ]]; then
      echo "✗ selector 测试应编译为 $architecture，实际为：$actual_architecture" >&2
      return 1
    fi
    "$selector_test_binary"
    rm -f "$selector_test_binary"

    policy_test_binary="$test_dir/AppSettingsPolicyTests-$architecture"
    xcrun swiftc \
      -target "$architecture-apple-macos13.0" \
      -sdk "$sdk" \
      "$ROOT_DIR/DockWindowPreview/AppSettings.swift" \
      "$ROOT_DIR/Tests/AppSettingsPolicyTests.swift" \
      -o "$policy_test_binary"
    actual_architecture="$(/usr/bin/lipo -archs "$policy_test_binary" | /usr/bin/xargs)"
    if [[ "$actual_architecture" != "$architecture" ]]; then
      echo "✗ settings policy 测试应编译为 $architecture，实际为：$actual_architecture" >&2
      return 1
    fi
    "$policy_test_binary"
    rm -f "$policy_test_binary"
  done
  rmdir "$test_dir"
}

verify_distribution_dmg() {
  local dmg_path="$1"
  local architecture="$2"
  local label="$3"
  local mounted_app

  codesign --verify --verbose=4 "$dmg_path"
  validate_staple "$dmg_path"
  hdiutil verify "$dmg_path"
  spctl -a -vvv -t open --context context:primary-signature "$dmg_path"

  CURRENT_VERIFY_MOUNT="$(mktemp -d "/tmp/Y-Dock-$architecture-dist-verify.XXXXXX")"
  hdiutil attach "$dmg_path" -mountpoint "$CURRENT_VERIFY_MOUNT" -nobrowse -readonly -noautoopen >/dev/null
  mounted_app="$CURRENT_VERIFY_MOUNT/$APP_NAME.app"
  codesign --verify --deep --strict --verbose=2 "$mounted_app"
  validate_staple "$mounted_app"
  spctl -a -t exec -vvv "$mounted_app"
  assert_version "$mounted_app" "$label 内 App"
  assert_app_architecture "$mounted_app" "$architecture" "$label 内 App"
  hdiutil detach "$CURRENT_VERIFY_MOUNT" >/dev/null 2>&1 || hdiutil detach "$CURRENT_VERIFY_MOUNT" -force >/dev/null 2>&1
  rm -rf "$CURRENT_VERIFY_MOUNT"
  CURRENT_VERIFY_MOUNT=""
}

release_architecture() {
  local architecture="$1"
  local architecture_root="$WORK_ROOT/$architecture"
  local derived_data="$architecture_root/DerivedData"
  local debug_app="$derived_data/Build/Products/Debug/$APP_NAME.app"
  local built_app="$derived_data/Build/Products/Release/$APP_NAME.app"
  local stage="$architecture_root/stage"
  local staged_app="$stage/$APP_NAME.app"
  local app_zip="$architecture_root/$APP_NAME-$architecture.zip"
  local dmg_work="$architecture_root/dmg"
  local dmg_path="$dmg_work/$APP_NAME-v$VERSION-$architecture.dmg"
  local mounted_app
  local signature_info

  mkdir -p "$stage" "$dmg_work"
  rm -rf "$derived_data" "$staged_app"
  rm -f "$app_zip" "$dmg_path"

  bold "▶ [$architecture] 1/9 Debug thin 构建…"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -derivedDataPath "$derived_data" \
    ARCHS="$architecture" \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    build
  assert_version "$debug_app" "$architecture Debug 构建"
  assert_app_architecture "$debug_app" "$architecture" "$architecture Debug App"

  bold "▶ [$architecture] 2/9 Release thin 构建…"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    ARCHS="$architecture" \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    build
  assert_version "$built_app" "$architecture Release 构建"
  assert_app_architecture "$built_app" "$architecture" "$architecture Release App"

  bold "▶ [$architecture] 3/9 独立签名 App…"
  ditto --noextattr --norsrc "$built_app" "$staged_app"
  xattr -cr "$staged_app"
  assert_app_architecture "$staged_app" "$architecture" "$architecture stage App"
  codesign_with_timestamp_retry --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$staged_app"
  codesign --verify --deep --strict --verbose=2 "$staged_app"
  assert_app_architecture "$staged_app" "$architecture" "$architecture 已签名 App"
  signature_info="$(codesign -dvvv "$staged_app" 2>&1)"
  if ! grep -q "Identifier=$APP_BUNDLE_IDENTIFIER" <<< "$signature_info"; then
    echo "✗ $architecture App 签名标识不是 $APP_BUNDLE_IDENTIFIER。" >&2
    exit 1
  fi
  if ! grep -q "Authority=Developer ID Application" <<< "$signature_info"; then
    echo "✗ $architecture App 未用 Developer ID Application 签名。" >&2
    exit 1
  fi
  if ! grep -q "TeamIdentifier=$APP_TEAM_IDENTIFIER" <<< "$signature_info"; then
    echo "✗ $architecture App 签名团队不是 $APP_TEAM_IDENTIFIER。" >&2
    exit 1
  fi
  if ! grep -q "flags=.*runtime" <<< "$signature_info"; then
    echo "✗ $architecture App 未启用 hardened runtime。" >&2
    exit 1
  fi
  echo "  ✓ $architecture App 独立签名校验通过"

  bold "▶ [$architecture] 4/9 独立公证并装订 App…"
  ditto -c -k --keepParent "$staged_app" "$app_zip"
  notarize "$app_zip"
  rm -f "$app_zip"
  staple_with_retry "$staged_app"
  validate_staple "$staged_app"
  codesign --verify --deep --strict --verbose=2 "$staged_app"
  spctl -a -t exec -vvv "$staged_app"
  assert_app_architecture "$staged_app" "$architecture" "$architecture 已公证 App"
  echo "  ✓ $architecture App 已独立公证、装订并通过 Gatekeeper 验证"

  bold "▶ [$architecture] 5/9 独立打包 DMG…"
  Y_RELEASE_REQUIRE_VENDORED=1 \
  APP_PATH_OVERRIDE="$staged_app" \
  VOLUME_NAME_OVERRIDE="$APP_NAME v$VERSION $architecture" \
  DMG_OUTPUT_PATH_OVERRIDE="$dmg_path" \
    "$ROOT_DIR/make_dmg.sh"
  if [[ ! -f "$dmg_path" ]]; then
    echo "✗ $architecture DMG 未生成：$dmg_path" >&2
    exit 1
  fi

  bold "▶ [$architecture] 6/9 独立签名 DMG…"
  codesign_with_timestamp_retry --force --timestamp --sign "$SIGN_IDENTITY" "$dmg_path"
  codesign --verify --verbose=4 "$dmg_path"
  echo "  ✓ $architecture DMG 独立签名校验通过"

  bold "▶ [$architecture] 7/9 独立公证 DMG…"
  notarize "$dmg_path"
  echo "  ✓ $architecture DMG 已独立公证"

  bold "▶ [$architecture] 8/9 装订并验证 DMG…"
  staple_with_retry "$dmg_path"
  validate_staple "$dmg_path"
  hdiutil verify "$dmg_path"
  spctl -a -vvv -t open --context context:primary-signature "$dmg_path"
  echo "  ✓ $architecture DMG 已装订并通过镜像与 Gatekeeper 校验"

  bold "▶ [$architecture] 9/9 挂载复核并严格断言架构…"
  CURRENT_VERIFY_MOUNT="$(mktemp -d "/tmp/Y-Dock-$architecture-verify.XXXXXX")"
  hdiutil attach "$dmg_path" -mountpoint "$CURRENT_VERIFY_MOUNT" -nobrowse -readonly -noautoopen >/dev/null
  mounted_app="$CURRENT_VERIFY_MOUNT/$APP_NAME.app"
  codesign --verify --deep --strict --verbose=2 "$mounted_app"
  validate_staple "$mounted_app"
  spctl -a -t exec -vvv "$mounted_app"
  assert_version "$mounted_app" "$architecture DMG 内 App"
  assert_app_architecture "$mounted_app" "$architecture" "$architecture DMG 内 App"
  hdiutil detach "$CURRENT_VERIFY_MOUNT" >/dev/null 2>&1 || hdiutil detach "$CURRENT_VERIFY_MOUNT" -force >/dev/null 2>&1
  rm -rf "$CURRENT_VERIFY_MOUNT"
  CURRENT_VERIFY_MOUNT=""
  echo "  ✓ $architecture DMG 挂载复核完成"
}

mkdir -p "$DIST_DIR"
if ! mkdir "$RELEASE_LOCK_DIR" 2>/dev/null; then
  echo "✗ 已有同版本 Y-Dock 发布流程或上次异常退出留下的锁：$RELEASE_LOCK_DIR" >&2
  echo "  请先确认没有 release.sh 正在运行，并检查 dist 中的 .backup/.new 文件后再移除该锁。" >&2
  exit 1
fi
LOCK_ACQUIRED=1
assert_vendored_release_inputs || exit 1
SOURCE_FINGERPRINT="$(release_source_fingerprint)" || {
  echo "✗ 无法记录发布源码指纹。" >&2
  exit 1
}
echo "  ✓ 已锁定本轮发布源码指纹"

bold "▶ 运行双架构 standalone 测试…"
run_standalone_tests
assert_release_source_unchanged "双架构 standalone 测试后"
echo "  ✓ updater selector、主可执行文件架构与 settings policy 测试通过"

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '"' '/Developer ID Application.*\(A94225N8T5\)/ { print $2; exit }')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "错误：找不到所需的 Developer ID Application 证书。" >&2
  exit 1
fi

bold "▶ 检查公证配置…"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
找不到可用的公证配置。

请先使用 xcrun notarytool store-credentials 存入钥匙串，或通过 NOTARY_PROFILE 指定已保存的 profile 后重试。
EOF
  exit 1
fi
echo "  ✓ 公证配置可用"
echo "  ✓ 签名证书可用"

for architecture in "${ARCHITECTURES[@]}"; do
  for target in "$(final_dmg_path "$architecture")" "$(new_dmg_path "$architecture")" "$(backup_dmg_path "$architecture")"; do
    if [[ -d "$target" && ! -L "$target" ]]; then
      echo "✗ 发布目标路径被目录占用：$target" >&2
      exit 1
    fi
  done
done

for architecture in "${ARCHITECTURES[@]}"; do
  assert_release_source_unchanged "$architecture 架构构建前"
  release_architecture "$architecture"
  assert_release_source_unchanged "$architecture 架构完整产物生成后"
done

assert_release_source_unchanged "双架构 source DMG 成套预检前"
for architecture in "${ARCHITECTURES[@]}"; do
  source_dmg="$WORK_ROOT/$architecture/dmg/$APP_NAME-v$VERSION-$architecture.dmg"
  if [[ ! -f "$source_dmg" || -L "$source_dmg" ]]; then
    echo "✗ 缺少本次构建的常规 $architecture DMG，拒绝复制或使用旧产物。" >&2
    exit 1
  fi
  verify_distribution_dmg "$source_dmg" "$architecture" "$architecture source DMG"
done

echo "  ✓ 两个 source DMG 已成套预检"
for architecture in "${ARCHITECTURES[@]}"; do
  source_dmg="$WORK_ROOT/$architecture/dmg/$APP_NAME-v$VERSION-$architecture.dmg"
  staged_dmg="$(new_dmg_path "$architecture")"
  rm -f "$staged_dmg"
  /bin/cp -p "$source_dmg" "$staged_dmg"
  if [[ ! -f "$staged_dmg" || -L "$staged_dmg" ]]; then
    echo "✗ $architecture .new DMG 不是普通文件。" >&2
    exit 1
  fi
  verify_distribution_dmg "$staged_dmg" "$architecture" "$architecture dist .new DMG"
done

echo "  ✓ 两个 .new DMG 已完成复制后完整验证"
assert_release_source_unchanged "双架构最终文件切换前"
bold "▶ 成套备份并切换两个最终发布文件…"
for architecture in "${ARCHITECTURES[@]}"; do
  final_dmg="$(final_dmg_path "$architecture")"
  backup_dmg="$(backup_dmg_path "$architecture")"
  rm -f "$backup_dmg"
  if [[ -e "$final_dmg" || -L "$final_dmg" ]]; then
    touch "$PUBLISH_STATE_DIR/$architecture.backed-up"
    mv "$final_dmg" "$backup_dmg"
  fi
done

for architecture in "${ARCHITECTURES[@]}"; do
  final_dmg="$(final_dmg_path "$architecture")"
  staged_dmg="$(new_dmg_path "$architecture")"
  touch "$PUBLISH_STATE_DIR/$architecture.published"
  mv "$staged_dmg" "$final_dmg"
  if [[ ! -f "$final_dmg" || -L "$final_dmg" ]]; then
    echo "✗ $architecture 最终 DMG 原子落位失败。" >&2
    exit 1
  fi
done

for architecture in "${ARCHITECTURES[@]}"; do
  final_dmg="$(final_dmg_path "$architecture")"
  verify_distribution_dmg "$final_dmg" "$architecture" "$architecture final DMG"
done

assert_release_source_unchanged "双架构最终产物验证后"
RELEASE_SUCCEEDED=1
print ""
bold "双架构发布产物已成套完成"
for architecture in "${ARCHITECTURES[@]}"; do
  final_dmg="$(final_dmg_path "$architecture")"
  echo "可分发文件：$final_dmg"
  ls -lh "$final_dmg"
done
