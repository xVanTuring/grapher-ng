import AppKit
import GrapherKit

/// The left column's lower half: one slider per document parameter.
final class ParameterPanelViewController: NSViewController {

    let state: AppState

    private let rows = NSStackView()
    private var observerID: UUID?
    private var layoutSignature: [String]?

    private lazy var addButton = ControlFactory.symbolButton(
        symbol: "plus",
        target: self,
        action: #selector(addParameter(_:)),
        tooltip: "新建参数",
        accessibility: "新建参数"
    )

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ParameterPanelViewController is created in code only")
    }

    deinit {
        if let observerID { MainActor.assumeIsolated { state.removeObserver(observerID) } }
    }

    override func loadView() {
        let root = FlippedView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = ControlFactory.sectionLabel("参数")
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let header = ControlFactory.stack(
            [title, spacer, addButton],
            orientation: .horizontal,
            spacing: 8,
            alignment: .centerY
        )
        root.addSubview(header)

        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = ControlFactory.Metric.rowSpacing

        let scroll = ControlFactory.scrolling(rows)
        root.addSubview(scroll)

        let gutter = ControlFactory.Metric.gutter
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gutter),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gutter),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: ControlFactory.Metric.rowSpacing),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observerID = state.observe([.parameters, .layers, .document]) { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    // MARK: - Building

    /// Rebuilding tears the sliders down, so it only happens when the set of
    /// parameters, their names or their bounds changed — not when a slider is
    /// being dragged or a formula is being typed elsewhere.
    private func reload() {
        let parameters = state.document.parameters
        let signature = parameters.map { "\($0.id)|\($0.name)|\($0.lowerBound)|\($0.upperBound)" }
        guard signature != layoutSignature else { return }
        layoutSignature = signature

        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !parameters.isEmpty else {
            rows.addArrangedSubview(ControlFactory.caption(
                "还没有参数。新建后可以在公式里写 a*sin(x)，拖动滑块看图形实时变化。"
            ))
            return
        }
        for parameter in parameters {
            rows.addArrangedSubview(makeRow(for: parameter))
        }
    }

    private func makeRow(for parameter: ParameterDefinition) -> ParameterRowView {
        let row = ParameterRowView(parameter: parameter)
        row.onRename = { [weak self] name in
            guard let self, name != parameter.name else { return }
            self.state.renameParameter(id: parameter.id, to: name)
        }
        row.onRemove = { [weak self] in self?.state.removeParameter(id: parameter.id) }
        row.onDragBegin = { [weak self] in self?.state.beginLiveEdit() }
        row.onValueChange = { [weak self] value in self?.state.updateParameter(id: parameter.id, value: value) }
        row.onDragEnd = { [weak self] in self?.state.commitLiveEdit("修改参数") }
        return row
    }

    @objc private func addParameter(_ sender: Any?) {
        state.addParameter()
    }
}

/// One parameter: its name, its current value, a delete button and the slider.
private final class ParameterRowView: NSView {

    var onRename: ((String) -> Void)?
    var onRemove: (() -> Void)?
    var onValueChange: ((Double) -> Void)?
    var onDragBegin: (() -> Void)?
    var onDragEnd: (() -> Void)?

    private let nameField: NSTextField
    private let equalsLabel = ControlFactory.monospacedLabel("=")
    private let valueLabel = ControlFactory.monospacedLabel("")
    private let slider: NSSlider
    private let removeButton = ControlFactory.symbolButton(
        symbol: "trash",
        target: nil,
        action: #selector(removeClicked(_:)),
        tooltip: "删除参数",
        accessibility: "删除参数"
    )
    private var isDragging = false
    private var currentName: String

    init(parameter: ParameterDefinition) {
        currentName = parameter.name
        nameField = ControlFactory.textField(parameter.name, placeholder: "名称", monospaced: true)
        let lower = min(parameter.lowerBound, parameter.upperBound)
        let upper = max(parameter.lowerBound, parameter.upperBound)
        slider = ControlFactory.slider(
            value: parameter.value,
            range: lower...upper,
            target: nil,
            action: #selector(sliderMoved(_:))
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        nameField.target = self
        nameField.action = #selector(commitName(_:))
        nameField.delegate = self
        valueLabel.stringValue = Self.formatValue(parameter.value)
        slider.target = self
        removeButton.target = self

        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ParameterRowView is created in code only")
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        // A slider drag is one undo step: open it on the first value the drag
        // produces, close it on the mouse-up that ends the drag.
        if !isDragging {
            isDragging = true
            onDragBegin?()
        }
        valueLabel.stringValue = Self.formatValue(sender.doubleValue)
        onValueChange?(sender.doubleValue)
        if NSApp.currentEvent?.type == .leftMouseUp {
            isDragging = false
            onDragEnd?()
        }
    }

    @objc private func commitName(_ sender: Any?) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            nameField.stringValue = currentName
            return
        }
        nameField.stringValue = name
        guard name != currentName else { return }
        currentName = name
        onRename?(name)
    }

    @objc private func removeClicked(_ sender: Any?) {
        onRemove?()
    }

    private static func formatValue(_ value: Double) -> String {
        value.isFinite ? String(format: "%.4g", value) : "—"
    }

    private func build() {
        for subview in [nameField, equalsLabel, valueLabel, removeButton, slider] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            nameField.topAnchor.constraint(equalTo: topAnchor),
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameField.widthAnchor.constraint(equalToConstant: 54),
            nameField.heightAnchor.constraint(equalToConstant: ControlFactory.Metric.fieldHeight),

            equalsLabel.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 6),
            equalsLabel.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),

            valueLabel.leadingAnchor.constraint(equalTo: equalsLabel.trailingAnchor, constant: 6),
            valueLabel.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),

            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            removeButton.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor, constant: -6),

            slider.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 2),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

extension ParameterRowView: NSTextFieldDelegate {

    func controlTextDidEndEditing(_ obj: Notification) {
        commitName(obj.object)
    }
}
