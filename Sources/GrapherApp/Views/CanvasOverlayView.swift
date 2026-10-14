import AppKit
import GrapherKit

/// The text layer above the Metal canvas: tick numbers, axis names and the
/// cursor read-out.
///
/// 每个文字是一个小图层（`TextLayerPool`）：同一串字只渲染一次，拖动时只挪图层位置，不重画。
/// 早先整块叠加层每帧在主线程重画一张整窗大小的透明位图，WindowServer 每帧都得重新上传、合成它，
/// 窗口越大越拖累上屏。`refresh()` 由画布在每次屏幕刷新、Metal 画这一帧之前调用，与网格线同一个事务上屏。
@MainActor
final class CanvasOverlayView: NSView {

    var state: AppState?

    override var isFlipped: Bool { true }

    /// Purely decorative: clicks belong to the canvas underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    private let labels = TextLayerPool()
    private let probeRing = CAShapeLayer()
    private let probeDot = CAShapeLayer()
    private let probeBox = CALayer()
    private var probeBoxKey: String?
    private var probeBoxSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.addSublayer(labels.root)

        probeRing.fillColor = nil
        probeRing.lineWidth = 1.6
        probeDot.fillColor = NSColor.white.cgColor
        for probeLayer in [probeRing, probeDot, probeBox] as [CALayer] {
            probeLayer.actions = TextLayerPool.noAnimations
            probeLayer.isHidden = true
            labels.root.addSublayer(probeLayer)
        }
        probeBox.zPosition = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CanvasOverlayView is created in code only")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labels.root.frame = layer?.bounds ?? bounds
        // 宿主图层若已按翻转视图摆放，子图层直接用左上角原点；否则这里自己翻过来。
        labels.root.isGeometryFlipped = !(layer?.contentsAreFlipped() ?? false)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // 换到倍率不同的屏幕：位图全部按新倍率重出。
        labels.reset()
        probeBoxKey = nil
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // 读数框用的是系统动态色，外观一变就得重出。
        probeBoxKey = nil
        refresh()
    }

    // MARK: - Refresh

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

        // 刻度与网格线必须出自同一个视口：都取**当前**视口现算的那份（`AppState.chrome`），
        // 不用后台场景里带回来的——那份是开工那一刻的视口，拖动中早就过时了。
        let viewport = state.document.viewport
        let theme = state.document.theme
        let chrome = state.chrome().layout
        let bounds = self.bounds
        let labelColor = ControlFactory.nsColor(theme.label)

        // 文字摆在哪由 `PlaneLabels` 算（Quick Look 预览也用它），这里只按角色挑字体。
        // 遮挡宽度用视口里记的，不读 `safeAreaInsets`：前者侧栏开合时逐帧更新，
        // 后者收起时要等动画完才变（见 `SafeAreaProbeView`）。
        let tickFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let originFont = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        let axisNameFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        for label in PlaneLabels.make(
            chrome: chrome,
            viewport: viewport,
            showTickLabels: state.document.showTickLabels,
            width: bounds.width,
            height: bounds.height,
            pointScale: scale
        ) {
            let font: NSFont
            switch label.role {
            case .tick: font = tickFont
            case .origin: font = originFont
            case .axisName: font = axisNameFont
            }
            labels.place(label.key, label.text, font: font, color: labelColor,
                         at: CGPoint(x: label.point.x, y: label.point.y), anchor: label.anchor)
        }

        // 自由文字：写在数据坐标 (x, y) 上，文字左边缘对着这一点，跟着画布一起平移缩放。
        for (index, annotation) in TextAnnotations.all(in: state.document, compiled: state.compiler.compile(state.document)).enumerated() {
            let screen = viewport.toScreen(x: annotation.position.x, y: annotation.position.y)
            let point = CGPoint(x: screen.x / scale, y: screen.y / scale)
            guard point.x > -400, point.x < bounds.width + 40, point.y > -40, point.y < bounds.height + 40 else { continue }
            labels.place("a\(index)", annotation.text, font: .systemFont(ofSize: annotation.fontSize),
                         color: ControlFactory.nsColor(annotation.color), at: point, anchor: .leading)
        }

        placeProbe(state: state, scale: scale, bounds: bounds, insets: obscuredInsets(scale: scale))
    }

    // MARK: - Probe read-out

    private func placeProbe(state: AppState, scale: Double, bounds: NSRect, insets: NSEdgeInsets) {
        guard let probe = state.probe else {
            probeRing.isHidden = true
            probeDot.isHidden = true
            probeBox.isHidden = true
            return
        }
        // 按数据点和当前视口现算位置：拖动画布时读数圈跟着曲线走，不停在命中那一刻的屏幕位置。
        let screen = state.document.viewport.toScreen(x: probe.dataPoint.x, y: probe.dataPoint.y)
        let point = CGPoint(x: screen.x / scale, y: screen.y / scale)
        let color = ControlFactory.nsColor(probe.color)

        probeRing.isHidden = false
        probeRing.strokeColor = color.cgColor
        probeRing.path = CGPath(ellipseIn: CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9), transform: nil)
        probeDot.isHidden = false
        probeDot.path = CGPath(ellipseIn: CGRect(x: point.x - 1.6, y: point.y - 1.6, width: 3.2, height: 3.2), transform: nil)

        var lines = [
            "x = " + AxisLabelFormat.readout(probe.dataPoint.x),
            "y = " + AxisLabelFormat.readout(probe.dataPoint.y),
        ]
        if let slope = probe.slope, slope.isFinite {
            lines.append("dy/dx = " + AxisLabelFormat.readout(slope))
        }
        let body = lines.joined(separator: "   ")
        let key = "\(probe.layerName)|\(body)|\(probe.color)|\(scale)"
        if key != probeBoxKey, let rendered = renderProbeBox(title: probe.layerName, body: body, color: color, scale: scale) {
            probeBox.contents = rendered.image
            probeBox.contentsScale = scale
            probeBoxSize = rendered.size
            probeBoxKey = key
        }

        let boxWidth = probeBoxSize.width
        let boxHeight = probeBoxSize.height
        var originX = point.x + 12
        if originX + boxWidth > bounds.width - insets.right { originX = point.x - 12 - boxWidth }
        var originY = point.y + 12
        if originY + boxHeight > bounds.height { originY = point.y - 12 - boxHeight }
        // 读数框也让开毛玻璃侧栏。
        originX = max(insets.left + 4, originX)
        // Stay clear of the toolbar band, which floats over the canvas.
        originY = max(insets.top + 4, originY)
        probeBox.isHidden = false
        probeBox.frame = CGRect(x: originX.rounded(), y: originY.rounded(), width: boxWidth, height: boxHeight)
    }

    private func renderProbeBox(title: String, body: String, color: NSColor, scale: Double) -> TextLayerPool.Rendered? {
        let titleText = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: color,
        ])
        let bodyText = NSAttributedString(string: body, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
        let titleSize = titleText.size()
        let bodySize = bodyText.size()
        let size = CGSize(
            width: (max(titleSize.width, bodySize.width) + 18).rounded(.up),
            height: (titleSize.height + bodySize.height + 12).rounded(.up)
        )
        return TextLayerPool.renderImage(size: size, scale: scale, appearance: effectiveAppearance) { box in
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.controlBackgroundColor.withAlphaComponent(0.94).setFill()
            path.fill()
            color.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
            // 位图上下文不翻转：从上往下排要换算成从下往上的坐标。
            titleText.draw(at: CGPoint(x: 9, y: box.height - 6 - titleSize.height))
            bodyText.draw(at: CGPoint(x: 9, y: box.height - 6 - titleSize.height - 2 - bodySize.height))
        }
    }

    // MARK: - Helpers

    /// 画布被浮层盖住的四边，单位点。
    private func obscuredInsets(scale: Double) -> NSEdgeInsets {
        guard let viewport = state?.document.viewport, scale > 0 else { return safeAreaInsets }
        return NSEdgeInsets(
            top: viewport.insetTop / scale,
            left: viewport.insetLeft / scale,
            bottom: viewport.insetBottom / scale,
            right: viewport.insetRight / scale
        )
    }
}

