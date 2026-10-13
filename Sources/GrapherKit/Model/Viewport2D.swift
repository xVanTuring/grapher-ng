import Foundation

/// Maps between data space and viewport pixels.
///
/// The scale is deliberately *uniform* on both axes so that shapes keep their
/// true proportions — a circle has to look like a circle.
public struct Viewport2D: Equatable, Sendable, Codable {
    /// Data-space point shown at the centre of the viewport — 准确说是**没被遮住那块**
    /// （见 `insetLeft` 等）的中心。
    public var centerX: Double
    public var centerY: Double
    /// Backing pixels per data unit.
    public var scale: Double
    /// Viewport size in backing pixels. 这是整块画布的尺寸，含被侧栏 / 工具栏盖住的部分。
    public var widthPixels: Double
    public var heightPixels: Double

    /// 画布四边被浮层（毛玻璃侧栏、工具栏）盖住的宽度，单位像素。画布照样画到它们底下，
    /// 透过毛玻璃能看到；但「视口中心」落在没被盖住那块的中心——侧栏一开，内容就被推到
    /// 右边那块里居中（UniReader 阅读区同一个做法）。这是窗口状态，不进文档。
    public var insetLeft: Double = 0
    public var insetTop: Double = 0
    public var insetRight: Double = 0
    public var insetBottom: Double = 0

    /// 文档里只存中心、倍率与尺寸；遮挡宽度跟着窗口走，读进来一律是 0，由界面重新填。
    private enum CodingKeys: String, CodingKey {
        case centerX, centerY, scale, widthPixels, heightPixels
    }

    public init(
        centerX: Double = 0,
        centerY: Double = 0,
        scale: Double = 64,
        widthPixels: Double = 1200,
        heightPixels: Double = 800
    ) {
        self.centerX = centerX
        self.centerY = centerY
        self.scale = scale
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
    }

    /// `centerX/Y` 落在屏幕上的像素位置：没被遮住那块的中心。
    public var focusX: Double { insetLeft + (widthPixels - insetLeft - insetRight) / 2 }
    public var focusY: Double { insetTop + (heightPixels - insetTop - insetBottom) / 2 }

    public var halfWidthData: Double { widthPixels / 2 / scale }
    public var halfHeightData: Double { heightPixels / 2 / scale }

    /// 整块画布（含被遮住的部分）覆盖的数据范围：毛玻璃底下也要有图。
    public var xRange: ClosedRange<Double> {
        screenToDataX(0)...screenToDataX(widthPixels)
    }

    public var yRange: ClosedRange<Double> {
        screenToDataY(heightPixels)...screenToDataY(0)
    }

    public func toScreen(x: Double, y: Double) -> SIMD2<Double> {
        SIMD2(dataToScreenX(x), dataToScreenY(y))
    }

    public func toData(_ p: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(screenToDataX(p.x), screenToDataY(p.y))
    }

    public func screenToDataX(_ px: Double) -> Double {
        (px - focusX) / scale + centerX
    }

    public func screenToDataY(_ py: Double) -> Double {
        (focusY - py) / scale + centerY
    }

    public func dataToScreenX(_ x: Double) -> Double {
        (x - centerX) * scale + focusX
    }

    public func dataToScreenY(_ y: Double) -> Double {
        focusY - (y - centerY) * scale
    }

    /// 整块画布的数据矩形。
    public var dataBounds: DataBounds {
        DataBounds(minX: xRange.lowerBound, maxX: xRange.upperBound,
                   minY: yRange.lowerBound, maxY: yRange.upperBound)
    }

    /// 只剩没被遮住那块的视口（中心、倍率不变）。导出用它：导出的是用户眼前那块，
    /// 不含侧栏底下的部分。
    public var unobscured: Viewport2D {
        Viewport2D(
            centerX: centerX,
            centerY: centerY,
            scale: scale,
            widthPixels: max(widthPixels - insetLeft - insetRight, 1),
            heightPixels: max(heightPixels - insetTop - insetBottom, 1)
        )
    }

    /// 同中心、同倍率，四周各外扩 `fraction` 个视口宽 / 高的视口。后台按它采样，拖动时
    /// 视口外那一圈已经有图（UniReader 画板「视口外扩一圈先出图」的同一个做法）。
    ///
    /// 外扩量取**整像素**：画面停稳时，这份几何到当前屏幕的变换只差一个整数平移，
    /// 区域填充的逐像素矩形仍然压在像素格上，不会被插值糊掉。
    public func expanded(by fraction: Double) -> Viewport2D {
        guard fraction > 0 else { return self }
        let marginX = (widthPixels * fraction).rounded()
        let marginY = (heightPixels * fraction).rounded()
        var out = self
        out.widthPixels = widthPixels + 2 * marginX
        out.heightPixels = heightPixels + 2 * marginY
        // 遮挡宽度跟着外扩，`focus` 才会正好平移 margin，数据到像素的对应关系不变。
        out.insetLeft = insetLeft + marginX
        out.insetRight = insetRight + marginX
        out.insetTop = insetTop + marginY
        out.insetBottom = insetBottom + marginY
        return out
    }

    /// 把「按 `source` 换算出的屏幕像素」映到本视口的屏幕像素。两个视口的缩放都是等比的，
    /// 所以结果只是一个等比缩放加平移：拖动、缩放时直接拿旧几何套这个变换画，
    /// 不必等后台重新采样。
    public func screenTransform(from source: Viewport2D) -> ScreenTransform2D {
        guard source.scale > 0, scale > 0 else { return .identity }
        let ratio = scale / source.scale
        return ScreenTransform2D(
            scale: ratio,
            translation: SIMD2(
                focusX - source.focusX * ratio + (source.centerX - centerX) * scale,
                focusY - source.focusY * ratio - (source.centerY - centerY) * scale
            )
        )
    }

    /// 缩放的上下限。放得太远整条曲线缩成一个点，放得太近双精度也撑不住。
    public static let scaleRange: ClosedRange<Double> = 1e-3...1e8

    public mutating func pan(byPixels delta: SIMD2<Double>) {
        centerX -= delta.x / scale
        centerY += delta.y / scale
    }

    /// Zooms about a fixed pixel anchor, so the data point under the cursor stays put.
    public mutating func zoom(by factor: Double, anchorPixel: SIMD2<Double>) {
        let anchorData = toData(anchorPixel)
        scale = min(max(scale * factor, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        let after = toData(anchorPixel)
        centerX += anchorData.x - after.x
        centerY += anchorData.y - after.y
    }

    /// Frames the given data-space rectangle with a small margin — 装进没被遮住的那块。
    public mutating func fit(minX: Double, maxX: Double, minY: Double, maxY: Double, margin: Double = 0.08) {
        let w = max(maxX - minX, .leastNormalMagnitude)
        let h = max(maxY - minY, .leastNormalMagnitude)
        let usableW = max(widthPixels - insetLeft - insetRight, 1) * (1 - 2 * margin)
        let usableH = max(heightPixels - insetTop - insetBottom, 1) * (1 - 2 * margin)
        scale = min(usableW / w, usableH / h)
        centerX = (minX + maxX) / 2
        centerY = (minY + maxY) / 2
    }
}

/// A "nice" tick spacing: 1, 2, 5 or 10 times a power of ten.
public enum AxisTicks {
    public struct Ticks: Sendable {
        public var major: [Double]
        public var minor: [Double]
        public var step: Double
        public var labelDecimals: Int
    }

    public static func niceStep(minimumDataStep: Double) -> Double {
        guard minimumDataStep > 0, minimumDataStep.isFinite else { return 1 }
        let exponent = (log10(minimumDataStep)).rounded(.down)
        let base = pow(10.0, exponent)
        let mantissa = minimumDataStep / base
        let niceMantissa: Double
        if mantissa <= 1 { niceMantissa = 1 }
        else if mantissa <= 2 { niceMantissa = 2 }
        else if mantissa <= 5 { niceMantissa = 5 }
        else { niceMantissa = 10 }
        return niceMantissa * base
    }

    public static func ticks(
        range: ClosedRange<Double>,
        pixelsPerUnit: Double,
        minimumPixelSpacing: Double = 78,
        minorDivisions: Int = 5
    ) -> Ticks {
        let span = range.upperBound - range.lowerBound
        guard span > 0, span.isFinite, pixelsPerUnit > 0 else {
            return Ticks(major: [], minor: [], step: 1, labelDecimals: 1)
        }
        let step = niceStep(minimumDataStep: minimumPixelSpacing / pixelsPerUnit)
        let first = (range.lowerBound / step).rounded(.up) * step
        var major: [Double] = []
        var value = first
        // Guard against pathological ranges producing millions of ticks.
        while value <= range.upperBound && major.count < 4096 {
            major.append(value == 0 ? 0 : value)
            value += step
        }

        let minorStep = step / Double(max(minorDivisions, 1))
        var minor: [Double] = []
        var m = (range.lowerBound / minorStep).rounded(.up) * minorStep
        while m <= range.upperBound && minor.count < 20000 {
            let isMajor = abs((m / step).rounded() * step - m) < step * 1e-6
            if !isMajor { minor.append(m) }
            m += minorStep
        }

        let decimals = max(0, min(12, Int(ceil(-log10(step))) + 1))
        return Ticks(major: major, minor: minor, step: step, labelDecimals: decimals)
    }
}
