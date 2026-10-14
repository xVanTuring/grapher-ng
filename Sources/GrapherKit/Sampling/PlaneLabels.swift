import Foundation

/// 一串字相对它的锚点怎么摆：`top` 是锚点在字的上沿正中，`leading` 是锚点在字的左沿正中，依此类推。
public enum LabelAnchor: Equatable, Sendable {
    case top, bottom, leading, trailing, center
}

/// 平面图坐标轴上的一串字：刻度数字、原点「O」或轴名。
public struct PlaneLabel: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case tick, origin, axisName
    }

    /// 画布叠加层按它分池复用文字图层（x、y 轴上都有 "5.0" 时不混用）。
    public var key: String
    public var text: String
    public var role: Role
    /// 点，左上角原点。
    public var point: SIMD2<Double>
    public var anchor: LabelAnchor
}

/// 平面图的坐标轴文字摆在哪。画布叠加层与 Quick Look 预览共用这一份，两边的数字位置一致；
/// 这里只管位置，字号、字重由画的一方按 `PlaneLabel.Role` 定。
public enum PlaneLabels {
    /// - Parameters:
    ///   - chrome: 与网格线出自同一个视口的刻度（`SceneBuilder2D.chromeScene` 的 layout）。
    ///   - viewport: 当前视口；被侧栏 / 工具栏盖住的四边（`insetLeft` 等，像素）里不放字。
    ///   - width, height: 画布尺寸（点）。
    ///   - pointScale: 像素 / 点。
    public static func make(
        chrome: ChromeLayout,
        viewport: Viewport2D,
        showTickLabels: Bool,
        width: Double,
        height: Double,
        pointScale scale: Double
    ) -> [PlaneLabel] {
        guard scale > 0 else { return [] }
        var labels: [PlaneLabel] = []
        func place(_ key: String, _ text: String, _ role: PlaneLabel.Role, x: Double, y: Double, _ anchor: LabelAnchor) {
            labels.append(PlaneLabel(key: key, text: text, role: role, point: SIMD2(x, y), anchor: anchor))
        }

        // The canvas runs edge to edge under the translucent toolbar and the
        // glass sidebar, but text must not: a tick label drawn up there is
        // unreadable. Labels are held inside the unobscured area instead.
        let labelTop = viewport.insetTop / scale + 2
        let labelBottom = height - viewport.insetBottom / scale - 2
        let labelLeft = viewport.insetLeft / scale
        let labelRight = width - viewport.insetRight / scale

        let axisX = chrome.originPixel.x / scale
        let axisY = chrome.originPixel.y / scale
        // 竖轴压在侧栏毛玻璃底下时照样画线，但数字按「不在屏上」处理，钉到安全区左缘。
        let showsVertical = chrome.showsVerticalAxis && axisX >= labelLeft && axisX <= labelRight
        let showsHorizontal = chrome.showsHorizontalAxis

        // The label row rides the axis when it is on screen, otherwise it pins
        // to the edge so the numbers never disappear.
        let onAxis = showsHorizontal && axisY < labelBottom - 26
        let xLabelY = showsHorizontal ? min(max(axisY + 4, labelTop), labelBottom) : labelBottom
        let xAnchor: LabelAnchor = onAxis ? .top : .bottom

        // With both axes on screen the origin is marked with an "O", so the
        // zero tick would only collide with it.
        let originMarked = showsHorizontal && showsVertical

        if showTickLabels {
            // 窗口边缘允许半个数字露在外面；贴着侧栏那一边则整个让开，不往毛玻璃底下压。
            let minLabelX = labelLeft > 0 ? labelLeft + 12 : -24
            let maxLabelX = labelRight < width ? labelRight - 12 : width + 24
            for tick in chrome.xTicks.major {
                if originMarked && abs(tick) < 1e-9 { continue }
                let x = viewport.dataToScreenX(tick) / scale
                guard x > minLabelX, x < maxLabelX else { continue }
                place("x", AxisLabelFormat.tick(tick, decimals: chrome.xTicks.labelDecimals), .tick,
                      x: x, y: xLabelY, xAnchor)
            }

            let onAxisY = showsVertical && axisX > labelLeft + 44
            let yLabelX = showsVertical ? min(max(axisX - 6, labelLeft + 22), labelRight - 4) : labelLeft + 8
            let yAnchor: LabelAnchor = onAxisY ? .trailing : .leading
            for tick in chrome.yTicks.major where !(originMarked && abs(tick) < 1e-9) {
                let y = viewport.dataToScreenY(tick) / scale
                // Anything in the toolbar band or past the bottom edge is dropped
                // rather than drawn half-hidden.
                guard y > labelTop, y < labelBottom else { continue }
                place("y", AxisLabelFormat.tick(tick, decimals: chrome.yTicks.labelDecimals), .tick,
                      x: yLabelX, y: y, yAnchor)
            }
        }

        if originMarked, axisY > labelTop, axisY < labelBottom {
            place("origin", "O", .origin, x: axisX - 9, y: axisY + 9, .center)
        }
        if showsHorizontal {
            place("axis", "x", .axisName, x: labelRight - 12, y: min(max(axisY + 11, labelTop + 8), labelBottom), .center)
        }
        if showsVertical {
            place("axis", "y", .axisName, x: max(axisX + 13, labelLeft + 12), y: labelTop + 8, .center)
        }
        return labels
    }
}

/// 刻度数字与读数的格式，2D、3D 画布与预览共用。
public enum AxisLabelFormat {
    public static func tick(_ value: Double, decimals: Int) -> String {
        if abs(value) < 1e-12 { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1e6 || magnitude < 1e-4 {
            return String(format: "%.2g", value)
        }
        return String(format: "%.\(min(max(decimals, 0), 8))f", value)
    }

    public static func readout(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value == 0 { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1e6 || magnitude < 1e-4 {
            return String(format: "%.4g", value)
        }
        return String(format: "%.4f", value)
    }
}
