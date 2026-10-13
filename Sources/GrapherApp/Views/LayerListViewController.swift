import AppKit
import GrapherKit

private let layerRowDragType = NSPasteboard.PasteboardType("com.grapherng.layer-row")
private let layerRowViewIdentifier = NSUserInterfaceItemIdentifier("GrapherNG.layerRow")

/// The left column's upper half: one row per layer, reorderable by dragging.
/// 新建 / 删除放在「图层」标题行右侧，与下方「参数 ＋」同一个样式。
final class LayerListViewController: NSViewController {

    let state: AppState

    private let tableView = LayerTableView()
    private let scrollView = NSScrollView()
    private var observerID: UUID?
    private var isSyncingSelection = false
    /// 拖放落下、正在改模型：这一次的文档变更由表格自己的 `moveRow` 动画体现，不整表重载。
    private var isApplyingDrop = false

    private lazy var addButton = ControlFactory.symbolButton(
        symbol: "plus",
        target: self,
        action: #selector(showAddMenu(_:)),
        tooltip: L("New Layer"),
        accessibility: L("New Layer")
    )

    private lazy var removeButton = ControlFactory.symbolButton(
        symbol: "minus",
        target: self,
        action: #selector(removeSelectedLayer(_:)),
        tooltip: L("Delete Selected Layer"),
        accessibility: L("Delete Selected Layer")
    )

    /// 「＋」点开的图型菜单。
    private lazy var addMenu: NSMenu = {
        let menu = NSMenu()
        for kind in PlotKind.allCases {
            let item = NSMenuItem(title: kind.displayName, action: #selector(addLayerItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            menu.addItem(item)
        }
        return menu
    }()

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LayerListViewController is created in code only")
    }

    deinit {
        if let observerID { MainActor.assumeIsolated { state.removeObserver(observerID) } }
    }

    override func loadView() {
        let root = FlippedView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = ControlFactory.sectionLabel(L("Layers"))
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let header = ControlFactory.stack(
            [title, spacer, addButton, removeButton],
            orientation: .horizontal,
            spacing: 8,
            alignment: .centerY
        )
        root.addSubview(header)
        // 图标按钮按图标本身的尺寸会被压成扁条（"minus" 只有 3 点高），固定一个方形点击区。
        for button in [addButton, removeButton] {
            button.imageScaling = .scaleNone
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 22),
                button.heightAnchor.constraint(equalToConstant: 20),
            ])
        }

        configureTable()
        root.addSubview(scrollView)

        let gutter = ControlFactory.Metric.gutter
        // The split view sizes this pane to its fitting height, so the list
        // has to ask for a few rows' worth of room or it opens on a sliver.
        let listHeight = scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        listHeight.priority = .defaultHigh
        listHeight.isActive = true
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gutter),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gutter),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: ControlFactory.Metric.rowSpacing),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observerID = state.observe([.layers, .document, .selection, .errors]) { [weak self] change in
            self?.handle(change)
        }
        reloadList()
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("GrapherNG.layerColumn"))
        column.width = 220
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.frame = NSRect(x: 0, y: 0, width: 220, height: 0)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = ControlFactory.Metric.layerRowHeight
        // 侧栏列表用系统侧栏样式：选中行是圆角内缩高亮，与 Finder / 邮件一致。
        tableView.style = .sourceList
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.registerForDraggedTypes([layerRowDragType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        // 图层只在本表里排序，不许拖到别的 App 或访达里去。
        tableView.setDraggingSourceOperationMask([], forLocal: false)
        tableView.draggingDestinationFeedbackStyle = .gap
        tableView.menuProvider = { [weak self] row in self?.contextMenu(for: row) }
        tableView.onDelete = { [weak self] in self?.removeSelectedLayer(nil) }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - State

    private func handle(_ change: AppState.Change) {
        switch change {
        case .document, .layers:
            guard !isApplyingDrop else { return }
            reloadList()
        case .selection:
            syncSelection()
        case .errors:
            refreshErrorBadges()
        default:
            break
        }
    }

    private func reloadList() {
        isSyncingSelection = true
        tableView.reloadData()
        isSyncingSelection = false
        syncSelection()
    }

    private func syncSelection() {
        removeButton.isEnabled = state.selectedLayer != nil
        let target = state.document.layers.firstIndex { $0.id == state.selection } ?? -1
        guard tableView.selectedRow != target else { return }
        isSyncingSelection = true
        if target >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        isSyncingSelection = false
    }

    /// Rewriting the icons of the visible rows is enough here, and keeps a
    /// `.errors` post — which every rebuild sends — from reloading the table.
    private func refreshErrorBadges() {
        let layers = state.document.layers
        for row in 0..<min(layers.count, tableView.numberOfRows) {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? LayerRowView else {
                continue
            }
            cell.setHasError(state.expressionErrors[layers[row].id] != nil)
        }
    }

    private func toggleVisibility(of id: UUID) {
        let isVisible = state.layer(with: id)?.isVisible ?? false
        state.mutateLayers(isVisible ? L("Hide Layer") : L("Show Layer")) { document in
            guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
            document.layers[index].isVisible.toggle()
        }
    }

    private func contextMenu(for row: Int) -> NSMenu? {
        guard row >= 0, row < state.document.layers.count else { return nil }
        let menu = NSMenu()
        let duplicate = menu.addItem(
            withTitle: L("Duplicate Layer"),
            action: #selector(duplicateSelectedLayer(_:)),
            keyEquivalent: ""
        )
        duplicate.target = self
        let remove = menu.addItem(
            withTitle: L("Delete"),
            action: #selector(removeSelectedLayer(_:)),
            keyEquivalent: ""
        )
        remove.target = self
        return menu
    }

    // MARK: - Actions

    @objc private func showAddMenu(_ sender: NSButton) {
        // 菜单从按钮正下方弹出。
        addMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func addLayerItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = PlotKind(rawValue: raw) else { return }
        state.addLayer(kind)
    }

    @objc private func removeSelectedLayer(_ sender: Any?) {
        guard let id = state.selection else { return }
        state.removeLayer(id: id)
    }

    @objc private func duplicateSelectedLayer(_ sender: Any?) {
        guard let id = state.selection else { return }
        state.duplicateLayer(id: id)
    }
}

// MARK: - Table data source / 拖拽排序
//
// 拖板里放的是图层 id 而不是行号：拖动途中列表若因为别的改动重载过，行号就对不上了。
// 落下时先改模型、再让表格用 `moveRow` 动画把那一行挪到位，期间不响应文档变更去整表
// `reloadData`——让位（`.gap`）动画进行中整表重载，会出现丢行、重复行、被拖的那行不见了。

extension LayerListViewController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        state.document.layers.count
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= 0, row < state.document.layers.count else { return nil }
        let item = NSPasteboardItem()
        item.setString(state.document.layers[row].id.uuidString, forType: layerRowDragType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let source = draggedRow(info) else { return [] }
        // 落在某一行「上」也按插到它前面处理，免得指针正好压在行中间时拒收。
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        // 插回原位或原位下方都等于没动：不给接受标记，也不播让位动画。
        guard row != source, row != source + 1 else { return [] }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let source = draggedRow(info), row != source, row != source + 1 else { return false }
        let id = state.document.layers[source].id
        // `row` 是「插到第 row 行之前」；往下挪时源行先被拿走，落点要减一。
        let finalRow = row > source ? row - 1 : row

        isApplyingDrop = true
        state.moveLayers(from: IndexSet(integer: source), to: row)
        isApplyingDrop = false

        tableView.beginUpdates()
        tableView.moveRow(at: source, to: finalRow)
        tableView.endUpdates()
        // 拖哪一行，松手后就选中哪一行。
        state.selection = id
        syncSelection()
        return true
    }

    /// 拖的是本表里的哪一行；不是从本表拖来的（或那个图层已经不在了）返回 nil。
    private func draggedRow(_ info: NSDraggingInfo) -> Int? {
        guard let source = info.draggingSource as? NSTableView, source === tableView,
              let text = info.draggingPasteboard.pasteboardItems?.first?.string(forType: layerRowDragType),
              let id = UUID(uuidString: text)
        else { return nil }
        return state.document.layers.firstIndex { $0.id == id }
    }
}

// MARK: - Table delegate

extension LayerListViewController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < state.document.layers.count else { return nil }
        let layer = state.document.layers[row]
        let cell: LayerRowView
        if let reused = tableView.makeView(withIdentifier: layerRowViewIdentifier, owner: self) as? LayerRowView {
            cell = reused
        } else {
            cell = LayerRowView(frame: .zero)
            cell.identifier = layerRowViewIdentifier
        }
        cell.configure(layer: layer, hasError: state.expressionErrors[layer.id] != nil)
        cell.onToggleVisibility = { [weak self] in self?.toggleVisibility(of: layer.id) }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        let row = tableView.selectedRow
        let id = row >= 0 && row < state.document.layers.count ? state.document.layers[row].id : nil
        guard id != state.selection else { return }
        state.selection = id
    }
}

/// The table hands the row under the cursor to `menuProvider` and makes it the
/// selection first, so a context-menu action always targets what was clicked.
private final class LayerTableView: NSTableView {

    var menuProvider: ((Int) -> NSMenu?)?
    /// ⌫ / ⌦ 删除所选图层。
    var onDelete: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return menuProvider?(row)
    }

    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117]   // delete（退格）、forward delete
        if deleteKeys.contains(event.keyCode), selectedRow >= 0, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onDelete?()
            return
        }
        super.keyDown(with: event)
    }
}

/// One layer: the visibility toggle, the colour swatch, the name and formula,
/// and an error badge on the trailing edge.
private final class LayerRowView: NSTableCellView {

    var onToggleVisibility: (() -> Void)?

    private let visibilityButton = ControlFactory.symbolButton(
        symbol: "eye",
        target: nil,
        action: #selector(toggleVisibility(_:)),
        tooltip: L("Show/Hide"),
        accessibility: L("Show/Hide")
    )
    private let swatch = LayerSwatchView(frame: .zero)
    private let warningView = NSImageView()

    private let nameLabel: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }()

    private let formulaLabel: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        field.textColor = ControlFactory.Palette.caption
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        visibilityButton.target = self
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LayerRowView is created in code only")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    func configure(layer: Layer, hasError: Bool) {
        nameLabel.stringValue = layer.name
        formulaLabel.stringValue = formulaText(for: layer)
        swatch.color = ControlFactory.nsColor(layer.lineStyle.color)

        let symbol = layer.isVisible ? "eye" : "eye.slash"
        visibilityButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L("Show/Hide"))
        visibilityButton.contentTintColor = layer.isVisible ? .secondaryLabelColor : .tertiaryLabelColor
        setHasError(hasError)
        applyColors()
    }

    func setHasError(_ hasError: Bool) {
        warningView.isHidden = !hasError
    }

    @objc private func toggleVisibility(_ sender: Any?) {
        onToggleVisibility?()
    }

    private func formulaText(for layer: Layer) -> String {
        if layer.kind == .explicit, layer.usesExplicitDomain {
            // 限定了定义域就写出来：画布上曲线在这里截止，列表里也要看得出为什么。
            let lower = min(layer.domainLower, layer.domainUpper)
            let upper = max(layer.domainLower, layer.domainUpper)
            return "\(layer.formula)   x ∈ [\(String(format: "%g", lower)), \(String(format: "%g", upper))]"
        }
        guard layer.kind == .parametric, !layer.secondaryFormula.isEmpty else { return layer.formula }
        return "x = \(layer.formula)   y = \(layer.secondaryFormula)"
    }

    private func applyColors() {
        let emphasized = backgroundStyle == .emphasized
        nameLabel.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        formulaLabel.textColor = emphasized
            ? .alternateSelectedControlTextColor.withAlphaComponent(0.8)
            : ControlFactory.Palette.caption
    }

    private func build() {
        for subview in [visibilityButton, swatch, nameLabel, formulaLabel, warningView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        warningView.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: L("The formula has a syntax error")
        )
        warningView.contentTintColor = .systemOrange
        warningView.toolTip = L("The formula has a syntax error")
        warningView.imageScaling = .scaleProportionallyUpOrDown
        warningView.isHidden = true

        NSLayoutConstraint.activate([
            visibilityButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            visibilityButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            visibilityButton.widthAnchor.constraint(equalToConstant: 22),

            swatch.leadingAnchor.constraint(equalTo: visibilityButton.trailingAnchor, constant: 6),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 12),
            swatch.heightAnchor.constraint(equalToConstant: 12),

            nameLabel.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: warningView.leadingAnchor, constant: -6),

            formulaLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            formulaLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            formulaLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),

            warningView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            warningView.centerYAnchor.constraint(equalTo: centerYAnchor),
            warningView.widthAnchor.constraint(equalToConstant: 13),
            warningView.heightAnchor.constraint(equalToConstant: 13),
        ])
    }
}

/// A 12×12 rounded chip filled with the layer's stroke colour.
private final class LayerSwatchView: NSView {

    var color: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let inner = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: inner, xRadius: 3, yRadius: 3)
        color.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
