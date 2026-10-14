#!/usr/bin/env bash
#
# 发布新版本到 GitHub，并通过 Sparkle 推送给已安装的用户：
#   改版本号 → 跑测试 → 提交 → scripts/package.sh（签名、公证、zip + dmg）→ Sparkle 签名 zip
#   → 更新 appcast.xml → 打 tag → 推送 main 和 tag → GitHub release 上传 zip + dmg → 推送 appcast.xml
#
# 照 FreeMind 的 release.sh 改写（源自 agent-home/.claude/skills/release-macos-app 的模板，流程与 UniReader 相同）：
#   - 发布日志必须提前写好（--notes-file），中英双语用 <!-- lang:zh --> / <!-- lang:en --> 分段，
#     Sparkle 按用户系统语言显示对应段落；GitHub release 正文用同一个文件（标记是看不见的 HTML 注释）
#   - 公证全部通过之后才推送：中途失败时远端什么都没变，退出时会打印怎么撤销本地提交
#   - --dry-run 只做检查、改版本号、跑测试，然后把 project.yml 还原，不提交、不打包、不推送
#
# 用法：
#   scripts/release.sh <版本号> --notes-file <路径> [--dry-run]
# 例：
#   scripts/release.sh 1.0.1 --notes-file release-notes/v1.0.1.md --dry-run   # 先演练
#   scripts/release.sh 1.0.1 --notes-file release-notes/v1.0.1.md             # 正式发布（公开）
#
# 一次性准备工作见 docs/release.md。
#
set -euo pipefail

TEAM_ID="${TEAM_ID:-T8F5T6HKG8}"
NOTARY_PROFILE="${NOTARY_PROFILE:-noticky-notary}"
PROJECT="GrapherNG.xcodeproj"
SCHEME="GrapherNG"
# 产物文件名用 PRODUCT（GrapherNG-<版本>.zip），release 标题与 appcast 用显示名。
PRODUCT="GrapherNG"
DISPLAY_NAME="Grapher NG"
GH_REPO="xVanTuring/grapher-ng"
PROJECT_YML="project.yml"
INFO_PLIST="Sources/GrapherApp/Resources/Info.plist"
DERIVED_DATA="build/DerivedData"
SPARKLE_BIN_DIR="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"
APPCAST="appcast.xml"
APPCAST_MARKER="<!-- BEGIN-ITEMS (release.sh inserts new entries here, newest first) -->"

usage() {
    cat <<EOF >&2
用法: $(basename "$0") <版本号> --notes-file <路径> [--dry-run]

  <版本号>            MARKETING_VERSION，形如 1.0.1（构建号自动 +1）
  --notes-file 路径   提前写好的发布日志（Markdown），必填
  --dry-run           只做检查 + 改版本号 + 跑测试，然后还原 project.yml
EOF
    exit 1
}

VERSION=""; NOTES_FILE=""; DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --notes-file) NOTES_FILE="${2:?--notes-file 需要一个路径}"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -h|--help)    usage ;;
        -*)           echo "未知选项: $1" >&2; usage ;;
        *) if [[ -z "$VERSION" ]]; then VERSION="$1"; shift
           else echo "多余的参数: $1" >&2; usage; fi ;;
    esac
done

[[ -n "$VERSION" ]] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: 版本号应为 X.Y.Z（收到 '$VERSION'）" >&2; exit 1; }
[[ -n "$NOTES_FILE" ]] || { echo "ERROR: 必须用 --notes-file 指定提前写好的发布日志" >&2; usage; }
[[ -s "$NOTES_FILE" ]] || { echo "ERROR: 发布日志不存在或是空文件: $NOTES_FILE" >&2; exit 1; }

# 日志路径按调用时的目录解析，再切到仓库根目录
NOTES_FILE="$(cd "$(dirname "$NOTES_FILE")" && pwd)/$(basename "$NOTES_FILE")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 日志在仓库里且没被忽略 → 检查工作区时放过它，并随版本号一起提交
NOTES_IN_REPO=""
case "$NOTES_FILE" in
    "$ROOT"/*)
        NOTES_IN_REPO="${NOTES_FILE#"$ROOT"/}"
        if git check-ignore -q "$NOTES_IN_REPO"; then NOTES_IN_REPO=""; fi
        ;;
esac

TAG="v$VERSION"
TITLE="$DISPLAY_NAME $VERSION"
ZIP="build/dist/$PRODUCT-$VERSION.zip"
DMG="build/dist/$PRODUCT-$VERSION.dmg"

# ── 中途退出时的收尾 ────────────────────────────────────────────────
# STAGE：bumped（改了 project.yml 未提交）→ committed → tagged → pushed → released
STAGE=""
on_exit() {
    local rc=$?
    case "$STAGE" in
        bumped)
            echo "==> 还原 $PROJECT_YML 并重新生成工程"
            git checkout HEAD -- "$PROJECT_YML"
            xcodegen >/dev/null 2>&1 || true
            ;;
        committed|tagged)
            if [[ $rc -ne 0 ]]; then
                echo "" >&2
                echo "发布中断：版本号提交还在本地，没有推送，远端没有变化。重试前先撤销：" >&2
                if [[ "$STAGE" == "tagged" ]]; then echo "  git tag -d $TAG" >&2; fi
                echo "  git reset HEAD~1 && git checkout -- $PROJECT_YML $APPCAST && xcodegen" >&2
            fi
            ;;
        pushed)
            if [[ $rc -ne 0 ]]; then
                echo "" >&2
                echo "发布中断：main 和 $TAG 已推送，但 GitHub release 没建成。产物还在，可以手动补建：" >&2
                echo "  gh release create $TAG --repo $GH_REPO --verify-tag --title \"$TITLE\" --notes-file \"$NOTES_FILE\" $ZIP $DMG" >&2
            fi
            ;;
        released)
            if [[ $rc -ne 0 ]]; then
                echo "" >&2
                echo "发布中断：GitHub release $TAG 已建好，但 $APPCAST 的提交 / 推送失败，老用户暂时收不到更新。手动补：" >&2
                echo "  git add $APPCAST && git commit -m \"appcast: $TAG\" && git push origin main" >&2
            fi
            ;;
    esac
    exit "$rc"
}
trap on_exit EXIT

fail() { echo "ERROR: $*" >&2; exit 1; }
# 演练时一次性配置缺失只警告（演练只验证版本号和编译这条主线），正式发布严格拦下
precheck_fail() {
    if [[ "$DRY_RUN" == true ]]; then echo "WARN: $*（演练继续，正式发布会在这里停下）" >&2; else fail "$*"; fi
}

echo "==> 版本 $VERSION  •  tag $TAG  •  产物 $ZIP + $DMG"
if [[ "$DRY_RUN" == true ]]; then echo "==> [dry-run] 演练模式"; fi

# ── 发布前检查 ──────────────────────────────────────────────────────
echo "==> 发布前检查"
for cmd in xcodegen xcodebuild gh hdiutil python3; do
    command -v "$cmd" >/dev/null || fail "找不到命令 $cmd"
done
gh auth status >/dev/null 2>&1 || fail "gh 没登录，先运行 gh auth login"
[[ -d "$DERIVED_DATA/SourcePackages/artifacts/sparkle" ]] \
    || fail "SPM 包还没解析（缺 Sparkle），先运行：
  xcodegen && xcodebuild -project $PROJECT -scheme $SCHEME -derivedDataPath $DERIVED_DATA -resolvePackageDependencies"

[[ -f "$APPCAST" ]] || fail "找不到 $APPCAST"
grep -qF "$APPCAST_MARKER" "$APPCAST" || fail "$APPCAST 里没有 BEGIN-ITEMS 标记，拒绝写入（可能被手改坏了）"

ED_PUBKEY="$(plutil -extract SUPublicEDKey raw -o - "$INFO_PLIST" 2>/dev/null || true)"
[[ -n "$ED_PUBKEY" ]] || fail "$INFO_PLIST 里的 SUPublicEDKey 是空的（见 docs/release.md）"
[[ -x "$SPARKLE_BIN_DIR/sign_update" ]] || fail "找不到 Sparkle 的 sign_update（$SPARKLE_BIN_DIR）"
# 钥匙串里的私钥必须和 App 里写的公钥是一对，否则签出来的更新所有用户都会拒收
KEYCHAIN_PUBKEY="$("$SPARKLE_BIN_DIR/generate_keys" -p 2>/dev/null || true)"
if [[ -z "$KEYCHAIN_PUBKEY" ]]; then
    precheck_fail "登录钥匙串里没有 Sparkle EdDSA 私钥。换了电脑就导入备份：$SPARKLE_BIN_DIR/generate_keys -f <私钥文件>"
elif [[ "$KEYCHAIN_PUBKEY" != "$ED_PUBKEY" ]]; then
    precheck_fail "钥匙串里的 Sparkle 私钥和 $INFO_PLIST 的 SUPublicEDKey 不是一对（钥匙串：$KEYCHAIN_PUBKEY）"
fi

security find-identity -v -p codesigning | grep "Developer ID Application.*($TEAM_ID)" >/dev/null \
    || precheck_fail "钥匙串里没有 team $TEAM_ID 的 Developer ID Application 证书"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || precheck_fail "读不到 notarytool 配置 '$NOTARY_PROFILE'（见 docs/release.md），或用 NOTARY_PROFILE=<配置名> 指定"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || fail "要在 main 分支上发布（当前是 $BRANCH）"
if [[ -n "$NOTES_IN_REPO" ]]; then
    DIRTY="$(git status --porcelain -- . ":(exclude)$NOTES_IN_REPO")"
else
    DIRTY="$(git status --porcelain)"
fi
[[ -z "$DIRTY" ]] || fail "工作区有未提交的改动（发布日志除外），先提交或 stash：
$DIRTY"
git fetch --quiet origin main
git merge-base --is-ancestor origin/main HEAD || fail "本地 main 落后于 origin/main，先 git pull"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then fail "本地已有 tag $TAG"; fi
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then fail "origin 上已有 tag $TAG"; fi
if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then fail "GitHub 上已有 release $TAG"; fi

# ── 改版本号 ────────────────────────────────────────────────────────
read_setting() { grep -m1 "$1:" "$PROJECT_YML" | sed -E 's/.*"([^"]*)".*/\1/'; }
CURRENT_VERSION="$(read_setting MARKETING_VERSION)"
CURRENT_BUILD="$(read_setting CURRENT_PROJECT_VERSION)"
[[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || fail "$PROJECT_YML 里的 CURRENT_PROJECT_VERSION 格式不对: $CURRENT_BUILD"
NEXT_BUILD=$((CURRENT_BUILD + 1))
MIN_SYSTEM="$(read_setting MACOSX_DEPLOYMENT_TARGET)"
echo "==> 版本号 $CURRENT_VERSION (build $CURRENT_BUILD) → $VERSION (build $NEXT_BUILD)"

STAGE=bumped
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/" "$PROJECT_YML"
sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$NEXT_BUILD\"/" "$PROJECT_YML"
xcodegen >/dev/null

echo "==> 跑测试（$DERIVED_DATA）"
TEST_LOG="$(mktemp -t grapherng-release-test)"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug -derivedDataPath "$DERIVED_DATA" \
        -disableAutomaticPackageResolution test >"$TEST_LOG" 2>&1; then
    grep -E "error:|failed \(" "$TEST_LOG" | head -20 >&2 || true
    fail "测试没通过，完整日志：$TEST_LOG"
fi
echo "    $(grep -E "Executed [0-9]+ tests" "$TEST_LOG" | tail -1 | sed -E 's/^[[:space:]]+//')"

if [[ "$DRY_RUN" == true ]]; then
    echo "==> [dry-run] 检查和测试都通过，到此为止（不提交、不打包、不推送、不发布）"
    exit 0
fi

echo "==> 提交版本号"
git add "$PROJECT_YML"
if [[ -n "$NOTES_IN_REPO" ]]; then git add "$NOTES_IN_REPO"; fi
git commit -q -m "release: $TAG (build $NEXT_BUILD)"
STAGE=committed

# ── 签名、公证、打包 ────────────────────────────────────────────────
TEAM_ID="$TEAM_ID" NOTARY_PROFILE="$NOTARY_PROFILE" scripts/package.sh
[[ -f "$ZIP" && -f "$DMG" ]] || fail "scripts/package.sh 没有生成 $ZIP / $DMG"

# ── Sparkle：签 zip + 更新 appcast.xml ──────────────────────────────
echo "==> 用 Sparkle EdDSA 私钥签名 zip"
SIGN_LINE="$("$SPARKLE_BIN_DIR/sign_update" "$ZIP")"
ED_SIG="$(echo "$SIGN_LINE" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
ASSET_LEN="$(echo "$SIGN_LINE" | sed -E 's/.*length="([^"]+)".*/\1/')"
if [[ -z "$ED_SIG" || -z "$ASSET_LEN" || "$ED_SIG" == "$SIGN_LINE" ]]; then
    fail "解析不了 sign_update 的输出: $SIGN_LINE"
fi
echo "    edSignature ${ED_SIG:0:24}…  length $ASSET_LEN"

DOWNLOAD_URL="https://github.com/$GH_REPO/releases/download/$TAG/$(basename "$ZIP")"
RELEASE_LINK="https://github.com/$GH_REPO/releases/tag/$TAG"

echo "==> 更新 $APPCAST"
python3 - "$APPCAST" "$TAG" "$VERSION" "$NEXT_BUILD" "$MIN_SYSTEM" "$ED_SIG" "$ASSET_LEN" \
    "$DOWNLOAD_URL" "$RELEASE_LINK" "$NOTES_FILE" "$APPCAST_MARKER" <<'PYEOF'
import sys, html, re
from datetime import datetime, timezone

(appcast, tag, short_ver, build, min_system, ed_sig, length,
 dl_url, release_link, notes_file, marker) = sys.argv[1:]

pub_date = datetime.now(timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')

# 极简 Markdown → HTML（标题、列表、**粗体**、*斜体*、`代码`、裸链接）。先转义再替换，
# 免得日志里的 "<empty>" 这类文字被当成标签吞掉。
def md_to_html(md):
    def inline(s):
        s = html.escape(s, quote=False)
        s = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', s)
        s = re.sub(r'\*([^*\n]+?)\*', r'<em>\1</em>', s)
        s = re.sub(r'`(.+?)`', r'<code>\1</code>', s)
        s = re.sub(r'(https?://[^\s<]+)', r'<a href="\1">\1</a>', s)
        return s
    out, in_list = [], False
    def close_list():
        nonlocal in_list
        if in_list:
            out.append('</ul>')
            in_list = False
    for raw in md.splitlines():
        line = raw.rstrip()
        heading = re.match(r'^(#{1,6})\s+(.*)$', line)
        bullet = re.match(r'^[-*]\s+(.*)$', line)
        if bullet:
            if not in_list:
                out.append('<ul>')
                in_list = True
            out.append(f'<li>{inline(bullet.group(1))}</li>')
        elif heading:
            close_list()
            level = min(len(heading.group(1)) + 1, 6)   # 顶层 # 在更新窗口里太大，降一级
            out.append(f'<h{level}>{inline(heading.group(2))}</h{level}>')
        elif line and not line.lstrip().startswith('<!--'):
            close_list()
            out.append(f'<p>{inline(line)}</p>')
        else:
            close_list()
    close_list()
    return '\n'.join(out)

# 按 "<!-- lang:xx -->" 拆成多语言段落，每段一个 <description xml:lang="xx">；没有标记就整份一段
def split_langs(md):
    parts = re.split(r'(?im)^[ \t]*<!--[ \t]*lang:([a-z]{2})[ \t]*-->[ \t]*$', md)
    if len(parts) == 1:
        return [(None, md)]
    it = iter(parts[1:])
    return [(lang.lower(), chunk) for lang, chunk in zip(it, it) if chunk.strip()]

FOOTER = {'en': 'View the release on GitHub →', 'zh': '在 GitHub 上查看这次发布 →'}

def description(lang, chunk):
    body = md_to_html(chunk)
    body += f'\n<p><a href="{html.escape(release_link)}">{FOOTER.get(lang or "en", FOOTER["en"])}</a></p>'
    body = body.replace(']]>', ']]&gt;')   # CDATA 里不能出现 ]]>
    lang_attr = f' xml:lang="{lang}"' if lang else ''
    return f"      <description{lang_attr}><![CDATA[\n{body}\n      ]]></description>\n"

with open(notes_file, encoding='utf-8') as f:
    descriptions = ''.join(description(l, c) for l, c in split_langs(f.read()))

item = (
    "    <item>\n"
    f"      <title>{tag}</title>\n"
    f"      <pubDate>{pub_date}</pubDate>\n"
    f"      <sparkle:version>{build}</sparkle:version>\n"
    f"      <sparkle:shortVersionString>{short_ver}</sparkle:shortVersionString>\n"
    f"      <sparkle:minimumSystemVersion>{min_system}</sparkle:minimumSystemVersion>\n"
    f"{descriptions}"
    f"      <enclosure url=\"{dl_url}\" length=\"{length}\" "
    f"type=\"application/octet-stream\" sparkle:edSignature=\"{ed_sig}\" />\n"
    "    </item>\n"
)

with open(appcast, encoding='utf-8') as f:
    src = f.read()
line = marker + "\n"
if line not in src:
    sys.exit(f"ERROR: {appcast} 里找不到标记行，拒绝写入")
with open(appcast, 'w', encoding='utf-8') as f:
    f.write(src.replace(line, line + item, 1))
PYEOF

# 回读刚写进去的签名，确认无误再往下走
APPCAST_SIG="$(grep -m1 "sparkle:edSignature=" "$APPCAST" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
[[ "$APPCAST_SIG" == "$ED_SIG" ]] || fail "$APPCAST 顶部的签名和刚生成的对不上，拒绝继续"

# ── tag → 推送 → GitHub release ─────────────────────────────────────
echo "==> 打 tag $TAG"
git tag -a "$TAG" -m "$TITLE"
STAGE=tagged

echo "==> 推送 main 和 $TAG"
git push --atomic origin main "refs/tags/$TAG"
STAGE=pushed

echo "==> 创建 GitHub release 并上传 zip + dmg"
gh release create "$TAG" --repo "$GH_REPO" --verify-tag --title "$TITLE" --notes-file "$NOTES_FILE" "$ZIP" "$DMG"
STAGE=released

# 这时 zip 已经能从 GitHub 下载，appcast 里的链接才有效，最后再推 appcast
echo "==> 推送 $APPCAST"
git add "$APPCAST"
git commit -q -m "appcast: $TAG"
git push origin main
STAGE=""

echo ""
echo "================================================================"
echo "已发布 $TAG"
echo "  zip ：$ZIP ($(du -h "$ZIP" | cut -f1))"
echo "  dmg ：$DMG ($(du -h "$DMG" | cut -f1))"
echo "  页面：$RELEASE_LINK"
echo "  已安装的用户下次自动检查（每天一次）或手动「检查更新…」时会看到这个版本"
echo "================================================================"
