import Foundation

/// Maps between data space and viewport pixels.
///
/// The scale is deliberately *uniform* on both axes so that shapes keep their
/// true proportions — a circle has to look like a circle.
public struct Viewport2D: Equatable, Sendable, Codable {
    /// Data-space point shown at the centre of the viewport.
    public var centerX: Double
    public var centerY: Double
    /// Backing pixels per data unit.
    public var scale: Double
    /// Viewport size in backing pixels.
    public var widthPixels: Double
    public var heightPixels: Double

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

    public var halfWidthData: Double { widthPixels / 2 / scale }
    public var halfHeightData: Double { heightPixels / 2 / scale }

    public var xRange: ClosedRange<Double> {
        (centerX - halfWidthData)...(centerX + halfWidthData)
    }

    public var yRange: ClosedRange<Double> {
        (centerY - halfHeightData)...(centerY + halfHeightData)
    }

    public func toScreen(x: Double, y: Double) -> SIMD2<Double> {
        SIMD2((x - centerX) * scale + widthPixels / 2, heightPixels / 2 - (y - centerY) * scale)
    }

    public func toData(_ p: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(
            (p.x - widthPixels / 2) / scale + centerX,
            (heightPixels / 2 - p.y) / scale + centerY
        )
    }

    public func screenToDataX(_ px: Double) -> Double {
        (px - widthPixels / 2) / scale + centerX
    }

    public func screenToDataY(_ py: Double) -> Double {
        (heightPixels / 2 - py) / scale + centerY
    }

    public func dataToScreenX(_ x: Double) -> Double {
        (x - centerX) * scale + widthPixels / 2
    }

    public func dataToScreenY(_ y: Double) -> Double {
        heightPixels / 2 - (y - centerY) * scale
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

    /// Frames the given data-space rectangle with a small margin.
    public mutating func fit(minX: Double, maxX: Double, minY: Double, maxY: Double, margin: Double = 0.08) {
        let w = max(maxX - minX, .leastNormalMagnitude)
        let h = max(maxY - minY, .leastNormalMagnitude)
        let usableW = widthPixels * (1 - 2 * margin)
        let usableH = heightPixels * (1 - 2 * margin)
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
