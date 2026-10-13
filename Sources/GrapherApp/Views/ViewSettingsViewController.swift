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
    private var zRangeLabel: NSTextField?
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

        let axes = ControlFactory.checkbox(L("Axes"), target: self, action: #selector(axesToggled(_:)))
        let grid = ControlFactory.checkbox(L("Grid"), target: self, action: #selector(gridToggled(_:)))
        let minorGrid = ControlFactory.checkbox(L("Minor grid"), target: self, action: #selector(minorGridToggled(_:)))
        let theme = ControlFactory.checkbox(L("Dark theme"), target: self, action: #selector(themeToggled(_:)))
        axesCheckbox = axes
        gridCheckbox = grid
        minorGridCheckbox = minorGrid
        themeCheckbox = theme

        let xRange = ControlFactory.monospacedLabel("")
        let yRange = ControlFactory.monospacedLabel("")
        let zRange = ControlFactory.monospacedLabel("")
        xRangeLabel = xRange
        yRangeLabel = yRange
        zRangeLabel = zRange

        let switches = ControlFactory.stack([axes, grid, minorGrid, theme], spacing: ControlFactory.Metric.rowSpacing)
        let ranges = ControlFactory.stack([xRange, yRange, zRange], spacing: 2)
        add(ControlFactory.heading(L("View")))
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

        if state.document.dimension == .space {
            // 立体图：报坐标盒三个方向的范围；细分网格只有平面图有。
            let view = state.document.view3D
            minorGridCheckbox?.isHidden = true
            xRangeLabel?.stringValue = rangeText("X", view.range(axis: 0))
            yRangeLabel?.stringValue = rangeText("Y", view.range(axis: 1))
            zRangeLabel?.stringValue = rangeText("Z", view.range(axis: 2))
            zRangeLabel?.isHidden = false
            return
        }
        minorGridCheckbox?.isHidden = false
        zRangeLabel?.isHidden = true
        // 只报没被侧栏 / 工具栏盖住的那块：那才是用户眼前的范围。
        let viewport = state.viewport.unobscured
        xRangeLabel?.stringValue = rangeText("X", viewport.xRange)
        yRangeLabel?.stringValue = rangeText("Y", viewport.yRange)
    }

    private func rangeText(_ name: String, _ range: ClosedRange<Double>) -> String {
        "\(name): \(String(format: "%.4g", range.lowerBound)) … \(String(format: "%.4g", range.upperBound))"
    }

    // MARK: - Actions

    @objc private func axesToggled(_ sender: NSButton) {
        let on = sender.state == .on
        state.mutate(L("Show Axes")) { $0.showAxes = on }
    }

    @objc private func gridToggled(_ sender: NSButton) {
        let on = sender.state == .on
        state.mutate(L("Show Grid")) { $0.showGrid = on }
    }

    @objc private func minorGridToggled(_ sender: NSButton) {
        let on = sender.state == .on
        state.mutate(L("Show Minor Grid")) { $0.showMinorGrid = on }
    }

    @objc private func themeToggled(_ sender: NSButton) {
        let isDark = sender.state == .on
        state.mutate(L("Change Theme")) { $0.theme = isDark ? .dark : .light }
    }
}
