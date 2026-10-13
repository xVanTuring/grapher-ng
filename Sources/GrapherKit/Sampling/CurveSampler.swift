import Foundation

/// Turns the analytic description of a curve into a polyline that is smooth
/// enough to be drawn at the current zoom level.
public enum CurveSampler {

    public struct Options: Sendable {
        public var tolerancePixels: Double
        public var samplesPerPixel: Double
        public var maxDepth: Int
    }

    public static func options(for quality: SampleQuality) -> Options {
        switch quality {
        case .interactive:
            return Options(tolerancePixels: 0.55, samplesPerPixel: 0.35, maxDepth: 5)
        case .full:
            return Options(tolerancePixels: 0.14, samplesPerPixel: 1.0, maxDepth: 7)
        case .high:
            return Options(tolerancePixels: 0.06, samplesPerPixel: 2.0, maxDepth: 9)
        }
    }

    // MARK: - y = f(x)

    public static func sampleExplicit(
        f: (Double) -> Double,
        xRange: ClosedRange<Double>,
        viewport: Viewport2D,
        quality: SampleQuality
    ) -> SampledCurve {
        let options = options(for: quality)
        let lower = xRange.lowerBound
        let upper = xRange.upperBound
        guard lower.isFinite, upper.isFinite, upper > lower else { return SampledCurve() }

        let baseCount = clampCount(
            Int(viewport.widthPixels * options.samplesPerPixel * 0.5),
            low: 64,
            high: 20000
        )
        let step = (upper - lower) / Double(baseCount - 1)

        var xs = [Double](repeating: 0, count: baseCount)
        var ys = [Double](repeating: 0, count: baseCount)
        for i in 0..<baseCount {
            let x = i == baseCount - 1 ? upper : lower + step * Double(i)
            xs[i] = x
            ys[i] = f(x)
        }

        let project: (SIMD2<Double>) -> SIMD2<Double> = { viewport.toScreen(x: $0.x, y: $0.y) }
        let refiner = AdaptiveRefiner(
            tolerancePixels: options.tolerancePixels,
            maxDepth: options.maxDepth,
            project: project
        )

        // A jump this tall over this short a horizontal run is a pole, not a
        // steep-but-continuous piece of curve.
        let jumpThreshold = viewport.heightPixels * 0.55
        let steepRunPixels = 4.0

        var result: SampledCurve = SampledCurve()
        var run: [SIMD2<Double>] = []
        run.reserveCapacity(baseCount / 4 + 8)

        func flushRun() {
            if run.count >= 2 { result.segments.append(run) }
            run.removeAll(keepingCapacity: true)
        }

        let explicit: (Double) -> SIMD2<Double> = { SIMD2($0, f($0)) }
        var previousIndex = -1

        for i in 0..<baseCount {
            let y = ys[i]
            guard y.isFinite else {
                flushRun()
                previousIndex = -1
                continue
            }
            let point = SIMD2(xs[i], y)
            guard previousIndex >= 0 else {
                run.append(point)
                previousIndex = i
                continue
            }
            let previous = run[run.count - 1]
            let dyPixels = abs(ys[previousIndex] - y) * viewport.scale
            let dxPixels = abs(xs[i] - xs[previousIndex]) * viewport.scale
            if dyPixels > jumpThreshold && dxPixels < steepRunPixels {
                flushRun()
                run.append(point)
                previousIndex = i
                continue
            }
            refiner.refine(
                explicit,
                t0: xs[previousIndex],
                p0: previous,
                t1: xs[i],
                p1: point,
                depth: 0,
                into: &run
            )
            previousIndex = i
        }
        flushRun()
        return result
    }

    // MARK: - (x, y) = F(t)

    public static func sampleParametric(
        tRange: ClosedRange<Double>,
        f: (Double) -> SIMD2<Double>,
        viewport: Viewport2D,
        quality: SampleQuality
    ) -> SampledCurve {
        let options = options(for: quality)
        let lower = tRange.lowerBound
        let upper = tRange.upperBound
        guard lower.isFinite, upper.isFinite, upper > lower else { return SampledCurve() }

        let project: (SIMD2<Double>) -> SIMD2<Double> = { viewport.toScreen(x: $0.x, y: $0.y) }

        // Probe the screen-space length so a long curve gets more base samples
        // than a short one.
        let probeCount = 256
        let probeStep = (upper - lower) / Double(probeCount)
        let lengthCap = max(viewport.widthPixels, viewport.heightPixels) * 4
        var length = 0.0
        var previous = project(f(lower))
        for i in 1...probeCount {
            let t = i == probeCount ? upper : lower + probeStep * Double(i)
            let point = project(f(t))
            if point.x.isFinite, point.y.isFinite, previous.x.isFinite, previous.y.isFinite {
                length += min(GeometryMath.simdLength(point - previous), lengthCap)
            }
            previous = point
        }

        let baseCount = clampCount(
            Int(length * options.samplesPerPixel * 0.5) + 32,
            low: 64,
            high: 40000
        )
        let step = (upper - lower) / Double(baseCount - 1)
        let refiner = AdaptiveRefiner(
            tolerancePixels: options.tolerancePixels,
            maxDepth: options.maxDepth,
            project: project
        )

        var result: SampledCurve = SampledCurve()
        var run: [SIMD2<Double>] = []
        run.reserveCapacity(baseCount / 4 + 8)

        func flushRun() {
            if run.count >= 2 { result.segments.append(run) }
            run.removeAll(keepingCapacity: true)
        }

        var previousT = lower
        var hasPrevious = false

        for i in 0..<baseCount {
            let t = i == baseCount - 1 ? upper : lower + step * Double(i)
            let point = f(t)
            guard point.x.isFinite, point.y.isFinite else {
                flushRun()
                hasPrevious = false
                continue
            }
            guard hasPrevious else {
                run.append(point)
                previousT = t
                hasPrevious = true
                continue
            }
            let previousPoint = run[run.count - 1]
            refiner.refine(f, t0: previousT, p0: previousPoint, t1: t, p1: point, depth: 0, into: &run)
            previousT = t
        }
        flushRun()
        return result
    }

    // MARK: - r = f(theta)

    public static func samplePolar(
        r: (Double) -> Double,
        thetaRange: ClosedRange<Double>,
        viewport: Viewport2D,
        quality: SampleQuality
    ) -> SampledCurve {
        let f: (Double) -> SIMD2<Double> = { theta in
            let radius = r(theta)
            return SIMD2(radius * cos(theta), radius * sin(theta))
        }
        return sampleParametric(tRange: thetaRange, f: f, viewport: viewport, quality: quality)
    }

    static func clampCount(_ value: Int, low: Int, high: Int) -> Int {
        Swift.min(Swift.max(value, low), high)
    }
}
