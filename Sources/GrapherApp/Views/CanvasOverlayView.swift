import AppKit
import GrapherKit

/// The text layer above the Metal canvas: tick numbers, axis names and the
/// cursor read-out. Drawing it in Core Graphics keeps the type crisp and lets
/// the geometry stay in Metal where it belongs.
@MainActor
final class CanvasOverlayView: NSView {

    var state: AppState?

    override var isFlipped: Bool { true }

    /// Purely decorative: clicks belong to the canvas underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isOpaque: Bool { false }

    private enum Anchor {
        case top, bottom, leading, trailing, center
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let state else { return }
        let scale = state.backingScale
        guard scale > 0 else { return }

        // 刻度与网格线必须出自同一个视口：都取**当前**视口现算的那份（`AppState.chrome`），
        // 不用后台场景里带回来的——那份是开工那一刻的视口，拖动中早就过时了。
        let viewport = state.document.viewport
        let theme = state.document.theme
        let chrome = state.chrome().layout
        let bounds = self.bounds

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

        let tickAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: ControlFactory.nsColor(theme.label),
        ]

        let axisX = chrome.originPixel.x / scale
        let axisY = chrome.originPixel.y / scale
        // 竖轴压在侧栏毛玻璃底下时照样画线，但数字按「不在屏上」处理，钉到安全区左缘。
        let showsVertical = chrome.showsVerticalAxis && axisX >= labelLeft && axisX <= labelRight
        let showsHorizontal = chrome.showsHorizontalAxis

        // The label row rides the axis when it is on screen, otherwise it pins
        // to the edge so the numbers never disappear.
        let onAxis = showsHorizontal && axisY < labelBottom - 26
        let xLabelY = showsHorizontal ? min(max(axisY + 4, labelTop), labelBottom) : labelBottom
        let xAnchor: Anchor = onAxis ? .top : .bottom

        // With both axes on screen the origin is marked with an "O", so the
        // zero tick would only collide with it.
        let originMarked = showsHorizontal && showsVertical

        // 窗口边缘允许半个数字露在外面；贴着侧栏那一边则整个让开，不往毛玻璃底下压。
        let minLabelX = labelLeft > 0 ? labelLeft + 12 : -24
        let maxLabelX = labelRight < bounds.width ? labelRight - 12 : bounds.width + 24
        for tick in chrome.xTicks.major {
            if originMarked && abs(tick) < 1e-9 { continue }
            let x = viewport.dataToScreenX(tick) / scale
            guard x > minLabelX, x < maxLabelX else { continue }
            draw(
                formatted(tick, decimals: chrome.xTicks.labelDecimals),
                at: CGPoint(x: x, y: xLabelY),
                anchor: xAnchor,
                attributes: tickAttributes
            )
        }

        let onAxisY = showsVertical && axisX > labelLeft + 44
        let yLabelX = showsVertical ? min(max(axisX - 6, labelLeft + 22), labelRight - 4) : labelLeft + 8
        let yAnchor: Anchor = onAxisY ? .trailing : .leading

        for tick in chrome.yTicks.major where !(originMarked && abs(tick) < 1e-9) {
            let y = viewport.dataToScreenY(tick) / scale
            // Anything in the toolbar band or past the bottom edge is dropped
            // rather than drawn half-hidden.
            guard y > labelTop, y < labelBottom else { continue }
            draw(
                formatted(tick, decimals: chrome.yTicks.labelDecimals),
                at: CGPoint(x: yLabelX, y: y),
                anchor: yAnchor,
                attributes: tickAttributes
            )
        }

        if originMarked, axisY > labelTop, axisY < labelBottom {
            draw(
                "O",
                at: CGPoint(x: axisX - 9, y: axisY + 9),
                anchor: .center,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
                    .foregroundColor: ControlFactory.nsColor(theme.label),
                ]
            )
        }

        let axisNameAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: ControlFactory.nsColor(theme.label),
        ]
        if showsHorizontal {
            draw(
                "x",
                at: CGPoint(x: labelRight - 12, y: min(max(axisY + 11, labelTop + 8), labelBottom)),
                anchor: .center,
                attributes: axisNameAttributes
            )
        }
        if showsVertical {
            draw(
                "y",
                at: CGPoint(x: max(axisX + 13, labelLeft + 12), y: labelTop + 8),
                anchor: .center,
                attributes: axisNameAttributes
            )
        }

        drawProbe(scale: scale, bounds: bounds)
    }

    // MARK: - Probe read-out

    private func drawProbe(scale: Double, bounds: NSRect) {
        guard let state, let probe = state.probe else { return }
        // 按数据点和当前视口现算位置：拖动画布时读数圈跟着曲线走，不停在命中那一刻的屏幕位置。
        let screen = state.document.viewport.toScreen(x: probe.dataPoint.x, y: probe.dataPoint.y)
        let point = CGPoint(x: screen.x / scale, y: screen.y / scale)
        let color = ControlFactory.nsColor(probe.color)

        let ring = NSBezierPath(ovalIn: NSRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9))
        ring.lineWidth = 1.6
        color.setStroke()
        ring.stroke()

        let dot = NSBezierPath(ovalIn: NSRect(x: point.x - 1.6, y: point.y - 1.6, width: 3.2, height: 3.2))
        NSColor.white.setFill()
        dot.fill()

        var lines = [
            "x = " + number(probe.dataPoint.x),
            "y = " + number(probe.dataPoint.y),
        ]
        if let slope = probe.slope, slope.isFinite {
            lines.append("dy/dx = " + number(slope))
        }

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: color,
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]

        let title = NSAttributedString(string: probe.layerName, attributes: titleAttributes)
        let body = NSAttributedString(string: lines.joined(separator: "   "), attributes: bodyAttributes)
        let titleSize = title.size()
        let bodySize = body.size()

        let boxWidth = max(titleSize.width, bodySize.width) + 18
        let boxHeight = titleSize.height + bodySize.height + 12

        var originX = point.x + 12
        let insets = obscuredInsets(scale: scale)
        if originX + boxWidth > bounds.width - insets.right { originX = point.x - 12 - boxWidth }
        var originY = point.y + 12
        if originY + boxHeight > bounds.height { originY = point.y - 12 - boxHeight }
        // 读数框也让开毛玻璃侧栏。
        originX = max(insets.left + 4, originX)
        // Stay clear of the toolbar band, which floats over the canvas.
        originY = max(insets.top + 4, originY)

        let box = NSRect(x: originX, y: originY, width: boxWidth, height: boxHeight)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.withAlphaComponent(0.94).setFill()
        path.fill()
        color.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()

        title.draw(at: CGPoint(x: box.minX + 9, y: box.minY + 6))
        body.draw(at: CGPoint(x: box.minX + 9, y: box.minY + 6 + titleSize.height + 2))
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

    private func draw(
        _ string: String,
        at point: CGPoint,
        anchor: Anchor,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let text = NSAttributedString(string: string, attributes: attributes)
        let size = text.size()
        let origin: CGPoint
        switch anchor {
        case .top:
            origin = CGPoint(x: point.x - size.width / 2, y: point.y)
        case .bottom:
            origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height)
        case .leading:
            origin = CGPoint(x: point.x, y: point.y - size.height / 2)
        case .trailing:
            origin = CGPoint(x: point.x - size.width, y: point.y - size.height / 2)
        case .center:
            origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        }
        // A flipped view draws text top-down, but Core Text still measures in
        // the unflipped space, so round to whole points to keep it sharp.
        text.draw(at: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()))
    }

    private func number(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value == 0 { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1e6 || magnitude < 1e-4 {
            return String(format: "%.4g", value)
        }
        return String(format: "%.4f", value)
    }

    private func formatted(_ value: Double, decimals: Int) -> String {
        if abs(value) < 1e-12 { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1e6 || magnitude < 1e-4 {
            return String(format: "%.2g", value)
        }
        return String(format: "%.\(min(max(decimals, 0), 8))f", value)
    }
}
