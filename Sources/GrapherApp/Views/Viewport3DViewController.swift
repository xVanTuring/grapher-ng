import AppKit
import GrapherKit
import GrapherRender

/// 立体图的画布：Metal 3D 视图、坐标盒刻度的文字层、底部状态条。结构与 2D 的
/// `ViewportViewController` 一致——画布铺满窗格、伸到毛玻璃侧栏底下，遮挡宽度由 `SafeAreaProbeView` 量，
/// 一切更新都在屏幕刷新的回调里做。
///
/// 操作：拖动旋转；⇧+拖动或双指滚动平移；⌘+滚轮或捏合缩放图形（改坐标盒的范围）；
/// ⌥+滚轮或 ⌥+捏合放大盒子；F 适应内容，R 回到默认视角。
final class Viewport3DViewController: NSViewController {

    private let state: AppState
    private let host = Viewport3DHostView()
    private let overlay = Canvas3DOverlayView()
    private let safeAreaProbe = SafeAreaProbeView()
    private let statusBar = CanvasStatusBar()

    private var metalView: MetalView3D?
    private var lastDragLocation: NSPoint?
    private var dragPans = false
    private var metricsSyncScheduled = false
    private var observerID: UUID?

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Viewport3DViewController is created in code only")
    }

    deinit {
        if let observerID { MainActor.assumeIsolated { state.removeObserver(observerID) } }
    }

    override func loadView() {
        let root = FlippedView()
        root.translatesAutoresizingMaskIntoConstraints = false

        host.translatesAutoresizingMaskIntoConstraints = false
        host.controller = self
        root.addSubview(host)

        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.state = state
        host.addSubview(overlay)

        safeAreaProbe.translatesAutoresizingMaskIntoConstraints = false
        safeAreaProbe.onChange = { [weak self] in self?.scheduleMetricsSync() }
        host.addSubview(safeAreaProbe)

        root.addSubview(statusBar)

        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: root.topAnchor),
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            overlay.topAnchor.constraint(equalTo: host.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),

            safeAreaProbe.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor),
            safeAreaProbe.leadingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.leadingAnchor),
            safeAreaProbe.trailingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.trailingAnchor),
            safeAreaProbe.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor),

            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installMetalView()
        observerID = state.observe([.scene, .status, .viewport, .document]) { [weak self] change in
            guard let self else { return }
            switch change {
            case .scene: self.pushContent()
            case .viewport, .document: self.requestFrame()
            case .status: self.updateStatus()
            default: break
            }
        }
        updateStatus()
    }

    private func installMetalView() {
        guard metalView == nil, let context = MetalContext.shared else { return }
        guard let view = MetalView3D(frame: host.bounds, context: context) else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view, positioned: .below, relativeTo: overlay)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        view.onFrame = { [weak self] in self?.frameWillDraw() }
        metalView = view
        pushContent()
        requestFrame()
    }

    private func pushContent() {
        guard let metalView else { return }
        guard let built = state.built3D else {
            metalView.setContent(nil, view: state.document.view3D)
            return
        }
        metalView.setContent(built.scene, view: built.view)
    }

    private func requestFrame() {
        if let metalView {
            metalView.requestFrame()
        } else {
            frameWillDraw()
        }
    }

    /// 每次屏幕刷新、Metal 画这一帧之前：坐标盒线框按当前视角重画，曲面曲线换视角，刻度文字挪到位。
    private func frameWillDraw() {
        if let metalView {
            let chrome = state.chrome3D().scene
            metalView.background = state.document.theme.background
            if metalView.chrome != chrome { metalView.chrome = chrome }
            metalView.viewport = state.document.view3D
        }
        overlay.refresh()
        let view = state.document.view3D
        statusBar.zoomText = String(format: L("Box ±%.4g · %.2g×"), view.halfExtent, view.cameraZoom)
    }

    private func updateStatus() {
        statusBar.update(
            isBuilding: state.isBuilding,
            message: state.statusMessage.isEmpty
                ? L("Drag to rotate · ⇧-drag or scroll to pan · ⌘-scroll or pinch to zoom · ⌥-scroll to resize the box · F fit · R reset")
                : state.statusMessage
        )
    }

    // MARK: - Metrics

    override func viewDidLayout() {
        super.viewDidLayout()
        scheduleMetricsSync()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(host)
        scheduleMetricsSync()
    }

    /// 同 2D：视口尺寸是被观察的状态，不能在布局过程中写，延后一拍。
    private func scheduleMetricsSync() {
        guard !metricsSyncScheduled else { return }
        metricsSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.metricsSyncScheduled = false
            self.syncMetrics()
        }
    }

    private func syncMetrics() {
        guard let metalView, let window = view.window else { return }
        let drawable = metalView.drawableSize
        let scale = Double(window.backingScaleFactor)
        guard drawable.width > 1, drawable.height > 1, scale > 0 else { return }
        let probe = safeAreaProbe.frame
        let bounds = host.bounds
        let insets = probe.width > 0 && probe.height > 0
            ? NSEdgeInsets(
                top: max(probe.minY, 0),
                left: max(probe.minX, 0),
                bottom: max(bounds.height - probe.maxY, 0),
                right: max(bounds.width - probe.maxX, 0)
            )
            : host.safeAreaInsets
        state.setViewportMetrics(
            pixelWidth: Double(drawable.width),
            pixelHeight: Double(drawable.height),
            insets: insets,
            backingScale: scale
        )
    }

    // MARK: - Input

    private var backingScale: Double { Double(view.window?.backingScaleFactor ?? 2) }

    fileprivate func handleMouseDown(_ event: NSEvent) {
        view.window?.makeFirstResponder(host)
        lastDragLocation = host.convert(event.locationInWindow, from: nil)
        dragPans = event.modifierFlags.contains(.shift)
    }

    fileprivate func handleMouseDragged(_ event: NSEvent) {
        guard let last = lastDragLocation else { return }
        let current = host.convert(event.locationInWindow, from: nil)
        let delta = SIMD2(Double(current.x - last.x), Double(current.y - last.y))
        lastDragLocation = current
        if dragPans || event.modifierFlags.contains(.shift) {
            state.mutateView3D { $0.pan(byPixels: delta * backingScale) }
            state.requestInteractiveRebuild()
        } else {
            // 只转相机：坐标盒没变，画布当帧换投影就够了，不用重采。
            state.mutateView3D { $0.orbit(byPoints: delta) }
        }
    }

    fileprivate func handleMouseUp(_ event: NSEvent) {
        lastDragLocation = nil
        dragPans = false
    }

    fileprivate func handleScrollWheel(_ event: NSEvent) {
        var dx = Double(event.scrollingDeltaX)
        var dy = Double(event.scrollingDeltaY)
        if !event.hasPreciseScrollingDeltas {
            dx *= 10
            dy *= 10
        }
        // ⌥+滚轮放大盒子，⌘+滚轮缩放图形（改范围，与平面图的 ⌘+滚轮一致），什么都不按是平移。
        let flags = event.modifierFlags
        if flags.contains(.option) || flags.contains(.command) {
            guard dy != 0, event.momentumPhase == [] else { return }
            zoom(by: min(max(exp(-dy * 0.008), 0.5), 2), box: flags.contains(.option))
            return
        }
        guard dx != 0 || dy != 0 else { return }
        state.mutateView3D { $0.pan(byPixels: SIMD2(dx, dy) * backingScale) }
        state.requestInteractiveRebuild()
    }

    fileprivate func handleMagnify(_ event: NSEvent) {
        let factor = 1 + Double(event.magnification)
        guard factor.isFinite, factor > 0 else { return }
        zoom(by: factor, box: event.modifierFlags.contains(.option))
    }

    /// 手势缩放：默认缩放图形（改坐标盒的范围，交互画质重采、停手补精）；
    /// 按住 ⌥ 放大盒子（盒子连同图形在屏幕上变大，只换投影，当帧生效）。
    private func zoom(by factor: Double, box: Bool) {
        if box {
            state.mutateView3D { $0.zoomCamera(by: factor) }
        } else {
            state.mutateView3D { $0.zoom(by: factor) }
            state.requestInteractiveRebuild()
        }
    }

    fileprivate func handleKeyDown(_ event: NSEvent) -> Bool {
        // 方向键每次转 10°：键盘也能转视角。
        let step = 10 / View3D.orbitRadiansPerPoint * .pi / 180
        switch event.specialKey {
        case .leftArrow?: state.mutateView3D { $0.orbit(byPoints: SIMD2(-step, 0)) }; return true
        case .rightArrow?: state.mutateView3D { $0.orbit(byPoints: SIMD2(step, 0)) }; return true
        case .upArrow?: state.mutateView3D { $0.orbit(byPoints: SIMD2(0, -step)) }; return true
        case .downArrow?: state.mutateView3D { $0.orbit(byPoints: SIMD2(0, step)) }; return true
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": state.fitToContent()
        case "r", "0": state.resetView()
        case "=", "+": state.zoom(by: 1.25, box: event.modifierFlags.contains(.option))
        case "-": state.zoom(by: 0.8, box: event.modifierFlags.contains(.option))
        default: return false
        }
        return true
    }
}

final class Viewport3DHostView: NSView {
    weak var controller: Viewport3DViewController?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { controller?.handleMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { controller?.handleMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { controller?.handleMouseUp(event) }
    override func scrollWheel(with event: NSEvent) { controller?.handleScrollWheel(event) }
    override func magnify(with event: NSEvent) { controller?.handleMagnify(event) }
    override func keyDown(with event: NSEvent) {
        if controller?.handleKeyDown(event) != true { super.keyDown(with: event) }
    }
}

/// 立体图画布上的文字：坐标盒的刻度数字与轴名。位置每帧按当前视角投影（`AppState.chrome3D`），
/// 每串字是一个小图层，只挪不重画（同 2D 的 `CanvasOverlayView`）。
@MainActor
final class Canvas3DOverlayView: NSView {

    var state: AppState?
    private let labels = TextLayerPool()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.addSublayer(labels.root)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Canvas3DOverlayView is created in code only")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labels.root.frame = layer?.bounds ?? bounds
        labels.root.isGeometryFlipped = !(layer?.contentsAreFlipped() ?? false)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        labels.reset()
        refresh()
    }

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        labels.begin()
        defer { labels.end() }

        guard let state else { return }
        let scale = state.backingScale
        guard scale > 0 else { return }
        labels.scale = scale
        labels.appearance = effectiveAppearance

        let view = state.document.view3D
        let color = ControlFactory.nsColor(state.document.theme.label)
        let tickFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let nameFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        // 被侧栏 / 工具栏盖住的地方不放字。
        let left = view.insetLeft / scale
        let top = view.insetTop / scale
        let right = bounds.width - view.insetRight / scale
        let bottom = bounds.height - view.insetBottom / scale

        for label in state.chrome3D().labels {
            guard let screen = view.project(label.position) else { continue }
            let point = CGPoint(x: screen.x / scale, y: screen.y / scale)
            guard point.x > left + 8, point.x < right - 8, point.y > top + 8, point.y < bottom - 8 else { continue }
            switch label.kind {
            case .tick(let value, let decimals):
                labels.place("t\(label.axis)", AxisLabelFormat.tick(value, decimals: decimals),
                             font: tickFont, color: color, at: point, anchor: .center)
            case .axisName(let name):
                labels.place("n", name, font: nameFont, color: color, at: point, anchor: .center)
            }
        }
    }
}
