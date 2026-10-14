#!/usr/bin/env bash
#
# 签名打包：archive（Developer ID 签名）→ 导出 → 校验签名 → 公证 + 装订 → zip + dmg（dmg 也公证、装订）。
# 不改版本号、不碰 git，用 project.yml 当前的版本号。scripts/release.sh 发布时调用它；
# 单独运行可以打一个能直接发给别人安装的包。流程与 FreeMind 的 package.sh 相同。
#
# 用法：
#   scripts/package.sh                 # 完整打包（需要公证配置）
#   scripts/package.sh --no-notarize   # 只签名、不公证：验证签名流程用，产物在别的电脑上会被 Gatekeeper 拦下
#
# 产物：
#   build/dist/GrapherNG-<版本>.zip   Sparkle 自动更新下载的就是它
#   build/dist/GrapherNG-<版本>.dmg   手动下载安装用（拖进“应用程序”）
#   不公证时文件名带 -unnotarized，避免误发布。
#
# 签名身份由本脚本在命令行指定，project.yml 里仍是 ad-hoc 签名——没有证书的人照样能编译运行。
# 一次性准备工作见 docs/release.md。
#
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${TEAM_ID:-T8F5T6HKG8}"
NOTARY_PROFILE="${NOTARY_PROFILE:-noticky-notary}"
PROJECT="GrapherNG.xcodeproj"
SCHEME="GrapherNG"
PRODUCT="GrapherNG"
DISPLAY_NAME="Grapher NG"
# 和日常开发共用一份派生数据：SPM 包（Sparkle）已经解析在这里，打包时不联网拉包。
# archive 的中间产物在 ArchiveIntermediates 下，不会覆盖 Build/Products 里的开发版本。
DERIVED_DATA="build/DerivedData"
WORK_DIR="build/release"
ARCHIVE="$WORK_DIR/$PRODUCT.xcarchive"
EXPORT_DIR="$WORK_DIR/export"
DIST_DIR="build/dist"
EXPORT_OPTIONS="scripts/ExportOptions.plist"

NOTARIZE=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-notarize) NOTARIZE=false; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }

# 提交公证并等结果；只认输出里的 status: Accepted（不依赖 notarytool 的退出码）
notarize() {
    local file="$1" log="$2" id
    echo "==> 提交公证：$(basename "$file")（等待结果，通常几分钟）"
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$log" || true
    if ! grep -q "status: Accepted" "$log"; then
        id="$(grep -m1 -E '^ *id: ' "$log" | sed -E 's/^ *id: //' || true)"
        echo "ERROR: 公证没通过：$file（完整输出 $log）" >&2
        echo "       查看原因：xcrun notarytool log ${id:-<submission-id>} --keychain-profile $NOTARY_PROFILE" >&2
        exit 1
    fi
}

# ── 检查 ────────────────────────────────────────────────────────────
for cmd in xcodegen xcodebuild hdiutil ditto; do
    command -v "$cmd" >/dev/null || fail "找不到命令 $cmd"
done

# 管道末尾不用 grep -q：pipefail 下前面的命令可能因 SIGPIPE 被判失败
IDENTITY="$(security find-identity -v -p codesigning \
    | sed -nE "s/.*\"(Developer ID Application: .*\($TEAM_ID\))\".*/\1/p" | head -1)"
[[ -n "$IDENTITY" ]] || fail "钥匙串里没有 team $TEAM_ID 的 Developer ID Application 证书（见 docs/release.md）"

if [[ "$NOTARIZE" == true ]]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "读不到 notarytool 配置 '$NOTARY_PROFILE'（见 docs/release.md），或用 NOTARY_PROFILE=<配置名> 指定"
fi

[[ -d "$DERIVED_DATA/SourcePackages/artifacts/sparkle" ]] \
    || fail "SPM 包还没解析（缺 Sparkle），先运行：
  xcodegen && xcodebuild -project $PROJECT -scheme $SCHEME -derivedDataPath $DERIVED_DATA -resolvePackageDependencies"

xcodegen >/dev/null
read_setting() { grep -m1 "$1:" project.yml | sed -E 's/.*"([^"]*)".*/\1/'; }
VERSION="$(read_setting MARKETING_VERSION)"
BUILD="$(read_setting CURRENT_PROJECT_VERSION)"
SUFFIX=""
[[ "$NOTARIZE" == true ]] || SUFFIX="-unnotarized"
ZIP="$DIST_DIR/$PRODUCT-$VERSION$SUFFIX.zip"
DMG="$DIST_DIR/$PRODUCT-$VERSION$SUFFIX.dmg"
APP="$EXPORT_DIR/$PRODUCT.app"

echo "==> 打包 $PRODUCT $VERSION (build $BUILD)，签名身份：$IDENTITY"

# 只清本脚本自己的产物
rm -rf "$ARCHIVE" "$EXPORT_DIR"
rm -f "$ZIP" "$DMG"
mkdir -p "$WORK_DIR" "$DIST_DIR"

# ── archive + Developer ID 导出 ─────────────────────────────────────
echo "==> archive（Release，Developer ID 签名 + 时间戳）"
xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination "generic/platform=macOS" -archivePath "$ARCHIVE" \
    -derivedDataPath "$DERIVED_DATA" -disableAutomaticPackageResolution -quiet \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp"
[[ -d "$ARCHIVE" ]] || fail "没有生成 archive：$ARCHIVE"

echo "==> 导出（$EXPORT_OPTIONS）"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" -quiet
[[ -d "$APP" ]] || fail "导出的 app 不存在：$APP"

# ── 校验签名：App、两个扩展、三个框架都要是本团队的 Developer ID，带 hardened runtime，没有调试权限 ──
echo "==> 校验签名"
codesign --verify --deep --strict --verbose=2 "$APP"
check_signed() {
    local path="$1" info
    info="$(codesign -dv --verbose=4 "$path" 2>&1)"
    grep "TeamIdentifier=$TEAM_ID" <<<"$info" >/dev/null || fail "$path 的签名不是 team $TEAM_ID"
    grep "Authority=Developer ID Application" <<<"$info" >/dev/null || fail "$path 不是 Developer ID 签名"
    grep -E "flags=.*runtime" <<<"$info" >/dev/null || fail "$path 没有开启 hardened runtime"
    grep "Timestamp=" <<<"$info" >/dev/null || fail "$path 的签名没有时间戳"
    if codesign -d --entitlements - --xml "$path" 2>/dev/null | grep "get-task-allow" >/dev/null; then
        fail "$path 带有 get-task-allow 调试权限，公证会被拒"
    fi
    echo "    ✓ ${path#"$EXPORT_DIR/"}"
}
check_signed "$APP"
for item in "$APP"/Contents/PlugIns/*.appex "$APP"/Contents/Frameworks/*.framework; do
    [[ -e "$item" ]] && check_signed "$item"
done

# ── 公证 app → 装订 → 最终 zip ──────────────────────────────────────
if [[ "$NOTARIZE" == true ]]; then
    NOTARIZE_ZIP="$WORK_DIR/$PRODUCT-$VERSION-notarize.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARIZE_ZIP"
    notarize "$NOTARIZE_ZIP" "$WORK_DIR/notary-app.log"
    rm -f "$NOTARIZE_ZIP"
    echo "==> 装订公证票据到 app"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl -a -t exec -vv "$APP" 2>&1 || true
fi

# --sequesterRsrc：不加的话 Finder 解压会在包里留下 ._ 文件，破坏签名
echo "==> 打 zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# ── dmg（拖进“应用程序”安装）──────────────────────────────────────────
echo "==> 做 dmg"
DMG_STAGE="$WORK_DIR/dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/$PRODUCT.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "$DISPLAY_NAME $VERSION" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_STAGE"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ "$NOTARIZE" == true ]]; then
    notarize "$DMG" "$WORK_DIR/notary-dmg.log"
    echo "==> 装订公证票据到 dmg"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi

echo ""
echo "完成：$PRODUCT $VERSION (build $BUILD)"
echo "  zip：$ZIP ($(du -h "$ZIP" | cut -f1))"
echo "  dmg：$DMG ($(du -h "$DMG" | cut -f1))"
if [[ "$NOTARIZE" != true ]]; then
    echo "  ⚠️ 没有公证：只能在本机验证，别发给别人"
fi
