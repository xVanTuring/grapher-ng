# 发布与自动更新

Grapher NG 用 Developer ID 签名、经过 Apple 公证，在 GitHub release 上提供 `.dmg`（手动下载）和 `.zip`（自动更新），
已安装的用户通过 [Sparkle 2](https://sparkle-project.org) 收到更新。流程与 FreeMind / Perch / UniReader 相同。

| 脚本 | 作用 | 会不会公开发布 |
|---|---|---|
| `scripts/package.sh` | archive → Developer ID 签名 → 校验签名 → 公证、装订 → `build/dist/GrapherNG-<版本>.zip` / `.dmg` | 不会，只在本机生成文件 |
| `scripts/package.sh --no-notarize` | 同上但不公证，用来验证签名流程（文件名带 `-unnotarized`，别发给别人） | 不会 |
| `scripts/release.sh <版本> --notes-file <日志>` | 改版本号 → 跑测试 → 提交 → `package.sh` → Sparkle 签名 → 更新 `appcast.xml` → 打 tag → 推送 → GitHub release | **会**：推送到 GitHub 并推送更新给所有用户 |
| `scripts/release.sh … --dry-run` | 只做检查、改版本号、跑测试，然后还原 | 不会 |

## 自动更新怎么工作

- App 里：`Sources/GrapherApp/UpdaterService.swift` 用 `SPUStandardUpdaterController` 跑整个流程，界面是 Sparkle
  自带的标准窗口。菜单「Grapher NG ▸ 检查更新…」手动检查。默认每天自动检查一次
  （`SUEnableAutomaticChecks`、`SUScheduledCheckInterval`），不会在第二次启动时弹窗询问。
- 更新源：`project.yml` 里的 `SUFeedURL` 指向仓库 main 分支的 `appcast.xml`
  （`https://raw.githubusercontent.com/xVanTuring/grapher-ng/main/appcast.xml`），所以仓库必须保持公开。
- 校验：每个更新包都用 EdDSA 私钥签名，App 用 `SUPublicEDKey` 公钥验证，对不上的更新一律拒绝安装。
  公钥和 FreeMind、Perch、UniReader 是同一个（私钥在发布机登录钥匙串的 `https://sparkle-project.org` 项里）。
- App 没有开沙盒，所以不需要 Sparkle 的 Installer XPC 服务和额外的 entitlements。
  （两个 Quick Look 扩展开了沙盒，但它们不链接 Sparkle。）
- 单元测试里不启动更新检查（`AppDelegate.isRunningTests`）。
- Sparkle 是本工程唯一的第三方包，只链接到 App target；GrapherKit、GrapherRender 和 Quick Look 扩展都不引用它。

> ⚠️ **第一次发布之后严禁更换 `SUPublicEDKey`**：已安装的版本只认这把公钥，换了之后它们会拒绝以后所有的更新，
> 用户只能手动重新下载安装。私钥务必备份（见下面第 4 步）。

## 签名

- `project.yml` 里 Debug 与发布用同一个证书（zqsd 的 Developer ID Application，公司只有它能公证；不用 ad-hoc：签名每次都变，Keychain 会反复弹授权窗）；
  换机器 / 别的开发者要把 `CODE_SIGN_IDENTITY` 改成自己的开发证书。Release 在工程里是 ad-hoc，发布时由 `package.sh` 指定身份。
- `package.sh` 在命令行指定签名身份：`CODE_SIGN_IDENTITY` 取钥匙串里 team `T8F5T6HKG8` 的
  「Developer ID Application」证书全名（本机还有别的团队的 Developer ID 证书，不能只写类型名），加 `--timestamp`。
  Hardened Runtime 在 `project.yml` 里一直开着。
- 导出用 `scripts/ExportOptions.plist`（`developer-id`、manual）。没有 iCloud、推送这类受限能力，
  不需要 Developer ID 描述文件。
- 打包后逐个检查 App、两个 Quick Look 扩展、GrapherKit / GrapherRender / Sparkle 三个框架：必须是本团队的
  Developer ID、开了 hardened runtime、带时间戳、没有 `get-task-allow`，任何一项不对就停下，不会去提交公证。
- dmg 也签名、公证、装订，双击打开不会被 Gatekeeper 拦。

## 一次性准备（每台发布用的电脑做一次）

1. **Developer ID Application 证书**（team `T8F5T6HKG8`）在登录钥匙串里：
   Xcode › 设置 › 帐户 › 管理证书 › **+** › Developer ID Application。
2. **notarytool 配置**，默认名 `noticky-notary`（和其他 App 共用，是帐户级的，不分 App）：
   ```sh
   xcrun notarytool store-credentials noticky-notary --apple-id "<Apple ID>" --team-id T8F5T6HKG8
   ```
   会提示输入 App 专用密码（在 <https://appleid.apple.com> › 登录与安全 › App 专用密码生成）。
   名字不同就在运行脚本时加 `NOTARY_PROFILE=<配置名>`。
3. **gh 已登录**：`gh auth status`。
4. **Sparkle 私钥**在登录钥匙串里（和 FreeMind 等共用，本机已有）。换电脑时从备份导入：
   ```sh
   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/sparkle-private-key   # 在旧电脑导出备份
   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -f ~/sparkle-private-key   # 在新电脑导入
   ```
   `release.sh` 会检查钥匙串里的私钥和 `SUPublicEDKey` 是不是一对。第一次在本工程里运行时，系统可能弹窗问
   `generate_keys` / `sign_update` 能不能读这个钥匙串项，选「始终允许」。
5. **SPM 包已解析**（Sparkle 和它的 `sign_update`、`generate_keys` 工具）：
   ```sh
   xcodegen && xcodebuild -project GrapherNG.xcodeproj -scheme GrapherNG -derivedDataPath build/DerivedData -resolvePackageDependencies
   ```
   打包和发布时都加了 `-disableAutomaticPackageResolution`，不会现场联网拉包。

## 发布步骤

1. 写发布日志，比如 `release-notes/v1.0.1.md`。中英双语时用标记分段，Sparkle 的更新窗口会按用户的系统语言只显示一段；
   GitHub release 正文用同一个文件（标记是 HTML 注释，看不见）：
   ```markdown
   <!-- lang:zh -->
   ## 新功能
   - ……

   <!-- lang:en -->
   ## What's New
   - …
   ```
2. 先演练：`scripts/release.sh 1.0.1 --notes-file release-notes/v1.0.1.md --dry-run`
3. 正式发布：去掉 `--dry-run`。版本号写 `X.Y.Z`，构建号自动加一。
   日志文件在仓库里时会随版本号一起提交。
4. 中途失败时脚本会说明进行到哪一步、远端有没有变化、怎么撤销或补做。公证全部通过之后才会推送，
   所以签名或公证出问题时远端什么都没变。
5. 确认 GitHub 上的 release 建好、下载正常之后，删掉本地的发布包（`build/dist/` 与 `build/release/`），本地不留已发布的包。

发布之后用一台装了旧版本的电脑点「检查更新…」确认能收到并装上新版本。

## 版本号

`project.yml` 的 `MARKETING_VERSION`（显示版本）和 `CURRENT_PROJECT_VERSION`（构建号，Sparkle 用它比较新旧）
是唯一来源，App 和两个扩展的 Info.plist 都引用它们。不要手改 Info.plist 里的版本号。
