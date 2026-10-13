import Foundation
import simd

/// 空间曲线 (x, y, z) = F(t) 的自适应采样。
///
/// 误差在**盒内归一化坐标**里量：相机怎么转都不用重采，只有盒子变了（平移、缩放）才重来。
/// 弦高容差约合屏幕上零点几个像素（盒子在屏幕上大约六七百像素宽，即 2 个归一化单位）。
public enum SpaceCurveSampler {

    public struct Options: Sendable {
        /// 弦高容差，归一化单位。
        public var tolerance: Double
        /// 相邻两段的最大转角，弧度。
        public var angleTolerance: Double
        public var maxDepth: Int

        public init(tolerance: Double, angleTolerance: Double = 0.05, maxDepth: Int = 9) {
            self.tolerance = tolerance
            self.angleTolerance = angleTolerance
            self.maxDepth = maxDepth
        }
    }

    public static func options(for quality: SampleQuality) -> Options {
        switch quality {
        case .interactive: return Options(tolerance: 0.004, maxDepth: 6)
        case .full: return Options(tolerance: 0.0012, maxDepth: 9)
        case .high: return Options(tolerance: 0.0005, maxDepth: 11)
        }
    }

    /// - Returns: 若干段连续折线（数据坐标）；遇到函数无定义（非有限值）的地方断开。
    public static func sample(
        f: (Double) -> SIMD3<Double>,
        tRange: ClosedRange<Double>,
        view: View3D,
        options: Options
    ) -> [[SIMD3<Double>]] {
        let lower = tRange.lowerBound
        let upper = tRange.upperBound
        guard lower.isFinite, upper.isFinite, upper > lower else { return [] }

        func normalized(_ p: SIMD3<Double>) -> SIMD3<Double> { view.normalized(p) }

        // 先粗探一遍长度，长的曲线给更多初始采样点。
        let probes = 256
        var length = 0.0
        var previous = normalized(f(lower))
        for i in 1...probes {
            let t = i == probes ? upper : lower + (upper - lower) * Double(i) / Double(probes)
            let point = normalized(f(t))
            if isFinite(point), isFinite(previous) { length += min(simd_length(point - previous), 4) }
            previous = point
        }
        let baseCount = min(max(Int(length * 80) + 64, 64), 40_000)

        var runs: [[SIMD3<Double>]] = []
        var run: [SIMD3<Double>] = []
        var previousT = lower
        var previousPoint: SIMD3<Double>?

        func flush() {
            if run.count >= 2 { runs.append(run) }
            run.removeAll(keepingCapacity: true)
        }

        func refine(_ t0: Double, _ p0: SIMD3<Double>, _ t1: Double, _ p1: SIMD3<Double>, depth: Int) {
            let tm = (t0 + t1) / 2
            guard depth < options.maxDepth, tm != t0, tm != t1 else { run.append(p1); return }
            let pm = f(tm)
            guard isFinite(pm) else { run.append(p1); return }
            let n0 = normalized(p0), n1 = normalized(p1), nm = normalized(pm)
            let chord = n1 - n0
            let span = simd_length(chord)
            if span < 1e-5 { run.append(p1); return }
            let deviation = simd_length(simd_cross(nm - n0, chord)) / span
            if deviation <= options.tolerance, turn(n0, nm, n1) <= options.angleTolerance {
                run.append(p1)
                return
            }
            refine(t0, p0, tm, pm, depth: depth + 1)
            refine(tm, pm, t1, p1, depth: depth + 1)
        }

        for i in 0..<baseCount {
            let t = i == baseCount - 1 ? upper : lower + (upper - lower) * Double(i) / Double(baseCount - 1)
            let point = f(t)
            guard isFinite(point) else {
                flush()
                previousPoint = nil
                continue
            }
            if let p0 = previousPoint {
                refine(previousT, p0, t, point, depth: 0)
            } else {
                run.append(point)
            }
            previousT = t
            previousPoint = point
        }
        flush()
        return runs
    }

    private static func isFinite(_ p: SIMD3<Double>) -> Bool {
        p.x.isFinite && p.y.isFinite && p.z.isFinite
    }

    private static func turn(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> Double {
        let u = b - a, v = c - b
        let lu = simd_length(u), lv = simd_length(v)
        guard lu > 0, lv > 0 else { return 0 }
        return acos(min(max(simd_dot(u, v) / (lu * lv), -1), 1))
    }
}
