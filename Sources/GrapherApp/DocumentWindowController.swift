import AppKit
import GrapherKit

extension NSToolbarItem.Identifier {
    static let fitContent = NSToolbarItem.Identifier("GrapherNG.fitContent")
    static let resetView = NSToolbarItem.Identifier("GrapherNG.resetView")
    static let zoomGroup = NSToolbarItem.Identifier("GrapherNG.zoomGroup")
    static let zoomIn = NSToolbarItem.Identifier("GrapherNG.zoomIn")
    static let zoomOut = NSToolbarItem.Identifier("GrapherNG.zoomOut")
    static let export = NSToolbarItem.Identifier("GrapherNG.export")
    static let lesson = NSToolbarItem.Identifier("GrapherNG.lesson")
    static let toggleInspector = NSToolbarItem.Identifier("GrapherNG.toggleInspector")
}

/// One document window: the split view, the toolbar, and the menu actions that
/// operate on what the window shows. Opening, saving, the title and the
/// edited dot belong to the window's `GraphDocument`.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {

    let state: AppState

    private let splitViewController = NSSplitViewController()
    private let sidebarViewController: SidebarViewController
    private let canvasViewController: CanvasContainerViewController
    private let inspectorViewController: InspectorViewController
    private var inspectorItem: NSSplitViewItem?

    init(state: AppState) {
        self.state = state
        self.sidebarViewController = SidebarViewController(state: state)
        self.canvasViewController = CanvasContainerViewController(state: state)
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

        buildSplitView()
        buildToolbar()
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

        let canvasItem = NSSplitViewItem(viewController: canvasViewController)
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
        let toolbar = NSToolbar(identifier: "GrapherNGToolbar.v4")
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
        //   ◧ │ …… │ 适应内容 重置 │ 缩放 │ 讲解 │ 导出 │ 检查器
        [.toggleSidebar, .sidebarTrackingSeparator,
         .fitContent, .resetView, .zoomGroup,
         .flexibleSpace, .lesson, .space, .export, .space, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator,
         .fitContent, .resetView, .zoomGroup,
         .lesson, .export, .toggleInspector,
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
                label: L("Fit Content"),
                tooltip: L("Zoom to fit every curve (F)"),
                action: #selector(fitToContent(_:))
            )
        case .resetView:
            return toolbarButton(
                identifier,
                symbol: "scope",
                label: L("Reset"),
                tooltip: L("Back to the origin at the default zoom (R)"),
                action: #selector(resetView(_:))
            )
        case .zoomGroup:
            // A pair of related controls belongs in a group; that is what gives
            // it the shared bezel macOS uses for things like find or zoom.
            let group = NSToolbarItemGroup(itemIdentifier: identifier)
            group.controlRepresentation = .expanded
            group.selectionMode = .momentary
            group.label = L("Zoom")
            group.paletteLabel = L("Zoom")
            group.subitems = [
                toolbarButton(
                    .zoomOut,
                    symbol: "minus.magnifyingglass",
                    label: L("Zoom Out"),
                    tooltip: L("Zoom out (⌘-)"),
                    action: #selector(zoomOut(_:))
                ),
                toolbarButton(
                    .zoomIn,
                    symbol: "plus.magnifyingglass",
                    label: L("Zoom In"),
                    tooltip: L("Zoom in (⌘=)"),
                    action: #selector(zoomIn(_:))
                ),
            ]
            return group
        case .lesson:
            return toolbarButton(
                identifier,
                symbol: "graduationcap",
                label: L("Lesson"),
                tooltip: L("Step through the lesson; with no steps yet, make the first one from what is on screen (⌥⌘L)"),
                action: #selector(toggleLesson(_:))
            )
        case .export:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = symbolImage("square.and.arrow.up", L("Export"))
            item.label = L("Export")
            item.paletteLabel = L("Export")
            item.toolTip = L("Export PNG / vector PDF / sample points CSV")
            item.showsIndicator = false
            item.isBordered = true
            item.menu = exportMenu()
            return item
        case .toggleInspector:
            let item = toolbarButton(
                identifier,
                symbol: "sidebar.right",
                label: L("Inspector"),
                tooltip: L("Show/hide the inspector (⌥⌘I)"),
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
        menu.addItem(withTitle: L("Vector PDF…"), action: #selector(exportPDFAction(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Sample Points CSV…"), action: #selector(exportCSVAction(_:)), keyEquivalent: "").target = self
        return menu
    }

    // MARK: - File actions
    //
    // 新建、打开、保存、另存为走 NSDocumentController / NSDocument 自带的动作（见 MainMenu），这里没有。

    @objc func loadExample(_ sender: Any?) { state.loadExample() }

    @objc func exportPNG1x(_ sender: Any?) { Exporter.exportPNG(state: state, scale: 1, window: window) }
    @objc func exportPNG2x(_ sender: Any?) { Exporter.exportPNG(state: state, scale: 2, window: window) }
    @objc func exportPNG4x(_ sender: Any?) { Exporter.exportPNG(state: state, scale: 4, window: window) }
    @objc func exportPDFAction(_ sender: Any?) { Exporter.exportPDF(state: state, window: window) }
    @objc func exportCSVAction(_ sender: Any?) { Exporter.exportCSV(state: state, window: window) }

    // MARK: - View actions

    @objc func fitToContent(_ sender: Any?) { state.fitToContent() }
    @objc func resetView(_ sender: Any?) { state.resetView() }
    @objc func zoomIn(_ sender: Any?) { state.zoom(by: 1.25) }
    @objc func zoomOut(_ sender: Any?) { state.zoom(by: 0.8) }

    @objc func toggleInspector(_ sender: Any?) {
        inspectorItem?.animator().isCollapsed.toggle()
    }

    // MARK: - Lesson actions

    @objc func toggleLesson(_ sender: Any?) { state.toggleLesson() }
    @objc func nextLessonStep(_ sender: Any?) { state.nextStep() }
    @objc func previousLessonStep(_ sender: Any?) { state.previousStep() }
    @objc func addLessonStep(_ sender: Any?) { state.addLessonStep() }

    // MARK: - Menu validation

    /// 矢量 PDF 与采样点 CSV 只对平面图有意义，立体图先不给。
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleLesson(_:)):
            menuItem.title = state.lessonStep == nil ? L("Start Lesson") : L("End Lesson")
            return true
        case #selector(nextLessonStep(_:)):
            return state.lessonStep.map { $0 + 1 < state.document.lessonSteps.count } ?? false
        case #selector(previousLessonStep(_:)):
            return state.lessonStep.map { $0 > 0 } ?? false
        case #selector(exportPDFAction(_:)), #selector(exportCSVAction(_:)):
            return state.document.dimension == .plane
        default:
            return true
        }
    }

    // MARK: - Edited state

    /// 改过没存时，标题下面的子标题写「已编辑」，存过就清掉。系统只给「就地自动保存」的文档显示这个；
    /// 本 App 关了自动保存（关窗、退出要弹保存提示），所以自己写。NSDocument 改动计数一变就会调到这里。
    override func setDocumentEdited(_ dirtyFlag: Bool) {
        super.setDocumentEdited(dirtyFlag)
        let subtitle = dirtyFlag ? L("Edited") : ""
        if window?.subtitle != subtitle {
            window?.subtitle = subtitle
        }
    }

    // MARK: - Window delegate

    /// 文档自己的撤销栈（`GraphDocument` 交给了 `state`）。
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        state.undoManager
    }
}
