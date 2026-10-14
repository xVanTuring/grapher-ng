import AppKit
import GrapherKit
import simd

/// 立体图专用：选两个点 / 直线 / 平面，算它们的位置关系、距离、夹角，并可把垂足、交点、交线、公垂线画出来。
/// 点、直线、平面不是单独的图型，而是从图层里认出来的（`SpaceGeometry.recognize`）：
/// 点图层、线性的空间曲线、线性的隐式 / 显式曲面。
final class RelationPaneViewController: NSViewController {

    let state: AppState

    private let container = NSStackView()
    private var firstPopUp: NSPopUpButton?
    private var secondPopUp: NSPopUpButton?
    private let resultStack = ControlFactory.stack([], spacing: 4)
    private var drawButton: NSButton?
    private var candidates: [(layer: Layer, object: SpaceObject)] = []
    private var firstID: UUID?
    private var secondID: UUID?
    private var currentRelation: GeometryRelation?
    private var observerID: UUID?

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RelationPaneViewController is created in code only")
    }

    deinit {
        if let observerID { MainActor.assumeIsolated { state.removeObserver(observerID) } }
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
        let first = ControlFactory.popUp(items: [], target: self, action: #selector(firstChanged(_:)))
        let second = ControlFactory.popUp(items: [], target: self, action: #selector(secondChanged(_:)))
        firstPopUp = first
        secondPopUp = second
        let draw = ControlFactory.pushButton(L("Draw Results"), target: self, action: #selector(drawResults(_:)))
        draw.toolTip = L("Add the foot of the perpendicular, intersection point, common perpendicular or line of intersection as new layers.")
        drawButton = draw

        let rows: [NSView] = [
            ControlFactory.separator(),
            ControlFactory.heading(L("Relations")),
            ControlFactory.formRow(L("Object A"), first),
            ControlFactory.formRow(L("Object B"), second),
            resultStack,
            draw,
        ]
        for row in rows {
            container.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }
        observerID = state.observe([.layers, .document, .parameters]) { [weak self] _ in self?.reload() }
        reload()
    }

    // MARK: - Refresh

    func reload() {
        let isSpace = state.document.dimension == .space
        view.isHidden = !isSpace
        guard isSpace, firstPopUp != nil else { return }

        candidates = state.compiler.compile(state.document).compactMap { compiled in
            SpaceGeometry.recognize(compiled).map { (compiled.layer, $0) }
        }
        let ids = candidates.map(\.layer.id)
        if firstID == nil || !ids.contains(firstID!) { firstID = ids.first }
        if secondID == nil || !ids.contains(secondID!) || secondID == firstID {
            secondID = ids.first { $0 != firstID }
        }
        fill(firstPopUp, selected: firstID)
        fill(secondPopUp, selected: secondID)
        showResult()
    }

    private func fill(_ popUp: NSPopUpButton?, selected: UUID?) {
        guard let popUp else { return }
        popUp.removeAllItems()
        if candidates.isEmpty {
            popUp.addItem(withTitle: L("None"))
            popUp.isEnabled = false
            return
        }
        popUp.isEnabled = true
        for candidate in candidates {
            popUp.addItem(withTitle: "\(candidate.layer.name) (\(candidate.object.kindName))")
        }
        if let selected, let index = candidates.firstIndex(where: { $0.layer.id == selected }) {
            popUp.selectItem(at: index)
        }
    }

    private func showResult() {
        for view in resultStack.arrangedSubviews {
            resultStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        currentRelation = nil
        func add(_ view: NSView) {
            resultStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: resultStack.widthAnchor).isActive = true
        }

        guard let a = candidates.first(where: { $0.layer.id == firstID }),
              let b = candidates.first(where: { $0.layer.id == secondID }) else {
            add(ControlFactory.caption(L("Pick two of: a point, a straight line (a linear space curve), a plane (a linear surface).")))
            drawButton?.isEnabled = false
            return
        }
        let relation = SpaceGeometry.relation(a.object, b.object)
        currentRelation = relation
        add(ControlFactory.heading(relation.summary))
        for measure in relation.measures {
            let value = measure.isAngle ? "\(ControlFactory.format(measure.value))°" : ControlFactory.format(measure.value)
            let line = ControlFactory.monospacedLabel("\(measure.name)  \(value)")
            line.isSelectable = true
            add(line)
        }
        for construction in relation.constructions {
            let line = ControlFactory.monospacedLabel("\(construction.name)  \(describe(construction))")
            line.isSelectable = true
            add(line)
        }
        drawButton?.isEnabled = !relation.constructions.isEmpty
    }

    private func describe(_ construction: GeometryConstruction) -> String {
        func p(_ v: SIMD3<Double>) -> String {
            "(\(ControlFactory.format(v.x)), \(ControlFactory.format(v.y)), \(ControlFactory.format(v.z)))"
        }
        switch construction {
        case .point(let point, _): return p(point)
        case .segment(let a, let b, _): return "\(p(a)) → \(p(b))"
        case .line(let origin, let direction, _): return "\(p(origin)) + t·\(p(direction))"
        }
    }

    // MARK: - Actions

    @objc private func firstChanged(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < candidates.count else { return }
        firstID = candidates[sender.indexOfSelectedItem].layer.id
        showResult()
    }

    @objc private func secondChanged(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < candidates.count else { return }
        secondID = candidates[sender.indexOfSelectedItem].layer.id
        showResult()
    }

    /// 把结果里的辅助对象加成新图层（一次撤销一整批）。
    @objc private func drawResults(_ sender: NSButton) {
        guard let relation = currentRelation, !relation.constructions.isEmpty else { return }
        let box = state.document.view3D
        let base = state.document.layers.count
        var created: [Layer] = []
        for (offset, construction) in relation.constructions.enumerated() {
            let reach = simd_length(construction.reference - box.center) + 2 * 3.0.squareRoot() * box.halfExtent
            created.append(construction.makeLayer(index: base + offset, lineExtent: reach))
        }
        let last = created.last?.id
        state.mutateLayers(L("Add Construction")) { $0.layers.append(contentsOf: created) }
        if let last { state.selection = last }
    }
}

private extension GeometryConstruction {
    /// 用来估直线要画多长的参考点。
    var reference: SIMD3<Double> {
        switch self {
        case .point(let p, _): return p
        case .segment(let a, _, _): return a
        case .line(let origin, _, _): return origin
        }
    }
}
