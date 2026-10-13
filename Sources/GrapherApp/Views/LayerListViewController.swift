import AppKit
import GrapherKit

private let layerRowDragType = NSPasteboard.PasteboardType("com.grapherng.layer-row")
private let layerRowViewIdentifier = NSUserInterfaceItemIdentifier("GrapherNG.layerRow")

/// The left column's upper half: one row per layer, reorderable by dragging,
/// with the add/remove footer underneath.
final class LayerListViewController: NSViewController {

    let state: AppState

    private let tableView = LayerTableView()
    private let scrollView = NSScrollView()
    private var observerID: UUID?
    private var isSyncingSelection = false

    private lazy var addButton: NSPopUpButton = {
        let button = ControlFactory.popUp(
            items: [],
            target: nil,
            action: #selector(addLayerItem(_:))
        )
        button.pullsDown = true
        button.addItem(withTitle: "+ 添加")
        for kind in PlotKind.allCases {
            let item = NSMenuItem(title: kind.displayName, action: #selector(addLayerItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            button.menu?.addItem(item)
        }
        return button
    }()

    private lazy var removeButton = ControlFactory.pushButton(
        "−",
        target: self,
        action: #selector(removeSelectedLayer(_:))
    )

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

        let header = ControlFactory.sectionLabel("图层")
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        configureTable()
        root.addSubview(scrollView)

        let footer = ControlFactory.stack([addButton, removeButton], orientation: .horizontal, spacing: 6)
        root.addSubview(footer)

        let gutter = ControlFactory.Metric.gutter
        // The split view sizes this pane to its fitting height, so the list
        // has to ask for a few rows' worth of room or it opens on a sliver.
        let listHeight = scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        listHeight.priority = .defaultHigh
        listHeight.isActive = true
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gutter),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -gutter),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gutter),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -gutter),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
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
        tableView.style = .fullWidth
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.registerForDraggedTypes([layerRowDragType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.draggingDestinationFeedbackStyle = .gap
        tableView.menuProvider = { [weak self] row in self?.contextMenu(for: row) }

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
        state.mutateLayers(isVisible ? "隐藏图层" : "显示图层") { document in
            guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
            document.layers[index].isVisible.toggle()
        }
    }

    private func contextMenu(for row: Int) -> NSMenu? {
        guard row >= 0, row < state.document.layers.count else { return nil }
        let menu = NSMenu()
        let duplicate = menu.addItem(
            withTitle: "复制图层",
            action: #selector(duplicateSelectedLayer(_:)),
            keyEquivalent: ""
        )
        duplicate.target = self
        let remove = menu.addItem(
            withTitle: "删除",
            action: #selector(removeSelectedLayer(_:)),
            keyEquivalent: ""
        )
        remove.target = self
        return menu
    }

    // MARK: - Actions

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

// MARK: - Table data source

extension LayerListViewController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        state.document.layers.count
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: layerRowDragType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let source = info.draggingSource as? NSTableView, source === tableView else { return [] }
        guard dropOperation == .above else { return [] }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let text = info.draggingPasteboard.pasteboardItems?.first?.string(forType: layerRowDragType),
              let source = Int(text),
              source >= 0,
              source < state.document.layers.count,
              row != source,
              row != source + 1
        else { return false }
        state.moveLayers(from: IndexSet(integer: source), to: row)
        return true
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return menuProvider?(row)
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
        tooltip: "显示/隐藏",
        accessibility: "显示/隐藏"
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
        visibilityButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "显示/隐藏")
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
            accessibilityDescription: "公式有语法错误"
        )
        warningView.contentTintColor = .systemOrange
        warningView.toolTip = "公式有语法错误"
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
