import AppKit
import GrapherKit
import GrapherRender
import QuickLookUI

/// 访达里按空格预览 .grapher：一块只读的画布，打开时是文档存下时眼前那块，能拖、能缩放、立体图能转，
/// 手感与 App 相同（`CanvasInput`）；双击回到存下时的取景。画法与 App 同一套（`MetalView2D` / `MetalView3D`、
/// 刻度文字 `PlaneLabels` / `Chrome3D`），只是没有编辑、没有读数。
final class PreviewViewController: NSViewController, QLPreviewingController {
    private var canvas: PreviewCanvasView?

    override func loadView() {
        view = NSView()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let document = try DocumentStore.load(from: url)
            guard let canvas = PreviewCanvasView(session: PreviewSession(document: document)) else {
                throw CocoaError(.featureUnsupported)
            }
            canvas.frame = view.bounds
            canvas.autoresizingMask = [.width, .height]
            view.addSubview(canvas)
            self.canvas = canvas
            // 预览窗口一开始的大小：存下时眼前那块，按 Retina（2 像素 / 点）换成点，不超过 960 × 640。
            let saved = GraphSnapshot.savedCanvasSize(of: document)
            let fit = min(1, 960 / (saved.width / 2), 640 / (saved.height / 2))
            preferredContentSize = CGSize(width: (saved.width / 2 * fit).rounded(), height: (saved.height / 2 * fit).rounded())
            handler(nil)
        } catch {
            handler(error)
        }
    }
}

/// 预览画布：底下是 Metal 画布，上面是刻度文字图层，鼠标与触控板事件都由它自己接。
/// 翻转坐标（左上角原点），与 App 的画布宿主一致：拖动位移、缩放锚点都按这个量。
@MainActor
final class PreviewCanvasView: NSView {
    private let session: PreviewSession
    private let metal2D: MetalView2D?
    private let metal3D: MetalView3D?
    private let overlay = PreviewLabelOverlay()

    private var lastDragLocation: NSPoint?
    private var dragPans = false
    private var chrome2D: (viewport: Viewport2D, scale: Double, scene: Scene2D, layout: ChromeLayout)?
    private var chrome3D: (view: View3D, scale: Double, result: Chrome3D.Result)?

    init?(session: PreviewSession) {
        self.session = session
        guard let context = MetalContext.shared else { return nil }
        if session.isSpace {
            metal3D = MetalView3D(frame: .zero, context: context)
            metal2D = nil
        } else {
            metal2D = MetalView2D(frame: .zero, context: context)
            metal3D = nil
        }
        super.init(frame: .zero)
        guard let canvas: NSView = metal2D ?? metal3D else { return nil }
        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)

        metal2D?.onFrame = { [weak self] in self?.frameWillDraw() }
        metal3D?.onFrame = { [weak self] in self?.frameWillDraw() }
        session.onViewChange = { [weak self] in self?.requestFrame() }
        session.onSceneChange = { [weak self] in self?.pushContent() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreviewCanvasView is created in code only")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    // 预览窗口可以拖背景移动；画布上的拖动归画布。
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var backingScale: Double { Double(window?.backingScaleFactor ?? 2) }

    // MARK: - 尺寸

    override func layout() {
        super.layout()
        syncCanvasSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        overlay.labels.reset()
        syncCanvasSize()
    }

    /// 布局里不直接改状态，延后一拍（同 App 的 `ViewportViewController`）。
    private func syncCanvasSize() {
        let size = bounds.size
        let scale = backingScale
        DispatchQueue.main.async { [weak self] in
            self?.session.setCanvasSize(pixelWidth: (size.width * scale).rounded(),
                                        pixelHeight: (size.height * scale).rounded(), backingScale: scale)
        }
    }

    // MARK: - 出帧

    private func requestFrame() {
        metal2D?.requestFrame()
        metal3D?.requestFrame()
    }

    private func pushContent() {
        if let metal2D, let built = session.built {
            metal2D.setContent(built.scene, viewport: built.viewport)
        }
        if let metal3D, let built = session.built3D {
            metal3D.setContent(built.scene, view: built.view)
        }
    }

    /// 每次屏幕刷新、Metal 画这一帧之前：网格 / 坐标盒按当前视口现画，曲线层换视口，刻度文字挪到位。
    private func frameWillDraw() {
        let document = session.document
        let scale = session.backingScale
        let labelColor = NSColor(srgbRed: document.theme.label.r, green: document.theme.label.g,
                                 blue: document.theme.label.b, alpha: document.theme.label.a)
        overlay.begin(scale: scale, appearance: effectiveAppearance)
        defer { overlay.end() }

        if let metal2D {
            let viewport = session.viewport
            if chrome2D?.viewport != viewport || chrome2D?.scale != scale {
                let made = SceneBuilder2D.chromeScene(document: document, viewport: viewport, backingScale: scale)
                chrome2D = (viewport, scale, made.scene, made.layout)
            }
            guard let chrome = chrome2D else { return }
            metal2D.background = document.theme.background
            if metal2D.chrome != chrome.scene { metal2D.chrome = chrome.scene }
            metal2D.viewport = viewport

            let tickFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            let originFont = NSFont.systemFont(ofSize: 10.5, weight: .bold)
            let axisNameFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
            for label in PlaneLabels.make(chrome: chrome.layout, viewport: viewport,
                                          showTickLabels: document.showTickLabels,
                                          width: bounds.width, height: bounds.height, pointScale: scale) {
                let font: NSFont
                switch label.role {
                case .tick: font = tickFont
                case .origin: font = originFont
                case .axisName: font = axisNameFont
                }
                overlay.labels.place(label.key, label.text, font: font, color: labelColor,
                                     at: CGPoint(x: label.point.x, y: label.point.y), anchor: label.anchor)
            }
        }

        if let metal3D {
            let view = session.view3D
            if chrome3D?.view != view || chrome3D?.scale != scale {
                chrome3D = (view, scale, Chrome3D.make(view: view, document: document, backingScale: scale))
            }
            guard let chrome = chrome3D?.result else { return }
            metal3D.background = document.theme.background
            if metal3D.chrome != chrome.scene { metal3D.chrome = chrome.scene }
            metal3D.viewport = view

            let tickFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            let nameFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
            for label in chrome.labels {
                guard let screen = view.project(label.position) else { continue }
                let point = CGPoint(x: screen.x / scale, y: screen.y / scale)
                guard point.x > 8, point.x < bounds.width - 8, point.y > 8, point.y < bounds.height - 8 else { continue }
                switch label.kind {
                case .tick(let value, let decimals):
                    overlay.labels.place("t\(label.axis)", AxisLabelFormat.tick(value, decimals: decimals),
                                         font: tickFont, color: labelColor, at: point, anchor: .center)
                case .axisName(let name):
                    overlay.labels.place("n", name, font: nameFont, color: labelColor, at: point, anchor: .center)
                }
            }
        }
    }

    // MARK: - 手势（规则在 CanvasInput，与 App 相同）

    private func anchor(of event: NSEvent) -> SIMD2<Double> {
        let local = convert(event.locationInWindow, from: nil)
        return SIMD2(Double(local.x), Double(local.y)) * backingScale
    }

    override func mouseDown(with event: NSEvent) {
        // 双击回到文档存下时的取景。
        if event.clickCount == 2 {
            lastDragLocation = nil
            session.resetView()
            return
        }
        window?.makeFirstResponder(self)
        lastDragLocation = convert(event.locationInWindow, from: nil)
        dragPans = event.modifierFlags.contains(.shift)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDragLocation else { return }
        let current = convert(event.locationInWindow, from: nil)
        lastDragLocation = current
        let delta = SIMD2(Double(current.x - last.x), Double(current.y - last.y))
        session.apply(CanvasInput.drag(delta, modifiers: CanvasInput.Modifiers(event.modifierFlags),
                                       space: session.isSpace, pansFromStart: dragPans, pointScale: backingScale),
                      anchor: anchor(of: event))
    }

    override func mouseUp(with event: NSEvent) {
        lastDragLocation = nil
        dragPans = false
    }

    override func scrollWheel(with event: NSEvent) {
        session.apply(CanvasInput.scroll(CanvasInput.Scroll(event), space: session.isSpace, pointScale: backingScale),
                      anchor: anchor(of: event))
    }

    override func magnify(with event: NSEvent) {
        session.apply(CanvasInput.pinch(magnification: Double(event.magnification),
                                        modifiers: CanvasInput.Modifiers(event.modifierFlags), space: session.isSpace),
                      anchor: anchor(of: event))
    }
}

/// 刻度文字层：每串字一个小图层，只挪不重画（`TextLayerPool`，与 App 的画布叠加层同一份）。
/// 不接鼠标，事件归底下的画布。
@MainActor
final class PreviewLabelOverlay: NSView {
    let labels = TextLayerPool()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.addSublayer(labels.root)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreviewLabelOverlay is created in code only")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labels.root.frame = layer?.bounds ?? bounds
        labels.root.isGeometryFlipped = !(layer?.contentsAreFlipped() ?? false)
        CATransaction.commit()
    }

    /// 一帧的文字改动包在一个关掉隐式动画的事务里，与 Metal 那一帧一起上屏。
    func begin(scale: Double, appearance: NSAppearance) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labels.scale = scale
        labels.appearance = appearance
        labels.begin()
    }

    func end() {
        labels.end()
        CATransaction.commit()
    }
}
