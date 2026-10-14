import AppKit
import GrapherKit

/// 欢迎窗口（照 FreeMind 的做，界面改用 AppKit）：启动时没有要打开的文档就显示，左边是新建 / 打开 / 示例，
/// 右边是最近打开的文档。任何文档的窗口一显示就把它关掉（`GraphDocument.showWindows`）。
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: WelcomeWindowController?
    private static let showsOnLaunchKey = "showWelcomeOnLaunch"
    private static let size = NSSize(width: 800, height: 500)

    /// 启动时是否显示欢迎窗口；关掉的话启动直接新建一份空白平面图。
    static var showsOnLaunch: Bool {
        get { UserDefaults.standard.object(forKey: showsOnLaunchKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showsOnLaunchKey) }
    }

    static func show() {
        if shared == nil { shared = WelcomeWindowController() }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    static func close() {
        shared?.window?.close()
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L("Welcome to Grapher NG")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        window.contentViewController = WelcomeViewController(size: Self.size)
        window.setContentSize(Self.size)
        window.center()
        window.initialFirstResponder = window.contentView
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WelcomeWindowController is created in code only")
    }

    func windowWillClose(_ notification: Notification) {
        // 下次显示时重新读最近列表。
        DispatchQueue.main.async { Self.shared = nil }
    }
}

/// 欢迎窗口的内容：左栏 340 点宽（图标、名称、版本、四个大按钮、「启动时显示」），右栏是最近文档。
/// 内容一直铺到透明标题栏底下。
@MainActor
private final class WelcomeViewController: NSViewController {
    private let size: NSSize
    private let recentStack = NSStackView()
    private let recentScroll = NSScrollView()
    private let emptyRecents = NSStackView()

    init(size: NSSize) {
        self.size = size
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WelcomeViewController is created in code only")
    }

    override func loadView() {
        let root = FocusAnchorView(frame: NSRect(origin: .zero, size: size))
        let left = makeActionsPane()
        let divider = NSBox()
        divider.boxType = .separator
        let right = makeRecentsPane()
        for pane in [left, divider, right] {
            pane.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(pane)
        }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: size.width),
            root.heightAnchor.constraint(equalToConstant: size.height),
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            left.topAnchor.constraint(equalTo: root.topAnchor),
            left.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: 340),
            divider.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            right.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            right.topAnchor.constraint(equalTo: root.topAnchor),
            right.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        reloadRecents()
    }

    // MARK: - 左栏

    private func makeActionsPane() -> NSView {
        let pane = NSView()

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: "Grapher NG")
        name.font = .systemFont(ofSize: 30, weight: .bold)
        let versionNumber = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let version = NSTextField(labelWithString: String(format: L("Version %@"), versionNumber))
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor

        let newPlane = WelcomeActionView(symbol: "plus.square", title: L("New 2D Graph"),
                                         detail: L("Curves, polar plots and regions"))
        newPlane.onClick = { NSDocumentController.shared.newDocument(nil) }
        let newSpace = WelcomeActionView(symbol: "cube", title: L("New 3D Graph"),
                                         detail: L("Surfaces and space curves"))
        newSpace.onClick = { GraphDocumentController.graphShared?.newDocument(dimension: .space) }
        let open = WelcomeActionView(symbol: "folder", title: L("Open…"),
                                     detail: L("Open a saved graph"))
        open.onClick = { NSDocumentController.shared.openDocument(nil) }
        let examples = WelcomeActionView(symbol: "sparkles", title: L("Examples"),
                                         detail: L("A ready-made 2D or 3D graph"))
        examples.onClick = { [weak self, weak examples] in
            guard let self, let examples else { return }
            // 卡片不是翻转坐标，y = -4 是卡片下沿再往下一点：菜单从卡片底下弹出，不盖住卡片。
            self.examplesMenu().popUp(positioning: nil, at: NSPoint(x: 12, y: -4), in: examples)
        }
        let actions = NSStackView(views: [newPlane, newSpace, open, examples])
        actions.orientation = .vertical
        actions.spacing = 6
        for action in actions.arrangedSubviews {
            action.widthAnchor.constraint(equalTo: actions.widthAnchor).isActive = true
        }

        let showOnLaunch = NSButton(checkboxWithTitle: L("Show this window when Grapher NG starts"),
                                    target: self, action: #selector(toggleShowOnLaunch(_:)))
        showOnLaunch.controlSize = .small
        showOnLaunch.state = WelcomeWindowController.showsOnLaunch ? .on : .off
        showOnLaunch.attributedTitle = NSAttributedString(string: showOnLaunch.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])

        for view in [icon, name, version, actions, showOnLaunch] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: pane.topAnchor, constant: 38),
            icon.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            name.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 6),
            name.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            version.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            version.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            actions.topAnchor.constraint(equalTo: version.bottomAnchor, constant: 24),
            actions.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 24),
            actions.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -24),
            showOnLaunch.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -18),
            showOnLaunch.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
        ])
        return pane
    }

    /// 「示例」点开的菜单：平面图示例 / 立体图示例，各开一扇新窗口。
    private func examplesMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: L("2D Example"), action: #selector(openPlaneExample(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("3D Example"), action: #selector(openSpaceExample(_:)), keyEquivalent: "").target = self
        return menu
    }

    @objc private func openPlaneExample(_ sender: Any?) {
        GraphDocumentController.graphShared?.newDocument(dimension: .plane, example: true)
    }

    @objc private func openSpaceExample(_ sender: Any?) {
        GraphDocumentController.graphShared?.newDocument(dimension: .space, example: true)
    }

    @objc private func toggleShowOnLaunch(_ sender: NSButton) {
        WelcomeWindowController.showsOnLaunch = sender.state == .on
    }

    // MARK: - 右栏

    private func makeRecentsPane() -> NSView {
        let pane = TintedPaneView()

        let title = NSTextField(labelWithString: L("Recent Graphs"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 2
        recentStack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(recentStack)
        recentScroll.documentView = document
        recentScroll.drawsBackground = false
        recentScroll.hasVerticalScroller = true
        recentScroll.autohidesScrollers = true
        NSLayoutConstraint.activate([
            recentStack.topAnchor.constraint(equalTo: document.topAnchor),
            recentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 10),
            recentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -10),
            recentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12),
            document.widthAnchor.constraint(equalTo: recentScroll.contentView.widthAnchor),
        ])

        let clock = NSImageView()
        clock.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 30, weight: .regular))
        clock.contentTintColor = .tertiaryLabelColor
        let none = NSTextField(labelWithString: L("No recent graphs"))
        none.textColor = .secondaryLabelColor
        let hint = NSTextField(labelWithString: L("Graphs you open will appear here."))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        emptyRecents.setViews([clock, none, hint], in: .center)
        emptyRecents.orientation = .vertical
        emptyRecents.spacing = 8

        for view in [title, recentScroll, emptyRecents] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: pane.topAnchor, constant: 36),
            title.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            recentScroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            recentScroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            recentScroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            recentScroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            emptyRecents.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            emptyRecents.centerYAnchor.constraint(equalTo: pane.centerYAnchor, constant: -20),
        ])
        return pane
    }

    private func reloadRecents() {
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let urls = RecentGraphs.urls
        for url in urls {
            let row = RecentGraphRow(url: url)
            row.onClick = { RecentGraphs.open(url) }
            row.onRemove = { [weak self] in
                RecentGraphs.remove(url)
                self?.reloadRecents()
            }
            row.onClearAll = { [weak self] in
                RecentGraphs.clear()
                self?.reloadRecents()
            }
            recentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: recentStack.widthAnchor).isActive = true
        }
        recentScroll.isHidden = urls.isEmpty
        emptyRecents.isHidden = !urls.isEmpty
    }
}
