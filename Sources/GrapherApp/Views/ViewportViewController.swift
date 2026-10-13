import AppKit
import GrapherKit
import GrapherRender

/// The canvas pane: the Metal view, the text overlay on top of it, and the
/// status strip underneath.
final class ViewportViewController: NSViewController {

    private let state: AppState
    private let host = ViewportHostView()
    private let overlay = CanvasOverlayView()
    private let safeAreaProbe = SafeAreaProbeView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private var metalView: MetalView2D?
    private var trackingArea: NSTrackingArea?
    private var lastDragLocation: NSPoint?
    private var metricsSyncScheduled = false
    private var observerID: UUID?

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ViewportViewController is created in code only")
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

        let status = makeStatusBar()
        root.addSubview(status)

        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: root.topAnchor),
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: status.topAnchor),

            overlay.topAnchor.constraint(equalTo: host.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),

            safeAreaProbe.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor),
            safeAreaProbe.leadingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.leadingAnchor),
            safeAreaProbe.trailingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.trailingAnchor),
            safeAreaProbe.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor),

            status.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 24),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installMetalView()
        observerID = state.observe([.scene, .status, .probe, .viewport, .document]) { [weak self] change in
            guard let self else { return }
            switch change {
            case .scene:
                self.pushContent()
            case .viewport, .document:
                // 视口一变：网格重画、曲线按新旧视口之差挪过去、刻度数字跟上——都在这一帧里，
                // 不等后台采样（UniReader 画板 `viewportChanged` 同一个思路）。
                self.refreshCanvas()
                self.overlay.needsDisplay = true
            case .probe:
                self.overlay.needsDisplay = true
            case .status:
                self.updateStatus()
            default:
                break
            }
        }
        updateStatus()
    }

    private func makeStatusBar() -> NSView {
        let bar = FlippedView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(separator)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(spinner)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(statusLabel)

        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = .tertiaryLabelColor
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(zoomLabel)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: bar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bar.trailingAnchor),

            // 整个窗格伸到毛玻璃侧栏底下，状态条的文字得让开侧栏：钉安全区，不钉边。
            spinner.leadingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            spinner.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            statusLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: zoomLabel.leadingAnchor, constant: -10),

            zoomLabel.trailingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            zoomLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    private func installMetalView() {
        guard metalView == nil, let context = MetalContext.shared else { return }
        guard let view = MetalView2D(frame: host.bounds, context: context) else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view, positioned: .below, relativeTo: overlay)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        metalView = view
        refreshCanvas()
        pushContent()
    }

    /// 后台新算好一份曲线：上传一次显存，按它与当前视口之差摆好。
    private func pushContent() {
        guard let metalView else { return }
        guard let built = state.built else {
            metalView.setContent(nil, size: .zero, transform: .identity)
            return
        }
        metalView.setContent(
            built.scene,
            size: SIMD2(built.viewport.widthPixels, built.viewport.heightPixels),
            transform: state.viewport.screenTransform(from: built.viewport)
        )
    }

    /// 视口或显示设置变了：网格与坐标轴按当前视口重画，曲线层只改变换。
    private func refreshCanvas() {
        guard let metalView else { return }
        let chrome = state.chrome().scene
        metalView.background = state.document.theme.background
        if metalView.chrome != chrome { metalView.chrome = chrome }
        if let built = state.built {
            metalView.contentTransform = state.viewport.screenTransform(from: built.viewport)
        }
        zoomLabel.stringValue = String(format: "缩放 %.4g px/单位", state.document.viewport.scale)
    }

    private func updateStatus() {
        if state.isBuilding {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        statusLabel.stringValue = state.statusMessage.isEmpty
            ? "拖动平移 · 滚轮/捏合缩放 · 移动鼠标读数 · F 适应内容 · R 重置"
            : state.statusMessage
        zoomLabel.stringValue = String(format: "缩放 %.4g px/单位", state.document.viewport.scale)
    }

    // MARK: - Metrics

    override func viewDidLayout() {
        super.viewDidLayout()
        scheduleMetricsSync()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.acceptsMouseMovedEvents = true
        view.window?.makeFirstResponder(host)
        scheduleMetricsSync()
    }

    /// The viewport size is observed state, so it must never be written from
    /// inside a layout pass — writing it there makes the layout loop forever.
    private func scheduleMetricsSync() {
        guard !metricsSyncScheduled else { return }
        metricsSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.metricsSyncScheduled = false
            self.syncMetrics()
        }
    }

    func syncMetrics() {
        guard let metalView, let window = view.window else { return }
        let drawable = metalView.drawableSize
        let scale = Double(window.backingScaleFactor)
        guard drawable.width > 1, drawable.height > 1, scale > 0 else { return }
        state.setViewportMetrics(
            pixelWidth: Double(drawable.width),
            pixelHeight: Double(drawable.height),
            insets: obscuredInsets,
            backingScale: scale
        )
    }

    /// 宿主被浮层盖住的四边（点）。按安全区探测视图的 frame 量，不读 `safeAreaInsets`——
    /// 原因见 `SafeAreaProbeView`。
    private var obscuredInsets: NSEdgeInsets {
        let probe = safeAreaProbe.frame
        let bounds = host.bounds
        guard probe.width > 0, probe.height > 0 else { return host.safeAreaInsets }
        return NSEdgeInsets(
            top: max(probe.minY, 0),
            left: max(probe.minX, 0),
            bottom: max(bounds.height - probe.maxY, 0),
            right: max(bounds.width - probe.maxX, 0)
        )
    }

    fileprivate func hostDidLayout() {
        scheduleMetricsSync()
    }

    // MARK: - Input
    //
    // These are deliberately not named `mouseMoved` and friends: those are
    // NSResponder methods, and the host view is the responder that overrides
    // them. Renaming keeps the two from colliding.

    fileprivate var backingScale: Double {
        Double(view.window?.backingScaleFactor ?? 2)
    }

    fileprivate func pixelPoint(from event: NSEvent) -> SIMD2<Double> {
        let local = host.convert(event.locationInWindow, from: nil)
        return SIMD2(Double(local.x) * backingScale, Double(local.y) * backingScale)
    }

    fileprivate func updateTrackingAreas() {
        if let trackingArea { host.removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: host.bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: host,
            userInfo: nil
        )
        host.addTrackingArea(area)
        trackingArea = area
    }

    fileprivate func updateProbe(at pixel: SIMD2<Double>) {
        guard let built = state.built else {
            state.probe = nil
            return
        }
        state.probe = CurveProbe.nearest(
            curves: built.probeCurves,
            toPixel: pixel,
            viewport: state.document.viewport
        )
    }

    fileprivate func handleMouseMoved(_ event: NSEvent) {
        updateProbe(at: pixelPoint(from: event))
    }

    fileprivate func handleMouseExited() {
        state.probe = nil
    }

    fileprivate func handleMouseDown(_ event: NSEvent) {
        view.window?.makeFirstResponder(host)
        lastDragLocation = host.convert(event.locationInWindow, from: nil)
    }

    fileprivate func handleMouseDragged(_ event: NSEvent) {
        guard let last = lastDragLocation else { return }
        let current = host.convert(event.locationInWindow, from: nil)
        let delta = SIMD2(
            Double(current.x - last.x) * backingScale,
            Double(current.y - last.y) * backingScale
        )
        lastDragLocation = current
        state.mutateViewport { $0.pan(byPixels: delta) }
        state.requestInteractiveRebuild()
    }

    fileprivate func handleMouseUp(_ event: NSEvent) {
        lastDragLocation = nil
        updateProbe(at: pixelPoint(from: event))
    }

    /// 滚轮：普通滚动 = 平移，⌘+滚动 = 缩放。这是无限画布的通行手感（Figma / Miro / 他们的
    /// 画板都是这一套），缩放只在非惯性阶段消费——否则触控板一甩会连着放大好几档。
    fileprivate func handleScrollWheel(_ event: NSEvent) {
        var dx = Double(event.scrollingDeltaX)
        var dy = Double(event.scrollingDeltaY)
        // 有级滚轮一格只有 1 左右，触控板是连续的小量；不放大手感迟钝得离谱。
        if !event.hasPreciseScrollingDeltas {
            dx *= 10
            dy *= 10
        }

        if event.modifierFlags.contains(.command) {
            guard dy != 0, event.momentumPhase == [] else { return }
            let factor = min(max(exp(-dy * 0.008), 0.5), 2)
            state.mutateViewport { $0.zoom(by: factor, anchorPixel: pixelPoint(from: event)) }
            state.requestInteractiveRebuild()
            return
        }

        guard dx != 0 || dy != 0 else { return }
        state.mutateViewport { $0.pan(byPixels: SIMD2(dx, dy)) }
        state.requestInteractiveRebuild()
        // 指针没动、曲线在它底下滑过去：读数换成指针下面那条。
        updateProbe(at: pixelPoint(from: event))
    }

    fileprivate func handleMagnify(_ event: NSEvent) {
        let factor = 1 + Double(event.magnification)
        guard factor.isFinite, factor > 0 else { return }
        state.mutateViewport { $0.zoom(by: factor, anchorPixel: pixelPoint(from: event)) }
        state.requestInteractiveRebuild()
    }

    fileprivate func handleKeyDown(_ event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": state.fitToContent()
        case "r", "0": state.resetView()
        case "=", "+": state.zoom(by: 1.25)
        case "-": state.zoom(by: 0.8)
        default: super.keyDown(with: event)
        }
    }
}

/// 钉在宿主安全区参考线上的透明视图，只用来量「画布被侧栏 / 工具栏盖住了多少」。
///
/// 不直接读 `safeAreaInsets`：侧栏**收起**的动画里它一直停在原值、动画结束才一下跳到 0
/// （展开时倒是逐帧变的，实测），内容就会等侧栏收完再猛地一跳；而按参考线约束出来的
/// frame 两个方向都逐帧跟着侧栏走，frame 一变就去对一次视口。
final class SafeAreaProbeView: NSView {
    var onChange: (() -> Void)?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        onChange?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onChange?()
    }
}

/// Transparent to the responder chain for everything except the handful of
/// events the canvas cares about.
final class ViewportHostView: NSView {
    weak var controller: ViewportViewController?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        controller?.updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        controller?.hostDidLayout()
    }

    override func mouseMoved(with event: NSEvent) { controller?.handleMouseMoved(event) }
    override func mouseExited(with event: NSEvent) { controller?.handleMouseExited() }
    override func mouseDown(with event: NSEvent) { controller?.handleMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { controller?.handleMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { controller?.handleMouseUp(event) }
    override func scrollWheel(with event: NSEvent) { controller?.handleScrollWheel(event) }
    override func magnify(with event: NSEvent) { controller?.handleMagnify(event) }
    override func keyDown(with event: NSEvent) { controller?.handleKeyDown(event) }
}
