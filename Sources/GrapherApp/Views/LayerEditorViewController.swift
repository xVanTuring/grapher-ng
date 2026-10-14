import AppKit
import GrapherKit
import simd

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
    private var tertiaryField: FormulaFieldView?
    private var builtAsSurface: Bool?
    private var domainCheckbox: NSButton?
    private var domainGroup: NSStackView?
    private var domainLowerField: NSTextField?
    private var domainUpperField: NSTextField?
    private var domain2LowerField: NSTextField?
    private var domain2UpperField: NSTextField?
    private var extrudeCheckbox: NSButton?
    private var sourceAPopUp: NSPopUpButton?
    private var sourceBPopUp: NSPopUpButton?
    private var sourceHint: NSTextField?
    private var projectionSourcePopUp: NSPopUpButton?
    private var projectionTargetPopUp: NSPopUpButton?
    private var projectionOffsetField: NSTextField?
    private var projectionOffsetRow: NSView?
    private var projectorsCheckbox: NSButton?
    private var labelCheckbox: NSButton?
    private var obliqueCheckbox: NSButton?
    private var directionFields: [NSTextField] = []
    private var directionRowView: NSView?
    private var textContentField: NSTextField?
    private var textPositionFields: [NSTextField] = []
    private var fontSizeField: NSTextField?
    private var tangentSourcePopUp: NSPopUpButton?
    private var anchorUField: NSTextField?
    private var anchorVField: NSTextField?
    private var normalCheckbox: NSButton?
    private var tangentReadout: NSTextField?
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
            replaceContents([ControlFactory.caption(L("Select a layer on the left to edit it, or click + to create one."))])
            return
        }
        // 换了图层、换了类型、或者「延伸到 3D」改变了画成线还是画成面，表单都要重排。
        if layer.id == builtLayerID, layer.kind == builtKind, rendersAsSurface(layer) == builtAsSurface {
            refresh(layer)
        } else {
            build(layer)
        }
    }

    /// 这个图层在画布上是一张面（只有颜色可调）还是一条线（颜色 + 线宽）。
    private func rendersAsSurface(_ layer: Layer) -> Bool {
        switch layer.kind {
        case .surface, .parametricSurface, .implicitSurface: return true
        case .explicit, .parametric, .polar, .implicit:
            return state.document.dimension == .space && layer.extrudesInSpace
        case .region, .spaceCurve, .surfaceIntersection, .point, .projection, .tangent, .tangentPlane, .text: return false
        }
    }

    private func build(_ layer: Layer) {
        builtLayerID = layer.id
        builtKind = layer.kind
        builtAsSurface = rendersAsSurface(layer)
        clearReferences()

        var rows: [NSView] = [ControlFactory.heading(L("Layer"))]

        let name = ControlFactory.textField(layer.name, target: self, action: #selector(nameEdited(_:)))
        name.cell?.sendsActionOnEndEditing = true
        nameField = name
        rows.append(ControlFactory.formRow(L("Name"), name))

        let kinds = availableKinds
        let kindPopUp = ControlFactory.popUp(
            items: kinds.map(\.shortName),
            target: self,
            action: #selector(kindEdited(_:))
        )
        if let index = kinds.firstIndex(of: layer.kind) { kindPopUp.selectItem(at: index) }
        self.kindPopUp = kindPopUp
        rows.append(ControlFactory.formRow(L("Type"), kindPopUp))

        rows.append(contentsOf: formulaRows(layer))

        if layer.kind == .surfaceIntersection {
            let a = ControlFactory.popUp(items: [], target: self, action: #selector(sourceAEdited(_:)))
            let b = ControlFactory.popUp(items: [], target: self, action: #selector(sourceBEdited(_:)))
            sourceAPopUp = a
            sourceBPopUp = b
            rows.append(ControlFactory.formRow(L("Surface A"), a))
            rows.append(ControlFactory.formRow(L("Surface B"), b))
            let hint = ControlFactory.caption(
                L("The curve where the two surfaces meet. Hide the surfaces to keep only the curve.")
            )
            sourceHint = hint
            rows.append(hint)
        }

        if layer.kind == .projection {
            let source = ControlFactory.popUp(items: [], target: self, action: #selector(projectionSourceEdited(_:)))
            let target = ControlFactory.popUp(items: [], target: self, action: #selector(projectionTargetEdited(_:)))
            let offset = ControlFactory.numberField(layer.projectionOffset, target: self, action: #selector(projectionOffsetEdited(_:)))
            let projectors = ControlFactory.checkbox(
                L("Show projecting lines"), target: self, action: #selector(projectorsToggled(_:)))
            projectionSourcePopUp = source
            projectionTargetPopUp = target
            projectionOffsetField = offset
            projectorsCheckbox = projectors
            let offsetRow = ControlFactory.formRow(L("Position"), offset)
            projectionOffsetRow = offsetRow
            rows.append(ControlFactory.formRow(L("Project"), source))
            rows.append(ControlFactory.formRow(L("Onto"), target))
            rows.append(offsetRow)
            let oblique = ControlFactory.checkbox(
                L("Oblique projection"), target: self, action: #selector(obliqueToggled(_:)))
            oblique.toolTip = L("Project along a direction instead of perpendicular to the plane.")
            obliqueCheckbox = oblique
            rows.append(oblique)
            let fields = (0..<3).map { _ in
                ControlFactory.numberField(0, target: self, action: #selector(directionEdited(_:)))
            }
            directionFields = fields
            let directionRow = ControlFactory.stack(fields, orientation: .horizontal, spacing: 6, alignment: .firstBaseline)
            fields.forEach { $0.setContentHuggingPriority(.defaultLow, for: .horizontal) }
            for field in fields.dropFirst() { field.widthAnchor.constraint(equalTo: fields[0].widthAnchor).isActive = true }
            let directionLabeled = ControlFactory.formRow(L("Direction"), directionRow)
            directionRowView = directionLabeled
            rows.append(directionLabeled)
            rows.append(projectors)
            rows.append(ControlFactory.caption(
                L("Orthogonal projection of a point, space curve or surface intersection. Hide the original to keep only the projection.")))
        }

        if layer.kind == .text {
            let content = ControlFactory.textField(layer.formula, target: self, action: #selector(textContentEdited(_:)))
            content.cell?.sendsActionOnEndEditing = true
            textContentField = content
            rows.append(ControlFactory.formRow(L("Text"), content))
            let isSpace = state.document.dimension == .space
            let axes = isSpace ? ["x", "y", "z"] : ["x", "y"]
            textPositionFields = axes.map { _ in
                ControlFactory.numberField(0, target: self, action: #selector(textPositionEdited(_:)))
            }
            for (name, field) in zip(axes, textPositionFields) {
                rows.append(ControlFactory.formRow(name, field))
            }
            let size = ControlFactory.numberField(layer.fontSize, target: self, action: #selector(fontSizeEdited(_:)))
            fontSizeField = size
            rows.append(ControlFactory.formRow(L("Font size"), size))
        }

        if layer.kind == .tangent || layer.kind == .tangentPlane {
            let source = ControlFactory.popUp(items: [], target: self, action: #selector(tangentSourceEdited(_:)))
            tangentSourcePopUp = source
            rows.append(ControlFactory.formRow(L("Of"), source))
            let first = ControlFactory.numberField(layer.anchorU, target: self, action: #selector(anchorEdited(_:)))
            anchorUField = first
            if layer.kind == .tangent {
                rows.append(ControlFactory.formRow(L("At"), first))
                let normal = ControlFactory.checkbox(
                    L("Draw the normal line instead"), target: self, action: #selector(normalToggled(_:)))
                normalCheckbox = normal
                rows.append(normal)
            } else {
                let second = ControlFactory.numberField(layer.anchorV, target: self, action: #selector(anchorEdited(_:)))
                anchorVField = second
                rows.append(ControlFactory.formRow(L("At u or x"), first))
                rows.append(ControlFactory.formRow(L("At v or y"), second))
            }
            let readout = ControlFactory.caption("")
            tangentReadout = readout
            rows.append(readout)
        }

        if layer.kind.usesDomain {
            // 只有显函数的定义域是可选的（不限定就跟着可见范围走）；参数方程、极坐标、空间曲线、
            // 参数曲面的参数范围总是生效，不给一个勾了也白勾的开关。
            if layer.kind == .explicit {
                let checkbox = ControlFactory.checkbox(L("Restrict domain"), target: self, action: #selector(domainToggled(_:)))
                domainCheckbox = checkbox
                rows.append(checkbox)
            }
            let group = domainGroup(layer, second: false)
            domainGroup = group
            rows.append(group)
            if layer.kind.usesSecondDomain {
                rows.append(domainGroup(layer, second: true))
            }
        }

        if state.document.dimension == .space, layer.kind.canExtrude {
            let checkbox = ControlFactory.checkbox(L("Extend into 3D"), target: self, action: #selector(extrudeToggled(_:)))
            checkbox.toolTip = L("Off: a curve on the z = 0 plane. On: a vertical surface swept along z through the box.")
            extrudeCheckbox = checkbox
            rows.append(checkbox)
        }

        if layer.kind == .point {
            let checkbox = ControlFactory.checkbox(L("Show name"), target: self, action: #selector(labelToggled(_:)))
            labelCheckbox = checkbox
            rows.append(checkbox)
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
            rows.append(ControlFactory.formRow(L("Relation"), popUp))
        }

        rows.append(ControlFactory.separator())
        if rendersAsSurface(layer) {
            // 曲面只有颜色可调：线宽对它没有意义。
            rows.append(ControlFactory.sectionLabel(L("Surface")))
            rows.append(lineRows(layer)[0])
            rows.append(ControlFactory.formRow(L("Opacity"), opacityControl(layer)))
        } else {
            rows.append(ControlFactory.sectionLabel(L("Line")))
            rows.append(contentsOf: lineRows(layer))
        }

        if layer.kind == .region {
            rows.append(ControlFactory.sectionLabel(L("Fill")))
            rows.append(contentsOf: fillRows(layer))
        }

        replaceContents(rows)
        refresh(layer)
    }

    private func refresh(_ layer: Layer) {
        if let nameField, nameField.currentEditor() == nil {
            nameField.stringValue = layer.name
        }
        if let kindPopUp, let index = availableKinds.firstIndex(of: layer.kind) {
            kindPopUp.selectItem(at: index)
        }

        // 每一栏显示自己的错误，列号指向的就是这一栏里的位置。
        let errors = state.formulaErrors[layer.id]
        primaryField?.text = layer.formula
        primaryField?.error = errors?.primary
        secondaryField?.text = layer.secondaryFormula
        secondaryField?.error = errors?.secondary
        tertiaryField?.text = layer.tertiaryFormula
        tertiaryField?.error = errors?.tertiary

        domainCheckbox?.state = layer.usesExplicitDomain ? .on : .off
        domainGroup?.isHidden = layer.kind == .explicit && !layer.usesExplicitDomain
        for (field, value) in [(domainLowerField, layer.domainLower), (domainUpperField, layer.domainUpper),
                               (domain2LowerField, layer.domain2Lower), (domain2UpperField, layer.domain2Upper)] {
            if let field, field.currentEditor() == nil { field.stringValue = ControlFactory.format(value) }
        }
        extrudeCheckbox?.state = layer.extrudesInSpace ? .on : .off
        labelCheckbox?.state = layer.showsLabel ? .on : .off
        refreshSourcePopUps(layer)
        refreshProjection(layer)
        refreshTangent(layer)
        refreshText(layer)
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

    /// 交线能选的来源：文档里所有曲面图层（列表随图层增删改名变化，每次刷新都重填）。
    private var sourceCandidates: [Layer] { state.document.layers.filter { $0.kind.isSurfaceSource } }

    private func refreshSourcePopUps(_ layer: Layer) {
        guard let a = sourceAPopUp, let b = sourceBPopUp else { return }
        let candidates = sourceCandidates
        for (popUp, selected) in [(a, layer.sourceA), (b, layer.sourceB)] {
            popUp.removeAllItems()
            popUp.addItem(withTitle: L("None"))
            popUp.menu?.addItem(.separator())
            for candidate in candidates { popUp.addItem(withTitle: candidate.name) }
            // 菜单项 = 「无」+ 分隔线 + 各曲面；分隔线占一个序号。
            if let selected, let index = candidates.firstIndex(where: { $0.id == selected }) {
                popUp.selectItem(at: index + 2)
            } else {
                popUp.selectItem(at: 0)
            }
        }
        let ready = layer.sourceA != nil && layer.sourceB != nil && layer.sourceA != layer.sourceB
            && candidates.contains { $0.id == layer.sourceA } && candidates.contains { $0.id == layer.sourceB }
        sourceHint?.stringValue = ready
            ? L("The curve where the two surfaces meet. Hide the surfaces to keep only the curve.")
            : L("Pick two different surface layers. Add surfaces first if the lists are empty.")
    }

    // MARK: - Text rows

    private func refreshText(_ layer: Layer) {
        if let field = textContentField, field.currentEditor() == nil { field.stringValue = layer.formula }
        let values = [layer.anchorU, layer.anchorV, layer.anchorW]
        for (field, value) in zip(textPositionFields, values) where field.currentEditor() == nil {
            field.stringValue = ControlFactory.format(value)
        }
        if let field = fontSizeField, field.currentEditor() == nil { field.stringValue = ControlFactory.format(layer.fontSize) }
    }

    @objc private func textContentEdited(_ sender: NSTextField) {
        let text = sender.stringValue
        editLayer(L("Edit Text")) { $0.formula = text }
    }

    @objc private func textPositionEdited(_ sender: NSTextField) {
        guard let layer = state.selectedLayer else { return }
        var values = [layer.anchorU, layer.anchorV, layer.anchorW]
        for (index, field) in textPositionFields.enumerated() {
            values[index] = ControlFactory.parse(field.stringValue) ?? values[index]
        }
        editLayer(L("Move Text")) {
            $0.anchorU = values[0]
            $0.anchorV = values[1]
            $0.anchorW = values[2]
        }
    }

    @objc private func fontSizeEdited(_ sender: NSTextField) {
        guard let layer = state.selectedLayer else { return }
        let size = min(max(ControlFactory.parse(sender.stringValue) ?? layer.fontSize, 6), 96)
        editLayer(L("Change Font Size")) { $0.fontSize = size }
    }

    // MARK: - Tangent rows

    private func tangentCandidates(for layer: Layer) -> [Layer] {
        state.document.layers.filter { layer.kind == .tangent ? $0.kind.isTangentSource : $0.kind.isTangentPlaneSource }
    }

    private func refreshTangent(_ layer: Layer) {
        guard let popUp = tangentSourcePopUp else { return }
        let sources = tangentCandidates(for: layer)
        popUp.removeAllItems()
        popUp.addItem(withTitle: L("None"))
        popUp.menu?.addItem(.separator())
        for source in sources { popUp.addItem(withTitle: source.name) }
        if let id = layer.sourceA, let index = sources.firstIndex(where: { $0.id == id }) {
            popUp.selectItem(at: index + 2)
        } else {
            popUp.selectItem(at: 0)
        }
        for (field, value) in [(anchorUField, layer.anchorU), (anchorVField, layer.anchorV)] {
            if let field, field.currentEditor() == nil { field.stringValue = ControlFactory.format(value) }
        }
        normalCheckbox?.state = layer.drawsNormal ? .on : .off

        // 读数：切点、斜率 / 法向。
        func p2(_ v: SIMD2<Double>) -> String { "(\(ControlFactory.format(v.x)), \(ControlFactory.format(v.y)))" }
        func p3(_ v: SIMD3<Double>) -> String {
            "(\(ControlFactory.format(v.x)), \(ControlFactory.format(v.y)), \(ControlFactory.format(v.z)))"
        }
        let all = state.compiler.compile(state.document)
        let source = all.first { $0.layer.id == layer.sourceA }
        var text = L("Pick a source layer.")
        if let source {
            if layer.kind == .tangent {
                if let t = Tangents.tangent(of: source, at: layer.anchorU) {
                    let slope = t.slope.map { "\(L("slope")) \(ControlFactory.format($0))" } ?? L("vertical tangent")
                    text = "\(L("Point")) \(p2(t.point))  ·  \(slope)"
                } else {
                    text = L("The curve has no tangent at this position.")
                }
            } else if let plane = Tangents.tangentPlane(of: source, u: layer.anchorU, v: layer.anchorV) {
                text = "\(L("Point")) \(p3(plane.point))\n\(L("Normal")) \(p3(plane.normal))"
            } else {
                text = L("The surface has no tangent plane at this position.")
            }
        }
        tangentReadout?.stringValue = text
    }

    @objc private func tangentSourceEdited(_ sender: NSPopUpButton) {
        guard let layer = state.selectedLayer else { return }
        let sources = tangentCandidates(for: layer)
        let index = sender.indexOfSelectedItem
        let id = index >= 2 && index - 2 < sources.count ? sources[index - 2].id : nil
        editLayer(L("Change Tangent")) { $0.sourceA = id }
    }

    @objc private func anchorEdited(_ sender: NSTextField) {
        guard let layer = state.selectedLayer else { return }
        let u = ControlFactory.parse(anchorUField?.stringValue ?? "") ?? layer.anchorU
        let v = ControlFactory.parse(anchorVField?.stringValue ?? "") ?? layer.anchorV
        editLayer(L("Change Tangent")) {
            $0.anchorU = u
            $0.anchorV = v
        }
    }

    @objc private func normalToggled(_ sender: NSButton) {
        let on = sender.state == .on
        editLayer(L("Change Tangent")) { $0.drawsNormal = on }
    }

    // MARK: - Projection rows

    private var projectableLayers: [Layer] { state.document.layers.filter { $0.kind.isProjectable } }

    /// 能当投影目标的平面图层（线性的隐式 / 显式曲面）。
    private var planeLayers: [Layer] {
        let all = state.compiler.compile(state.document)
        return all.compactMap { compiled in
            if case .plane? = SpaceGeometry.recognize(compiled, in: all) { return compiled.layer }
            return nil
        }
    }

    private func refreshProjection(_ layer: Layer) {
        guard let source = projectionSourcePopUp, let target = projectionTargetPopUp else { return }
        let sources = projectableLayers
        source.removeAllItems()
        source.addItem(withTitle: L("None"))
        source.menu?.addItem(.separator())
        for candidate in sources { source.addItem(withTitle: candidate.name) }
        if let id = layer.sourceA, let index = sources.firstIndex(where: { $0.id == id }) {
            source.selectItem(at: index + 2)
        } else {
            source.selectItem(at: 0)
        }

        let planes = planeLayers
        target.removeAllItems()
        for kind in [ProjectionTarget.xy, .yz, .xz] { target.addItem(withTitle: kind.displayName) }
        for plane in planes { target.addItem(withTitle: "\(L("Plane")): \(plane.name)") }
        if layer.projectionTarget != .plane {
            target.selectItem(at: [ProjectionTarget.xy, .yz, .xz].firstIndex(of: layer.projectionTarget) ?? 0)
        } else if let id = layer.sourceB, let index = planes.firstIndex(where: { $0.id == id }) {
            target.selectItem(at: 3 + index)
        } else {
            target.selectItem(at: -1)
        }

        projectionOffsetRow?.isHidden = layer.projectionTarget == .plane
        if let field = projectionOffsetField, field.currentEditor() == nil {
            field.stringValue = ControlFactory.format(layer.projectionOffset)
        }
        projectorsCheckbox?.state = layer.showsProjectors ? .on : .off
        obliqueCheckbox?.state = layer.projectionDirection != nil ? .on : .off
        directionRowView?.isHidden = layer.projectionDirection == nil
        if let direction = layer.projectionDirection {
            for (index, field) in directionFields.enumerated() where field.currentEditor() == nil {
                field.stringValue = ControlFactory.format(direction[index])
            }
        }
    }

    @objc private func obliqueToggled(_ sender: NSButton) {
        let on = sender.state == .on
        editLayer(L("Change Projection")) { $0.projectionDirection = on ? ($0.projectionDirection ?? SIMD3(1, 1, 1)) : nil }
    }

    @objc private func directionEdited(_ sender: NSTextField) {
        guard let layer = state.selectedLayer else { return }
        var direction = layer.projectionDirection ?? SIMD3(1, 1, 1)
        for (index, field) in directionFields.enumerated() {
            direction[index] = ControlFactory.parse(field.stringValue) ?? direction[index]
        }
        // 全零没有方向：当作没改。
        guard simd_length(direction) > 1e-9 else { return refreshProjection(layer) }
        editLayer(L("Change Projection")) { $0.projectionDirection = direction }
    }

    @objc private func projectionSourceEdited(_ sender: NSPopUpButton) {
        let sources = projectableLayers
        let index = sender.indexOfSelectedItem
        let id = index >= 2 && index - 2 < sources.count ? sources[index - 2].id : nil
        editLayer(L("Change Projection")) { $0.sourceA = id }
    }

    @objc private func projectionTargetEdited(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        let coordinate: [ProjectionTarget] = [.xy, .yz, .xz]
        if index >= 0, index < coordinate.count {
            let kind = coordinate[index]
            editLayer(L("Change Projection")) { $0.projectionTarget = kind }
            return
        }
        let planes = planeLayers
        guard index - 3 >= 0, index - 3 < planes.count else { return }
        let id = planes[index - 3].id
        editLayer(L("Change Projection")) {
            $0.projectionTarget = .plane
            $0.sourceB = id
        }
    }

    @objc private func projectionOffsetEdited(_ sender: NSTextField) {
        guard let layer = state.selectedLayer else { return }
        let value = ControlFactory.parse(sender.stringValue) ?? layer.projectionOffset
        editLayer(L("Change Projection")) { $0.projectionOffset = value }
    }

    @objc private func projectorsToggled(_ sender: NSButton) {
        let on = sender.state == .on
        editLayer(L("Change Projection")) { $0.showsProjectors = on }
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
        tertiaryField = nil
        domainCheckbox = nil
        domainGroup = nil
        domainLowerField = nil
        domainUpperField = nil
        domain2LowerField = nil
        domain2UpperField = nil
        extrudeCheckbox = nil
        sourceAPopUp = nil
        sourceBPopUp = nil
        sourceHint = nil
        projectionSourcePopUp = nil
        projectionTargetPopUp = nil
        projectionOffsetField = nil
        projectionOffsetRow = nil
        projectorsCheckbox = nil
        labelCheckbox = nil
        obliqueCheckbox = nil
        directionFields = []
        directionRowView = nil
        textContentField = nil
        textPositionFields = []
        fontSizeField = nil
        tangentSourcePopUp = nil
        anchorUField = nil
        anchorVField = nil
        normalCheckbox = nil
        tangentReadout = nil
        relationPopUp = nil
        lineColorWell = nil
        lineWidthSlider = nil
        lineWidthLabel = nil
        fillCheckbox = nil
        fillColorWell = nil
        fillOpacitySlider = nil
        fillOpacityLabel = nil
    }

    /// 当前文档能用的图型：平面图只有 2D 的五种，立体图只有 3D 的四种。
    private var availableKinds: [PlotKind] { PlotKind.cases(for: state.document.dimension) }

    // MARK: - Formula rows

    /// 一个图层最多三个公式：主公式、第二个（参数方程的 y）、第三个（立体图型的 z）。
    private enum FormulaSlot {
        case primary, secondary, tertiary

        func write(_ text: String, into layer: inout Layer) {
            switch self {
            case .primary: layer.formula = text
            case .secondary: layer.secondaryFormula = text
            case .tertiary: layer.tertiaryFormula = text
            }
        }
    }

    /// 每种图型的公式栏：标题与所在槽位。
    private func formulaTitles(_ kind: PlotKind) -> [(title: String, slot: FormulaSlot)] {
        switch kind {
        case .explicit: return [(L("Formula y = f(x)"), .primary)]
        case .parametric: return [("x(t) =", .primary), ("y(t) =", .secondary)]
        case .polar: return [("r(θ) =", .primary)]
        case .implicit: return [(L("F(x, y) = 0 — enter F here"), .primary)]
        case .region: return [(L("F(x, y) compared with 0"), .primary)]
        case .surface: return [(L("Formula z = f(x, y)"), .primary)]
        case .parametricSurface:
            return [("x(u, v) =", .primary), ("y(u, v) =", .secondary), ("z(u, v) =", .tertiary)]
        case .spaceCurve: return [("x(t) =", .primary), ("y(t) =", .secondary), ("z(t) =", .tertiary)]
        case .implicitSurface: return [(L("F(x, y, z) = 0 — enter F here"), .primary)]
        case .surfaceIntersection, .projection, .tangent, .tangentPlane, .text: return []
        case .point: return [("x =", .primary), ("y =", .secondary), ("z =", .tertiary)]
        }
    }

    private func formulaRows(_ layer: Layer) -> [NSView] {
        formulaTitles(layer.kind).map { title, slot in
            let placeholder: String
            switch slot {
            case .primary: placeholder = layer.kind.primaryPlaceholder
            case .secondary: placeholder = layer.kind.secondaryPlaceholder
            case .tertiary: placeholder = layer.kind.tertiaryPlaceholder
            }
            let field = makeFormulaField(title: title, placeholder: placeholder, layerID: layer.id, slot: slot)
            switch slot {
            case .primary: primaryField = field
            case .secondary: secondaryField = field
            case .tertiary: tertiaryField = field
            }
            return field
        }
    }

    private func makeFormulaField(
        title: String,
        placeholder: String,
        layerID: UUID,
        slot: FormulaSlot
    ) -> FormulaFieldView {
        let field = FormulaFieldView(title: title, placeholder: placeholder)
        field.onLiveChange = { [weak self] text in
            guard let self else { return }
            self.state.beginLiveEdit()
            self.state.updateLayerLive(id: layerID) { layer in slot.write(text, into: &layer) }
        }
        field.onCommit = { [weak self] text in
            guard let self else { return }
            self.state.updateLayerLive(id: layerID) { layer in slot.write(text, into: &layer) }
            self.state.commitLiveEdit(L("Edit Formula"))
        }
        return field
    }

    // MARK: - Domain rows

    /// 参数范围的快捷按钮。按钮的 `tag` = 第几个范围 × 10 + 这个枚举的值。
    private enum DomainPreset: Int {
        case fullTurn = 0, halfTurn = 1, visible = 2

        var title: String {
            switch self {
            case .fullTurn: return "0…2π"
            case .halfTurn: return "0…π"
            case .visible: return L("Visible Range")
            }
        }
    }

    /// 一个参数范围：「x [  ] 到 [  ]」加一排快捷按钮。`second` 是参数曲面的 v。
    private func domainGroup(_ layer: Layer, second: Bool) -> NSStackView {
        let action = second ? #selector(domain2Edited(_:)) : #selector(domainEdited(_:))
        let lower = ControlFactory.numberField(second ? layer.domain2Lower : layer.domainLower, target: self, action: action)
        let upper = ControlFactory.numberField(second ? layer.domain2Upper : layer.domainUpper, target: self, action: action)
        lower.setContentHuggingPriority(.defaultLow, for: .horizontal)
        upper.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if second {
            domain2LowerField = lower
            domain2UpperField = upper
        } else {
            domainLowerField = lower
            domainUpperField = upper
        }

        let dash = ControlFactory.label(L("to"))
        dash.setContentHuggingPriority(.required, for: .horizontal)
        dash.setContentCompressionResistancePriority(.required, for: .horizontal)
        let bounds = ControlFactory.stack(
            [lower, dash, upper],
            orientation: .horizontal,
            spacing: 6,
            alignment: .firstBaseline
        )
        lower.widthAnchor.constraint(equalTo: upper.widthAnchor).isActive = true

        let presets: [DomainPreset]
        switch layer.kind {
        case .explicit: presets = [.fullTurn, .visible]
        case .parametricSurface: presets = second ? [.halfTurn, .fullTurn] : [.fullTurn]
        default: presets = [.fullTurn]
        }
        let buttons = presets.map { preset -> NSButton in
            let button = ControlFactory.pushButton(preset.title, target: self, action: #selector(domainPreset(_:)))
            button.tag = (second ? 10 : 0) + preset.rawValue
            return button
        }
        let shortcuts = ControlFactory.stack(buttons, orientation: .horizontal, spacing: 6, alignment: .centerY)

        let symbol = second ? "v" : domainSymbol(layer.kind)
        return ControlFactory.stack(
            [
                ControlFactory.formRow(symbol, bounds),
                ControlFactory.formRow("", shortcuts),
            ],
            spacing: ControlFactory.Metric.rowSpacing
        )
    }

    private func domainSymbol(_ kind: PlotKind) -> String {
        switch kind {
        case .polar: return "θ"
        case .parametric, .spaceCurve: return "t"
        case .parametricSurface: return "u"
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
        return [ControlFactory.formRow(L("Color"), well), ControlFactory.formRow(L("Width"), width)]
    }

    /// 不透明度滑块（区域的填充、曲面共用同一个字段 `fillStyle.opacity`）。
    private func opacityControl(_ layer: Layer) -> NSView {
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
        return ControlFactory.stack([slider, value], orientation: .horizontal, spacing: 6, alignment: .centerY)
    }

    private func fillRows(_ layer: Layer) -> [NSView] {
        let checkbox = ControlFactory.checkbox(L("Fill region"), target: self, action: #selector(fillToggled(_:)))
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
            ControlFactory.formRow(L("Color"), well),
            ControlFactory.formRow(L("Opacity"), opacity),
        ]
    }

    // MARK: - Actions

    @objc private func nameEdited(_ sender: NSTextField) {
        let name = sender.stringValue
        editLayerList(L("Rename")) { $0.name = name }
    }

    @objc private func kindEdited(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        let kinds = availableKinds
        guard index >= 0, index < kinds.count else { return }
        let kind = kinds[index]
        editLayer(L("Change Type")) { $0.kind = kind }
    }

    @objc private func domainToggled(_ sender: NSButton) {
        let on = sender.state == .on
        editLayer(L("Change Domain")) { $0.usesExplicitDomain = on }
    }

    @objc private func domainEdited(_ sender: NSTextField) {
        guard let layer = state.selectedLayer else { return }
        let lower = ControlFactory.parse(domainLowerField?.stringValue ?? "") ?? layer.domainLower
        let upper = ControlFactory.parse(domainUpperField?.stringValue ?? "") ?? layer.domainUpper
        setDomain(lower: lower, upper: upper)
    }

    @objc private func domain2Edited(_ sender: NSTextField) {
        guard let layer = state.selectedLayer else { return }
        let lower = ControlFactory.parse(domain2LowerField?.stringValue ?? "") ?? layer.domain2Lower
        let upper = ControlFactory.parse(domain2UpperField?.stringValue ?? "") ?? layer.domain2Upper
        setDomain(lower: lower, upper: upper, second: true)
    }

    @objc private func domainPreset(_ sender: NSButton) {
        guard let preset = DomainPreset(rawValue: sender.tag % 10) else { return }
        let second = sender.tag >= 10
        switch preset {
        case .fullTurn: setDomain(lower: 0, upper: 2 * Double.pi, second: second)
        case .halfTurn: setDomain(lower: 0, upper: Double.pi, second: second)
        case .visible:
            // 平面图取可见区的 x 范围，立体图取坐标盒的 x 范围。
            let range = state.document.dimension == .space
                ? state.document.view3D.range(axis: 0)
                : state.viewport.unobscured.xRange
            setDomain(lower: range.lowerBound, upper: range.upperBound, second: second)
        }
    }

    @objc private func extrudeToggled(_ sender: NSButton) {
        let on = sender.state == .on
        editLayer(L("Extend into 3D")) { $0.extrudesInSpace = on }
    }

    @objc private func sourceAEdited(_ sender: NSPopUpButton) {
        let id = sourceID(at: sender.indexOfSelectedItem)
        editLayer(L("Change Surface")) { $0.sourceA = id }
    }

    @objc private func sourceBEdited(_ sender: NSPopUpButton) {
        let id = sourceID(at: sender.indexOfSelectedItem)
        editLayer(L("Change Surface")) { $0.sourceB = id }
    }

    /// 菜单序号 → 图层 id；0 是「无」，1 是分隔线。
    private func sourceID(at index: Int) -> UUID? {
        let candidates = sourceCandidates
        guard index >= 2, index - 2 < candidates.count else { return nil }
        return candidates[index - 2].id
    }

    @objc private func labelToggled(_ sender: NSButton) {
        let on = sender.state == .on
        editLayer(L("Show name")) { $0.showsLabel = on }
    }

    @objc private func relationEdited(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < RegionRelation.allCases.count else { return }
        let relation = RegionRelation.allCases[index]
        editLayer(L("Change Relation")) { $0.relation = relation }
    }

    @objc private func lineColorEdited(_ sender: NSColorWell) {
        let color = ControlFactory.rgbaColor(sender.color)
        editLayer(L("Change Color")) { $0.lineStyle.color = color }
    }

    @objc private func lineWidthEdited(_ sender: NSSlider) {
        let width = sender.doubleValue
        liveEdit(L("Change Line Width")) { $0.lineStyle.width = width }
        lineWidthLabel?.stringValue = ControlFactory.format(width)
    }

    @objc private func fillToggled(_ sender: NSButton) {
        let on = sender.state == .on
        editLayer(L("Change Fill")) { $0.fillStyle.isFilled = on }
    }

    @objc private func fillColorEdited(_ sender: NSColorWell) {
        let color = ControlFactory.rgbaColor(sender.color)
        editLayer(L("Change Fill Color")) { $0.fillStyle.color = color }
    }

    @objc private func fillOpacityEdited(_ sender: NSSlider) {
        let opacity = sender.doubleValue
        liveEdit(L("Change Fill")) { $0.fillStyle.opacity = opacity }
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

    private func setDomain(lower: Double, upper: Double, second: Bool = false) {
        guard let id = state.selectedLayer?.id else { return }
        state.mutate(L("Change Domain")) { document in
            guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
            if second {
                document.layers[index].domain2Lower = lower
                document.layers[index].domain2Upper = upper
            } else {
                document.layers[index].domainLower = lower
                document.layers[index].domainUpper = upper
            }
        }
    }
}
