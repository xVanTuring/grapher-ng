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

        // The canvas runs edge to edge under the translucent toolbar and the
        // glass sidebar, but text must not: a tick label drawn up there is
        // unreadable. Labels are held inside the unobscured area instead —
        // 用视口里记的遮挡宽度，不读 `safeAreaInsets`：前者侧栏开合时逐帧更新，
        // 后者收起时要等动画完才变（见 `SafeAreaProbeView`）。
        let insets = obscuredInsets(scale: scale)
        let labelTop = insets.top + 2
        let labelBottom = bounds.height - insets.bottom - 2
        let labelLeft = insets.left
        let labelRight = bounds.width - insets.right

        func place(_ key: String, _ text: String, _ font: NSFont, at point: CGPoint, anchor: TextAnchor) {
            labels.place(key, text, font: font, color: labelColor, at: point, anchor: anchor)
        }

        let tickFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let axisX = chrome.originPixel.x / scale
        let axisY = chrome.originPixel.y / scale
        // 竖轴压在侧栏毛玻璃底下时照样画线，但数字按「不在屏上」处理，钉到安全区左缘。
        let showsVertical = chrome.showsVerticalAxis && axisX >= labelLeft && axisX <= labelRight
        let showsHorizontal = chrome.showsHorizontalAxis

        // The label row rides the axis when it is on screen, otherwise it pins
        // to the edge so the numbers never disappear.
        let onAxis = showsHorizontal && axisY < labelBottom - 26
        let xLabelY = showsHorizontal ? min(max(axisY + 4, labelTop), labelBottom) : labelBottom
        let xAnchor: TextAnchor = onAxis ? .top : .bottom

        // With both axes on screen the origin is marked with an "O", so the
        // zero tick would only collide with it.
        let originMarked = showsHorizontal && showsVertical

        if state.document.showTickLabels {
            // 窗口边缘允许半个数字露在外面；贴着侧栏那一边则整个让开，不往毛玻璃底下压。
            let minLabelX = labelLeft > 0 ? labelLeft + 12 : -24
            let maxLabelX = labelRight < bounds.width ? labelRight - 12 : bounds.width + 24
            for tick in chrome.xTicks.major {
                if originMarked && abs(tick) < 1e-9 { continue }
                let x = viewport.dataToScreenX(tick) / scale
                guard x > minLabelX, x < maxLabelX else { continue }
                place("x", AxisLabelFormat.tick(tick, decimals: chrome.xTicks.labelDecimals), tickFont,
                      at: CGPoint(x: x, y: xLabelY), anchor: xAnchor)
            }

            let onAxisY = showsVertical && axisX > labelLeft + 44
            let yLabelX = showsVertical ? min(max(axisX - 6, labelLeft + 22), labelRight - 4) : labelLeft + 8
            let yAnchor: TextAnchor = onAxisY ? .trailing : .leading
            for tick in chrome.yTicks.major where !(originMarked && abs(tick) < 1e-9) {
                let y = viewport.dataToScreenY(tick) / scale
                // Anything in the toolbar band or past the bottom edge is dropped
                // rather than drawn half-hidden.
                guard y > labelTop, y < labelBottom else { continue }
                place("y", AxisLabelFormat.tick(tick, decimals: chrome.yTicks.labelDecimals), tickFont,
                      at: CGPoint(x: yLabelX, y: y), anchor: yAnchor)
            }
        }

        if originMarked, axisY > labelTop, axisY < labelBottom {
            place("origin", "O", .systemFont(ofSize: 10.5, weight: .bold),
                  at: CGPoint(x: axisX - 9, y: axisY + 9), anchor: .center)
        }

        let axisNameFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        if showsHorizontal {
            place("axis", "x", axisNameFont,
                  at: CGPoint(x: labelRight - 12, y: min(max(axisY + 11, labelTop + 8), labelBottom)),
                  anchor: .center)
        }
        if showsVertical {
            place("axis", "y", axisNameFont,
                  at: CGPoint(x: max(axisX + 13, labelLeft + 12), y: labelTop + 8), anchor: .center)
        }

        placeProbe(state: state, scale: scale, bounds: bounds, insets: insets)
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

/// 刻度数字与读数的格式，2D、3D 画布共用。
enum AxisLabelFormat {
    static func tick(_ value: Double, decimals: Int) -> String {
        if abs(value) < 1e-12 { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1e6 || magnitude < 1e-4 {
            return String(format: "%.2g", value)
        }
        return String(format: "%.\(min(max(decimals, 0), 8))f", value)
    }

    static func readout(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value == 0 { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1e6 || magnitude < 1e-4 {
            return String(format: "%.4g", value)
        }
        return String(format: "%.4f", value)
    }
}
