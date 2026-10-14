import AppKit
import GrapherKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 以测试宿主身份启动时（`GrapherNGTests` 的 `TEST_HOST`）不建窗口、不抢焦点，
    /// 免得跑测试时弹出界面打断正在用的实例。
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private var mcpServer: MCPServer?

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

        // MCP：工具表总是注册，是否真的监听端口由设置里的开关决定。
        let server = MCPServer(facade: MCPFacade())
        mcpServer = server
        MCPSettingsWindowController.shared.server = server
        if MCPSettings.isEnabled { server.start() }
    }

    /// 测试宿主里不开任何窗口。
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !Self.isRunningTests
    }

    /// 启动时没有文件要打开、或点 Dock 图标时一扇窗口都没有（同 FreeMind）：显示欢迎窗口；
    /// 用户在欢迎窗口里关掉了「启动时显示」的，直接新建一份空白平面图。
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if !NSDocumentController.shared.documents.isEmpty { return true }
        if WelcomeWindowController.showsOnLaunch {
            WelcomeWindowController.show()
        } else {
            NSDocumentController.shared.newDocument(nil)
        }
        return true
    }

    /// 用户又打开了一次 GrapherNG（那个进程抢不到单实例锁，已经退出）：调到前面；
    /// 没有窗口时和点 Dock 图标一样，显示欢迎窗口或新建文档。
    @objc private func handleSecondLaunch(_ note: Notification) {
        NSApp.unhide(nil)
        NSApp.activate()
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            _ = applicationOpenUntitledFile(NSApp)
        }
    }

    /// 右键 Dock 图标：新建平面图 / 立体图、打开（最近打开的文档由系统自动列在上面）。
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [
            (L("New 2D Graph"), #selector(newPlaneFromDock(_:))),
            (L("New 3D Graph"), #selector(newSpaceDocument(_:))),
            (L("Open…"), #selector(openFromDock(_:))),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func newPlaneFromDock(_ sender: Any?) {
        NSApp.activate()
        NSDocumentController.shared.newDocument(nil)
    }

    @objc private func openFromDock(_ sender: Any?) {
        NSApp.activate()
        NSDocumentController.shared.openDocument(nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Documents

    /// 新建立体图：开一扇新窗口，装着空白的立体图。
    @objc func newSpaceDocument(_ sender: Any?) {
        NSApp.activate()
        GraphDocumentController.graphShared?.newDocument(dimension: .space)
    }

    /// ⌘,：设置窗口（AI 接入）。
    @objc func showSettings(_ sender: Any?) {
        MCPSettingsWindowController.show()
    }

    /// ⇧⌘1：欢迎窗口（最近打开的文档）。
    @objc func showWelcome(_ sender: Any?) {
        WelcomeWindowController.show()
    }
}
