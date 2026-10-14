import AppKit
import Sparkle

/// Sparkle 2 自动更新（同 FreeMind / Perch / UniReader）。拉 appcast、EdDSA 校验、下载、安装、重启全交给
/// `SPUStandardUpdaterController`，界面是 Sparkle 自带的标准窗口：后台每天静默检查一次，真有新版本才弹窗。
/// 更新源与公钥在 project.yml（`SUFeedURL`、`SUPublicEDKey`），发布流程见 docs/release.md。
@MainActor
enum UpdaterService {
    /// 菜单「检查更新…」直接以它为 target（它自己按能否检查启用 / 禁用菜单项）。
    /// 建菜单时就会创建；单元测试以 App 为宿主运行时不启动更新检查。
    static let controller = SPUStandardUpdaterController(
        startingUpdater: !AppDelegate.isRunningTests,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
}
