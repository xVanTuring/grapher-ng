import AppKit
import GrapherKit

/// Axes, grid and theme switches, plus a read-out of the visible range.
final class ViewSettingsViewController: NSViewController {

    let state: AppState

    private let container = NSStackView()
    private var axesCheckbox: NSButton?
    private var gridCheckbox: NSButton?
    private var minorGridCheckbox: NSButton?
    private var themeCheckbox: NSButton?
    private var xRangeLabel: NSTextField?
    private var yRangeLabel: NSTextField?
    private var observerID: UUID?

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ViewSettingsViewController is created in code only")
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

        let axes = ControlFactory.checkbox("坐标轴", target: self, action: #selector(axesToggled(_:)))
        let grid = ControlFactory.checkbox("网格", target: self, action: #selector(gridToggled(_:)))
        let minorGrid = ControlFactory.checkbox("细分网格", target: self, action: #selector(minorGridToggled(_:)))
        let theme = ControlFactory.checkbox("暗色主题", target: self, action: #selector(themeToggled(_:)))
        axesCheckbox = axes
        gridCheckbox = grid
        minorGridCheckbox = minorGrid
        themeCheckbox = theme

        let xRange = ControlFactory.monospacedLabel("")
        let yRange = ControlFactory.monospacedLabel("")
        xRangeLabel = xRange
        yRangeLabel = yRange

        let switches = ControlFactory.stack([axes, grid, minorGrid, theme], spacing: ControlFactory.Metric.rowSpacing)
        let ranges = ControlFactory.stack([xRange, yRange], spacing: 2)
        add(ControlFactory.heading("视图"))
        add(switches)
        add(ranges)

        refresh()
        observerID = state.observe([.document, .viewport]) { [weak self] _ in
            self?.refresh()
        }
    }

    private func add(_ row: NSView) {
        container.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
    }

    private func refresh() {
        axesCheckbox?.state = state.document.showAxes ? .on : .off
        gridCheckbox?.state = state.document.showGrid ? .on : .off
        minorGridCheckbox?.state = state.document.showMinorGrid ? .on : .off
        themeCheckbox?.state = state.document.theme.background.r < 0.5 ? .on : .off

        let viewport = state.viewport
        xRangeLabel?.stringValue = rangeText("X", viewport.xRange)
        yRangeLabel?.stringValue = rangeText("Y", viewport.yRange)
    }

    private func rangeText(_ name: String, _ range: ClosedRange<Double>) -> String {
        "\(name): \(String(format: "%.4g", range.lowerBound)) … \(String(format: "%.4g", range.upperBound))"
    }

    // MARK: - Actions

    @objc private func axesToggled(_ sender: NSButton) {
        let on = sender.state == .on
        state.mutate("显示坐标轴") { $0.showAxes = on }
    }

    @objc private func gridToggled(_ sender: NSButton) {
        let on = sender.state == .on
        state.mutate("显示网格") { $0.showGrid = on }
    }

    @objc private func minorGridToggled(_ sender: NSButton) {
        let on = sender.state == .on
        state.mutate("显示细分网格") { $0.showMinorGrid = on }
    }

    @objc private func themeToggled(_ sender: NSButton) {
        let isDark = sender.state == .on
        state.mutate("切换主题") { $0.theme = isDark ? .dark : .light }
    }
}
