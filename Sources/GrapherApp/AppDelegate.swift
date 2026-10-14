import AppKit
import GrapherKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 以测试宿主身份启动时（`GrapherNGTests` 的 `TEST_HOST`）不建窗口、不抢焦点，
    /// 免得跑测试时弹出界面打断正在用的实例。
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 第一个建出来的 NSDocumentController 就是 `shared`，必须赶在 AppKit 自己建默认的那个之前。
        _ = GraphDocumentController()
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSecondLaunch(_:)),
            name: SingleInstanceLock.secondLaunchNotification,
            object: nil
        )
        NSApp.activate()
    }

    /// 启动时没有要打开的文件，AppKit 会自己开一份未命名的空白平面图；测试宿主里不开。
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !Self.isRunningTests
    }

    /// 用户又打开了一次 GrapherNG（那个进程抢不到单实例锁，已经退出）：调到前面；
    /// 没有窗口时新建一个。
    @objc private func handleSecondLaunch(_ note: Notification) {
        NSApp.unhide(nil)
        NSApp.activate()
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            NSDocumentController.shared.newDocument(nil)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Documents

    /// 新建立体图：开一扇新窗口，装着空白的立体图。
    @objc func newSpaceDocument(_ sender: Any?) {
        (NSDocumentController.shared as? GraphDocumentController)?.newDocument(dimension: .space)
    }
}
