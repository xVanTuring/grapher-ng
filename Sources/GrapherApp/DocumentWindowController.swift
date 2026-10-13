import AppKit
import GrapherKit
import UniformTypeIdentifiers

extension NSToolbarItem.Identifier {
    static let fitContent = NSToolbarItem.Identifier("GrapherNG.fitContent")
    static let resetView = NSToolbarItem.Identifier("GrapherNG.resetView")
    static let zoomGroup = NSToolbarItem.Identifier("GrapherNG.zoomGroup")
    static let zoomIn = NSToolbarItem.Identifier("GrapherNG.zoomIn")
    static let zoomOut = NSToolbarItem.Identifier("GrapherNG.zoomOut")
    static let export = NSToolbarItem.Identifier("GrapherNG.export")
    static let toggleInspector = NSToolbarItem.Identifier("GrapherNG.toggleInspector")
}

/// One document window: the split view, the toolbar, the undo stack, and every
/// menu action that operates on a document.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {

    let state: AppState
    var onClose: ((DocumentWindowController) -> Void)?

    private let undo = UndoManager()
    private let splitViewController = NSSplitViewController()
    private let sidebarViewController: SidebarViewController
    private let viewportViewController: ViewportViewController
    private let inspectorViewController: InspectorViewController
    private var inspectorItem: NSSplitViewItem?

    init(state: AppState? = nil) {
        let state = state ?? AppState()
        self.state = state
        self.sidebarViewController = SidebarViewController(state: state)
        self.viewportViewController = ViewportViewController(state: state)
        self.inspectorViewController = InspectorViewController(state: state)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
            // `.fullSizeContentView` 不能省：没有它内容区从标题栏下方才开始，画布与侧栏
            // 都被切在标题栏之下。现代侧栏（Finder/Mail 那样一路延伸到顶、工具栏浮在
            // 它上面）要三件齐备：这条 styleMask、`NSSplitViewItem(sidebarWithViewController:)`
            // （见 buildSplitView）、以及工具栏里的 `.sidebarTrackingSeparator`。
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Grapher NG"
        window.minSize = NSSize(width: 920, height: 600)
        window.tabbingMode = .disallowed
        // 窗口位置由下面的 frame autosave 管，系统的状态恢复不再插手一遍。
        window.isRestorable = false
        super.init(window: window)

        window.delegate = self
        window.setFrameAutosaveName("GrapherNGMainWindow")
        // 默认 true，`showWindow` 时会覆盖掉刚恢复的位置（AppKit 文档原话：设了 frame
        // 记忆就该把它关掉）。
        shouldCascadeWindows = false
        window.center()
        state.undoManager = undo

        buildSplitView()
        buildToolbar()
        updateTitle()
        state.observe { [weak self] change in
            guard let self else { return }
            switch change {
            case .document, .layers, .status:
                self.updateTitle()
            default:
                break
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DocumentWindowController is created in code only")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        state.requestRebuild(interactive: false)
    }

    // MARK: - Layout

    private func buildSplitView() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 380
        sidebarItem.canCollapse = true

        let canvasItem = NSSplitViewItem(viewController: viewportViewController)
        canvasItem.minimumThickness = 360
        // 沉浸式画布（UniReader 阅读区同款）：画布这一格伸到左侧毛玻璃侧栏底下，透过侧栏
        // 能看到曲线；被盖住的宽度以 `safeAreaInsets` 交给画布，视口中心落在没被盖住那块的
        // 中心，所以侧栏一开内容被推开、一收又回来。没有这一行，画布从侧栏右边才开始，
        // 侧栏底下只有窗口底色。检查器是普通分栏项，不受影响，仍然真的占宽度。
        if #available(macOS 26.0, *) {
            canvasItem.automaticallyAdjustsSafeAreaInsets = true
        }

        let inspectorItem = NSSplitViewItem(viewController: inspectorViewController)
        inspectorItem.minimumThickness = 286
        inspectorItem.maximumThickness = 460
        inspectorItem.canCollapse = true
        self.inspectorItem = inspectorItem

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(canvasItem)
        splitViewController.addSplitViewItem(inspectorItem)
        splitViewController.splitView.autosaveName = "GrapherNGSplit"
        window?.contentViewController = splitViewController
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "GrapherNGToolbar.v3")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    /// Symbols have to be given an explicit point size. Without one, AppKit
    /// renders the symbol at its natural size (often 24pt or more), which is
    /// noticeably larger than the 15pt the rest of the toolbar is built around.
    private func symbolImage(_ name: String, _ description: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
    }

    private func toolbarButton(
        _ identifier: NSToolbarItem.Identifier,
        symbol: String,
        label: String,
        tooltip: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = symbolImage(symbol, label)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tooltip
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    private func updateTitle() {
        let name = state.documentURL?.deletingPathExtension().lastPathComponent
        window?.title = name.map { "Grapher NG — \($0)" } ?? "Grapher NG"
        // Gives the title bar its proxy icon and ⌘-click path menu, and lights
        // up the dot in the close button when there are unsaved edits.
        window?.representedURL = state.documentURL
        window?.isDocumentEdited = state.isDocumentEdited
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // `.sidebarTrackingSeparator` is load-bearing: without it the sidebar
        // toggle is treated as an ordinary item and drifts over to the right
        // instead of sitting over the sidebar.
        //
        // `.inspectorTrackingSeparator` is deliberately NOT used. It carves the
        // inspector's width out of the toolbar and hands it to the inspector
        // region; with only a single small toggle living there the right-hand
        // third of the toolbar reads as empty and everything else gets squeezed
        // into the left. That separator earns its keep in FreeMind / UniReader
        // because they have a flexible-width item (a search field) that would
        // otherwise spread across the inspector — this toolbar has none.
        //
        // Consecutive icon items merge into one glass capsule, so grouping is
        // expressed purely by where the spaces fall:
        //   ◧ │ …… │ 适应内容 重置 │ 缩放 │ 导出 │ 检查器
        [.toggleSidebar, .sidebarTrackingSeparator,
         .fitContent, .resetView, .zoomGroup,
         .flexibleSpace, .export, .space, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator,
         .fitContent, .resetView, .zoomGroup,
         .export, .toggleInspector,
         .flexibleSpace, .space]
    }

    /// The inspector toggle is the only way into that pane, so it must not be
    /// draggable out of the toolbar.
    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        [.toggleInspector]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .fitContent:
            return toolbarButton(
                identifier,
                symbol: "arrow.up.left.and.arrow.down.right",
                label: "适应内容",
                tooltip: "缩放到刚好装下所有曲线（F）",
                action: #selector(fitToContent(_:))
            )
        case .resetView:
            return toolbarButton(
                identifier,
                symbol: "scope",
                label: "重置",
                tooltip: "回到原点、默认缩放（R）",
                action: #selector(resetView(_:))
            )
        case .zoomGroup:
            // A pair of related controls belongs in a group; that is what gives
            // it the shared bezel macOS uses for things like find or zoom.
            let group = NSToolbarItemGroup(itemIdentifier: identifier)
            group.controlRepresentation = .expanded
            group.selectionMode = .momentary
            group.label = "缩放"
            group.paletteLabel = "缩放"
            group.subitems = [
                toolbarButton(
                    .zoomOut,
                    symbol: "minus.magnifyingglass",
                    label: "缩小",
                    tooltip: "缩小（⌘-）",
                    action: #selector(zoomOut(_:))
                ),
                toolbarButton(
                    .zoomIn,
                    symbol: "plus.magnifyingglass",
                    label: "放大",
                    tooltip: "放大（⌘=）",
                    action: #selector(zoomIn(_:))
                ),
            ]
            return group
        case .export:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = symbolImage("square.and.arrow.up", "导出")
            item.label = "导出"
            item.paletteLabel = "导出"
            item.toolTip = "导出 PNG / 矢量 PDF / 采样点 CSV"
            item.showsIndicator = false
            item.isBordered = true
            item.menu = exportMenu()
            return item
        case .toggleInspector:
            let item = toolbarButton(
                identifier,
                symbol: "sidebar.right",
                label: "检查器",
                tooltip: "显示/隐藏检查器（⌥⌘I）",
                action: #selector(toggleInspector(_:))
            )
            return item
        default:
            return nil
        }
    }

    private func exportMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "PNG 1×", action: #selector(exportPNG1x(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "PNG 2×", action: #selector(exportPNG2x(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "PNG 4×", action: #selector(exportPNG4x(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "矢量 PDF…", action: #selector(exportPDFAction(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "采样点 CSV…", action: #selector(exportCSVAction(_:)), keyEquivalent: "").target = self
        return menu
    }

    // MARK: - File actions

    @objc func newDocument(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.newDocumentFromMenu(sender)
    }

    @objc func openDocumentAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "打开图形文档"
        present(panel) { [weak self] url in
            self?.state.open(url: url)
        }
    }

    @objc func saveDocumentAction(_ sender: Any?) {
        if let url = state.documentURL {
            state.save(to: url)
            updateTitle()
        } else {
            saveDocumentAsAction(sender)
        }
    }

    @objc func saveDocumentAsAction(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = (state.documentURL?.lastPathComponent) ?? "graph.grapher.json"
        panel.title = "保存图形文档"
        present(panel) { [weak self] url in
            self?.state.save(to: url)
            self?.updateTitle()
        }
    }

    @objc func exportPNG1x(_ sender: Any?) { Exporter.exportPNG(state: state, scale: 1, window: window) }
    @objc func exportPNG2x(_ sender: Any?) { Exporter.exportPNG(state: state, scale: 2, window: window) }
    @objc func exportPNG4x(_ sender: Any?) { Exporter.exportPNG(state: state, scale: 4, window: window) }
    @objc func exportPDFAction(_ sender: Any?) { Exporter.exportPDF(state: state, window: window) }
    @objc func exportCSVAction(_ sender: Any?) { Exporter.exportCSV(state: state, window: window) }

    private func present(_ panel: NSSavePanel, then handle: @escaping (URL) -> Void) {
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            handle(url)
        }
    }

    private func present(_ panel: NSOpenPanel, then handle: @escaping (URL) -> Void) {
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            handle(url)
        }
    }

    // MARK: - View actions

    @objc func fitToContent(_ sender: Any?) { state.fitToContent() }
    @objc func resetView(_ sender: Any?) { state.resetView() }
    @objc func zoomIn(_ sender: Any?) { state.zoom(by: 1.25) }
    @objc func zoomOut(_ sender: Any?) { state.zoom(by: 0.8) }

    @objc func toggleInspector(_ sender: Any?) {
        inspectorItem?.animator().isCollapsed.toggle()
    }

    // MARK: - Window delegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        undo
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}
