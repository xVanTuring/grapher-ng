import AppKit
import GrapherKit

/// A pane that takes the full width of the inspector's column. The inspector
/// stacks its panes with leading alignment, and NSStackView only applies
/// alignment constraints at low priority, so without this a pane would sit at
/// its narrow fitting width.
final class InspectorPaneView: NSView {
    private var widthConstraint: NSLayoutConstraint?

    override var isFlipped: Bool { true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        widthConstraint?.isActive = false
        widthConstraint = nil
        guard let superview else { return }
        let constraint = widthAnchor.constraint(equalTo: superview.widthAnchor)
        constraint.isActive = true
        widthConstraint = constraint
    }
}

/// Editor for the selected layer. The form is rebuilt whenever the selection or
/// the plot kind changes, and otherwise only has its values refreshed, so that
/// typing in a formula field is never interrupted.
final class LayerEditorViewController: NSViewController {

    let state: AppState

    private let container = NSStackView()
    private var builtLayerID: UUID?
    private var builtKind: PlotKind?
    private var liveCommitTask: Task<Void, Never>?

    private var nameField: NSTextField?
    private var kindPopUp: NSPopUpButton?
    private var primaryField: FormulaFieldView?
    private var secondaryField: FormulaFieldView?
    private var domainCheckbox: NSButton?
    private var domainGroup: NSStackView?
    private var domainLowerField: NSTextField?
    private var domainUpperField: NSTextField?
    private var relationPopUp: NSPopUpButton?
    private var lineColorWell: NSColorWell?
    private var lineWidthSlider: NSSlider?
    private var lineWidthLabel: NSTextField?
    private var fillCheckbox: NSButton?
    private var fillColorWell: NSColorWell?
    private var fillOpacitySlider: NSSlider?
    private var fillOpacityLabel: NSTextField?

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LayerEditorViewController is created in code only")
    }

    deinit {
        liveCommitTask?.cancel()
    }

    override func loadView() {
        let root = InspectorPaneView()
        root.translatesAutoresizingMaskIntoConstraints = false

        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = ControlFactory.Metric.sectionSpacing
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
    }

    // MARK: - Form

    func reload() {
        guard let layer = state.selectedLayer else {
            builtLayerID = nil
            builtKind = nil
            clearReferences()
            replaceContents([ControlFactory.caption("在左侧选一个图层来编辑，或者点「添加」新建一个。")])
            return
        }
        if layer.id == builtLayerID, layer.kind == builtKind {
            refresh(layer)
        } else {
            build(layer)
        }
    }

    private func build(_ layer: Layer) {
        builtLayerID = layer.id
        builtKind = layer.kind
        clearReferences()

        var rows: [NSView] = [ControlFactory.heading("图层")]

        let name = ControlFactory.textField(layer.name, target: self, action: #selector(nameEdited(_:)))
        name.cell?.sendsActionOnEndEditing = true
        nameField = name
        rows.append(ControlFactory.formRow("名称", name))

        let kinds = PlotKind.allCases
        let kindPopUp = ControlFactory.popUp(
            items: kinds.map(\.shortName),
            target: self,
            action: #selector(kindEdited(_:))
        )
        if let index = kinds.firstIndex(of: layer.kind) { kindPopUp.selectItem(at: index) }
        self.kindPopUp = kindPopUp
        rows.append(ControlFactory.formRow("类型", kindPopUp))

        rows.append(contentsOf: formulaRows(layer))

        if layer.kind.usesDomain {
            let checkbox = ControlFactory.checkbox("指定定义域", target: self, action: #selector(domainToggled(_:)))
            domainCheckbox = checkbox
            let group = domainGroup(layer)
            domainGroup = group
            rows.append(checkbox)
            rows.append(group)
        }

        if layer.kind.usesRelation {
            let relations = RegionRelation.allCases
            let popUp = ControlFactory.popUp(
                items: relations.map { "F(x,y) \($0.symbol) 0" },
                target: self,
                action: #selector(relationEdited(_:))
            )
            if let index = relations.firstIndex(of: layer.relation) { popUp.selectItem(at: index) }
            relationPopUp = popUp
            rows.append(ControlFactory.formRow("关系", popUp))
        }

        rows.append(ControlFactory.separator())
        rows.append(ControlFactory.sectionLabel("线条"))
        rows.append(contentsOf: lineRows(layer))

        if layer.kind == .region {
            rows.append(ControlFactory.sectionLabel("填充"))
            rows.append(contentsOf: fillRows(layer))
        }

        replaceContents(rows)
        refresh(layer)
    }

    private func refresh(_ layer: Layer) {
        if let nameField, nameField.currentEditor() == nil {
            nameField.stringValue = layer.name
        }
        if let kindPopUp, let index = PlotKind.allCases.firstIndex(of: layer.kind) {
            kindPopUp.selectItem(at: index)
        }

        primaryField?.text = layer.formula
        primaryField?.error = state.expressionErrors[layer.id]
        secondaryField?.text = layer.secondaryFormula

        domainCheckbox?.state = layer.usesExplicitDomain ? .on : .off
        domainGroup?.isHidden = !layer.usesExplicitDomain
        if let domainLowerField, domainLowerField.currentEditor() == nil {
            domainLowerField.stringValue = ControlFactory.format(layer.domainLower)
        }
        if let domainUpperField, domainUpperField.currentEditor() == nil {
            domainUpperField.stringValue = ControlFactory.format(layer.domainUpper)
        }
        if let relationPopUp, let index = RegionRelation.allCases.firstIndex(of: layer.relation) {
            relationPopUp.selectItem(at: index)
        }

        lineColorWell?.color = ControlFactory.nsColor(layer.lineStyle.color)
        lineWidthSlider?.doubleValue = layer.lineStyle.width
        lineWidthLabel?.stringValue = ControlFactory.format(layer.lineStyle.width)

        fillCheckbox?.state = layer.fillStyle.isFilled ? .on : .off
        fillColorWell?.color = ControlFactory.nsColor(layer.fillStyle.color)
        fillOpacitySlider?.doubleValue = layer.fillStyle.opacity
        fillOpacityLabel?.stringValue = ControlFactory.format(layer.fillStyle.opacity)
    }

    private func replaceContents(_ views: [NSView]) {
        for subview in container.arrangedSubviews {
            container.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        for view in views {
            container.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }
    }

    private func clearReferences() {
        nameField = nil
        kindPopUp = nil
        primaryField = nil
        secondaryField = nil
        domainCheckbox = nil
        domainGroup = nil
        domainLowerField = nil
        domainUpperField = nil
        relationPopUp = nil
        lineColorWell = nil
        lineWidthSlider = nil
        lineWidthLabel = nil
        fillCheckbox = nil
        fillColorWell = nil
        fillOpacitySlider = nil
        fillOpacityLabel = nil
    }

    // MARK: - Formula rows

    private func formulaRows(_ layer: Layer) -> [NSView] {
        switch layer.kind {
        case .explicit:
            let field = makeFormulaField(
                title: "公式 y = f(x)",
                placeholder: PlotKind.explicit.primaryPlaceholder,
                layerID: layer.id,
                isPrimary: true
            )
            primaryField = field
            return [field]
        case .parametric:
            let xField = makeFormulaField(
                title: "x(t) =",
                placeholder: PlotKind.parametric.primaryPlaceholder,
                layerID: layer.id,
                isPrimary: true
            )
            let yField = makeFormulaField(
                title: "y(t) =",
                placeholder: PlotKind.parametric.secondaryPlaceholder,
                layerID: layer.id,
                isPrimary: false
            )
            primaryField = xField
            secondaryField = yField
            return [xField, yField]
        case .polar:
            let field = makeFormulaField(
                title: "r(θ) =",
                placeholder: PlotKind.polar.primaryPlaceholder,
                layerID: layer.id,
                isPrimary: true
            )
            primaryField = field
            return [field]
        case .implicit:
            let field = makeFormulaField(
                title: "F(x, y) = 0，即 F 填在这里",
                placeholder: PlotKind.implicit.primaryPlaceholder,
                layerID: layer.id,
                isPrimary: true
            )
            primaryField = field
            return [field]
        case .region:
            let field = makeFormulaField(
                title: "F(x, y) 与 0 比较",
                placeholder: PlotKind.region.primaryPlaceholder,
                layerID: layer.id,
                isPrimary: true
            )
            primaryField = field
            return [field]
        }
    }

    private func makeFormulaField(
        title: String,
        placeholder: String,
        layerID: UUID,
        isPrimary: Bool
    ) -> FormulaFieldView {
        let field = FormulaFieldView(title: title, placeholder: placeholder)
        field.onLiveChange = { [weak self] text in
            guard let self else { return }
            self.state.beginLiveEdit()
            self.state.updateLayerLive(id: layerID) { layer in
                if isPrimary { layer.formula = text } else { layer.secondaryFormula = text }
            }
        }
        field.onCommit = { [weak self] text in
            guard let self else { return }
            self.state.updateLayerLive(id: layerID) { layer in
                if isPrimary { layer.formula = text } else { layer.secondaryFormula = text }
            }
            self.state.commitLiveEdit("修改公式")
        }
        return field
    }

    // MARK: - Domain rows

    private func domainGroup(_ layer: Layer) -> NSStackView {
        let lower = ControlFactory.numberField(
            layer.domainLower,
            target: self,
            action: #selector(domainEdited(_:))
        )
        let upper = ControlFactory.numberField(
            layer.domainUpper,
            target: self,
            action: #selector(domainEdited(_:))
        )
        lower.setContentHuggingPriority(.defaultLow, for: .horizontal)
        upper.setContentHuggingPriority(.defaultLow, for: .horizontal)
        domainLowerField = lower
        domainUpperField = upper

        let dash = ControlFactory.label("到")
        dash.setContentHuggingPriority(.required, for: .horizontal)
        dash.setContentCompressionResistancePriority(.required, for: .horizontal)
        let bounds = ControlFactory.stack(
            [lower, dash, upper],
            orientation: .horizontal,
            spacing: 6,
            alignment: .firstBaseline
        )
        lower.widthAnchor.constraint(equalTo: upper.widthAnchor).isActive = true

        let fullCircle = ControlFactory.pushButton(
            "0…2π",
            target: self,
            action: #selector(domainFullCircle(_:))
        )
        let visible = ControlFactory.pushButton(
            "视图范围",
            target: self,
            action: #selector(domainFollowViewport(_:))
        )
        let shortcuts = ControlFactory.stack(
            [fullCircle, visible],
            orientation: .horizontal,
            spacing: 6,
            alignment: .centerY
        )

        return ControlFactory.stack(
            [
                ControlFactory.formRow(domainSymbol(layer.kind), bounds),
                ControlFactory.formRow("", shortcuts),
            ],
            spacing: ControlFactory.Metric.rowSpacing
        )
    }

    private func domainSymbol(_ kind: PlotKind) -> String {
        switch kind {
        case .polar: return "θ"
        case .parametric: return "t"
        default: return "x"
        }
    }

    // MARK: - Style rows

    private func lineRows(_ layer: Layer) -> [NSView] {
        let well = ControlFactory.colorWell(
            ControlFactory.nsColor(layer.lineStyle.color),
            target: self,
            action: #selector(lineColorEdited(_:))
        )
        lineColorWell = well

        let slider = ControlFactory.slider(
            value: layer.lineStyle.width,
            range: 0.5...6,
            target: self,
            action: #selector(lineWidthEdited(_:))
        )
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        lineWidthSlider = slider

        let value = ControlFactory.monospacedLabel(ControlFactory.format(layer.lineStyle.width))
        value.widthAnchor.constraint(equalToConstant: 34).isActive = true
        lineWidthLabel = value

        let width = ControlFactory.stack(
            [slider, value],
            orientation: .horizontal,
            spacing: 6,
            alignment: .centerY
        )
        return [ControlFactory.formRow("颜色", well), ControlFactory.formRow("线宽", width)]
    }

    private func fillRows(_ layer: Layer) -> [NSView] {
        let checkbox = ControlFactory.checkbox("填充区域", target: self, action: #selector(fillToggled(_:)))
        fillCheckbox = checkbox

        let well = ControlFactory.colorWell(
            ControlFactory.nsColor(layer.fillStyle.color),
            target: self,
            action: #selector(fillColorEdited(_:))
        )
        fillColorWell = well

        let slider = ControlFactory.slider(
            value: layer.fillStyle.opacity,
            range: 0.05...1,
            target: self,
            action: #selector(fillOpacityEdited(_:))
        )
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fillOpacitySlider = slider

        let value = ControlFactory.monospacedLabel(ControlFactory.format(layer.fillStyle.opacity))
        value.widthAnchor.constraint(equalToConstant: 34).isActive = true
        fillOpacityLabel = value

        let opacity = ControlFactory.stack(
            [slider, value],
            orientation: .horizontal,
            spacing: 6,
            alignment: .centerY
        )
        return [
            checkbox,
            ControlFactory.formRow("颜色", well),
            ControlFactory.formRow("不透明度", opacity),
        ]
    }

    // MARK: - Actions

    @objc private func nameEdited(_ sender: NSTextField) {
        let name = sender.stringValue
        editLayerList("重命名") { $0.name = name }
    }

    @objc private func kindEdited(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < PlotKind.allCases.count else { return }
        let kind = PlotKind.allCases[index]
        editLayer("修改类型") { $0.kind = kind }
    }

    @objc private func domainToggled(_ sender: NSButton) {
        let on = sender.state == .on
        editLayer("修改定义域") { $0.usesExplicitDomain = on }
    }

    @objc private func domainEdited(_ sender: NSTextField) {
        guard let layer = state.selectedLayer else { return }
        let lower = ControlFactory.parse(domainLowerField?.stringValue ?? "") ?? layer.domainLower
        let upper = ControlFactory.parse(domainUpperField?.stringValue ?? "") ?? layer.domainUpper
        setDomain(lower: lower, upper: upper)
    }

    @objc private func domainFullCircle(_ sender: Any?) {
        setDomain(lower: 0, upper: 2 * Double.pi)
    }

    @objc private func domainFollowViewport(_ sender: Any?) {
        setDomain(lower: state.viewport.unobscured.xRange.lowerBound, upper: state.viewport.unobscured.xRange.upperBound)
    }

    @objc private func relationEdited(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < RegionRelation.allCases.count else { return }
        let relation = RegionRelation.allCases[index]
        editLayer("修改关系") { $0.relation = relation }
    }

    @objc private func lineColorEdited(_ sender: NSColorWell) {
        let color = ControlFactory.rgbaColor(sender.color)
        editLayer("修改颜色") { $0.lineStyle.color = color }
    }

    @objc private func lineWidthEdited(_ sender: NSSlider) {
        let width = sender.doubleValue
        liveEdit("修改线宽") { $0.lineStyle.width = width }
        lineWidthLabel?.stringValue = ControlFactory.format(width)
    }

    @objc private func fillToggled(_ sender: NSButton) {
        let on = sender.state == .on
        editLayer("修改填充") { $0.fillStyle.isFilled = on }
    }

    @objc private func fillColorEdited(_ sender: NSColorWell) {
        let color = ControlFactory.rgbaColor(sender.color)
        editLayer("修改填充颜色") { $0.fillStyle.color = color }
    }

    @objc private func fillOpacityEdited(_ sender: NSSlider) {
        let opacity = sender.doubleValue
        liveEdit("修改填充") { $0.fillStyle.opacity = opacity }
        fillOpacityLabel?.stringValue = ControlFactory.format(opacity)
    }

    // MARK: - Mutation helpers

    private func editLayer(_ actionName: String, _ body: @escaping (inout Layer) -> Void) {
        applyEdit(actionName, listChange: false, body)
    }

    private func editLayerList(_ actionName: String, _ body: @escaping (inout Layer) -> Void) {
        applyEdit(actionName, listChange: true, body)
    }

    private func applyEdit(
        _ actionName: String,
        listChange: Bool,
        _ body: @escaping (inout Layer) -> Void
    ) {
        guard let id = state.selectedLayer?.id else { return }
        let update: (inout GrapherDocument) -> Void = { document in
            guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
            body(&document.layers[index])
        }
        if listChange {
            state.mutateLayers(actionName, update)
        } else {
            state.mutate(actionName, update)
        }
    }

    /// Dragging a slider produces a stream of changes; the run is closed into a
    /// single undo step once the changes stop arriving.
    private func liveEdit(_ actionName: String, _ body: @escaping (inout Layer) -> Void) {
        guard let id = state.selectedLayer?.id else { return }
        state.beginLiveEdit()
        state.updateLayerLive(id: id, body)
        liveCommitTask?.cancel()
        liveCommitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            self.state.commitLiveEdit(actionName)
        }
    }

    private func setDomain(lower: Double, upper: Double) {
        guard let id = state.selectedLayer?.id else { return }
        state.mutate("修改定义域") { document in
            guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
            document.layers[index].domainLower = lower
            document.layers[index].domainUpper = upper
        }
    }
}
