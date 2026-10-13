import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [DocumentWindowController] = []

    /// 以测试宿主身份启动时（`GrapherNGTests` 的 `TEST_HOST`）不建窗口、不抢焦点，
    /// 免得跑测试时弹出界面打断正在用的实例。
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
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
        newWindow()
        NSApp.activate()
    }

    /// 用户又打开了一次 GrapherNG（那个进程抢不到单实例锁，已经退出）：调到前面；
    /// 没有窗口时新建一个。
    @objc private func handleSecondLaunch(_ note: Notification) {
        NSApp.unhide(nil)
        NSApp.activate()
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            newWindow()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Documents

    @discardableResult
    private func newWindow() -> DocumentWindowController {
        let controller = DocumentWindowController()
        controller.onClose = { [weak self] closed in
            self?.windowControllers.removeAll { $0 === closed }
        }
        windowControllers.append(controller)
        controller.showWindow(nil)
        return controller
    }

    /// The window that menu commands without an explicit target apply to.
    private var activeController: DocumentWindowController? {
        if let controller = NSApp.keyWindow?.windowController as? DocumentWindowController {
            return controller
        }
        if let controller = NSApp.mainWindow?.windowController as? DocumentWindowController {
            return controller
        }
        return windowControllers.last
    }

    @objc func openDocument(_ sender: Any?) {
        guard let controller = activeController else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "打开图形文档"
        panel.beginSheetModal(for: controller.window!) { response in
            guard response == .OK, let url = panel.url else { return }
            controller.state.open(url: url)
        }
    }

    @objc func newDocumentFromMenu(_ sender: Any?) {
        newWindow()
    }
}
