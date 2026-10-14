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
        tooltip: L("New Parameter"),
        accessibility: L("New Parameter")
    )

    /// 播放设置：扫满一次要多久、到头之后怎么办。拉下菜单里勾选。
    private lazy var optionsButton: NSPopUpButton = {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.controlSize = .small
        button.isBordered = false
        button.toolTip = L("Playback options")
        let menu = NSMenu()
        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: L("Playback options"))
        menu.addItem(title)
        for (name, seconds) in [(L("Slow"), 12.0), (L("Medium"), 6.0), (L("Fast"), 3.0)] {
            let item = NSMenuItem(title: name, action: #selector(speedChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(seconds)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (name, mode) in [(L("Back and forth"), PlaybackMode.pingPong), (L("Repeat"), .loop)] {
            let item = NSMenuItem(title: name, action: #selector(modeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            menu.addItem(item)
        }
        menu.delegate = self
        button.menu = menu
        return button
    }()

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

        let title = ControlFactory.sectionLabel(L("Parameters"))
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let header = ControlFactory.stack(
            [title, spacer, optionsButton, addButton],
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
        observerID = state.observe([.parameters, .layers, .document, .playback]) { [weak self] change in
            if change == .playback {
                self?.syncPlayback()
            } else {
                self?.reload()
            }
        }
        reload()
    }

    /// 播放期间每帧：滑块和读数跟着状态里的值走，播放按钮显示播放 / 暂停。不重建行。
    private func syncPlayback() {
        let parameters = Dictionary(uniqueKeysWithValues: state.document.parameters.map { ($0.id, $0) })
        for case let row as ParameterRowView in rows.arrangedSubviews {
            guard let parameter = parameters[row.parameterID] else { continue }
            row.setValue(parameter.value)
            row.setPlaying(state.isPlaying(parameter.id))
        }
    }

    @objc private func speedChosen(_ sender: NSMenuItem) {
        state.playbackSweepSeconds = Double(sender.tag)
    }

    @objc private func modeChosen(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = PlaybackMode(rawValue: raw) {
            state.playbackMode = mode
        }
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
                L("No parameters yet. Add one, write a*sin(x) in a formula, and drag the slider to watch the graph change live.")
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
        row.onPlay = { [weak self] in self?.state.togglePlayback(id: parameter.id) }
        row.setPlaying(state.isPlaying(parameter.id))
        row.onDragBegin = { [weak self] in self?.state.beginLiveEdit() }
        row.onValueChange = { [weak self] value in self?.state.updateParameter(id: parameter.id, value: value) }
        row.onDragEnd = { [weak self] in self?.state.commitLiveEdit(L("Change Parameter")) }
        return row
    }

    @objc private func addParameter(_ sender: Any?) {
        state.addParameter()
    }
}

extension ParameterPanelViewController: NSMenuDelegate {
    /// 拉下菜单时把当前的速度、方式打上勾。
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if item.action == #selector(speedChosen(_:)) {
                item.state = Double(item.tag) == state.playbackSweepSeconds ? .on : .off
            } else if item.action == #selector(modeChosen(_:)) {
                item.state = (item.representedObject as? String) == state.playbackMode.rawValue ? .on : .off
            }
        }
    }
}

/// One parameter: its name, its current value, a play button, a delete button and the slider.
private final class ParameterRowView: NSView {

    var onRename: ((String) -> Void)?
    var onRemove: (() -> Void)?
    var onPlay: (() -> Void)?
    let parameterID: UUID
    private let playButton = ControlFactory.symbolButton(
        symbol: "play.fill",
        target: nil,
        action: #selector(playClicked(_:)),
        tooltip: L("Play"),
        accessibility: L("Play")
    )
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
        tooltip: L("Delete Parameter"),
        accessibility: L("Delete Parameter")
    )
    private var isDragging = false
    private var currentName: String

    init(parameter: ParameterDefinition) {
        parameterID = parameter.id
        currentName = parameter.name
        nameField = ControlFactory.textField(parameter.name, placeholder: L("Name"), monospaced: true)
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
        playButton.target = self

        build()
    }

    /// 播放时外面把新值推进来（拖动滑块时不动它，免得和手抢）。
    func setValue(_ value: Double) {
        guard !isDragging else { return }
        slider.doubleValue = value
        valueLabel.stringValue = Self.formatValue(value)
    }

    func setPlaying(_ playing: Bool) {
        let symbol = playing ? "pause.fill" : "play.fill"
        let title = playing ? L("Pause") : L("Play")
        playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        playButton.toolTip = title
    }

    @objc private func playClicked(_ sender: Any?) {
        onPlay?()
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
        for subview in [nameField, equalsLabel, valueLabel, playButton, removeButton, slider] as [NSView] {
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
            playButton.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -4),
            playButton.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: playButton.leadingAnchor, constant: -6),

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
