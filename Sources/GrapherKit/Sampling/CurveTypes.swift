import Foundation

/// A curve after sampling, expressed as one or more continuous runs in data
/// space. Discontinuities (poles, jumps) produce separate runs so that no
/// spurious vertical line is ever drawn across a gap.
public struct SampledCurve: Sendable {
    public var segments: [[SIMD2<Double>]]

    public init(segments: [[SIMD2<Double>]] = []) {
        self.segments = segments
    }

    public var pointCount: Int {
        segments.reduce(0) { $0 + $1.count }
    }

    public var isEmpty: Bool {
        segments.allSatisfy { $0.count < 2 }
    }

    public func bounds() -> (minX: Double, maxX: Double, minY: Double, maxY: Double)? {
        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity
        var found = false
        for segment in segments {
            for point in segment where point.x.isFinite && point.y.isFinite {
                found = true
                minX = Swift.min(minX, point.x)
                maxX = Swift.max(maxX, point.x)
                minY = Swift.min(minY, point.y)
                maxY = Swift.max(maxY, point.y)
            }
        }
        guard found else { return nil }
        return (minX, maxX, minY, maxY)
    }
}

public enum GeometryMath {
    /// Shortest distance from `p` to the segment `a`–`b`, all in the same space.
    public static func distanceToSegment(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        guard lengthSquared > 0 else { return simdLength(p - a) }
        var t = ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lengthSquared
        t = Swift.min(Swift.max(t, 0), 1)
        let closest = a + ab * t
        return simdLength(p - closest)
    }

    public static func simdLength(_ v: SIMD2<Double>) -> Double {
        (v.x * v.x + v.y * v.y).squareRoot()
    }

    /// Signed turn angle between `a -> b` and `b -> c`, in radians, magnitude in
    /// `0...pi`.
    public static func turnAngle(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
        let u = b - a
        let v = c - b
        let lu = simdLength(u)
        let lv = simdLength(v)
        guard lu > 0, lv > 0 else { return 0 }
        let cross = u.x * v.y - u.y * v.x
        let dot = u.x * v.x + u.y * v.y
        return abs(atan2(cross, dot))
    }
}

/// Recursively splits a parametric interval until the chord is within a
/// fraction of a pixel of the true curve, so the rendered polyline is
/// indistinguishable from the analytic curve.
struct AdaptiveRefiner {
    var tolerancePixels: Double
    var angleTolerance: Double
    var maxDepth: Int
    /// Stop subdividing once the chord is this short on screen; keeps poles and
    /// other non-convergent spots from exploding the point count.
    var minimumScreenSpan: Double
    var project: (SIMD2<Double>) -> SIMD2<Double>

    init(
        tolerancePixels: Double,
        angleTolerance: Double = 0.035,
        maxDepth: Int = 7,
        minimumScreenSpan: Double = 0.05,
        project: @escaping (SIMD2<Double>) -> SIMD2<Double>
    ) {
        self.tolerancePixels = tolerancePixels
        self.angleTolerance = angleTolerance
        self.maxDepth = maxDepth
        self.minimumScreenSpan = minimumScreenSpan
        self.project = project
    }

    /// Appends the refined points of `p0...p1` to `out`. `p0` is assumed to be
    /// already present; `p1` is appended by the leaf call.
    func refine(
        _ f: (Double) -> SIMD2<Double>,
        t0: Double,
        p0: SIMD2<Double>,
        t1: Double,
        p1: SIMD2<Double>,
        depth: Int,
        into out: inout [SIMD2<Double>]
    ) {
        let s0 = project(p0)
        let s1 = project(p1)
        let tm = (t0 + t1) * 0.5
        if tm == t0 || tm == t1 {
            out.append(p1)
            return
        }
        let pm = f(tm)
        guard pm.x.isFinite, pm.y.isFinite else {
            out.append(p1)
            return
        }
        let sm = project(pm)
        let span = Swift.max(abs(s1.x - s0.x), abs(s1.y - s0.y))
        if depth >= maxDepth || span < minimumScreenSpan {
            out.append(p1)
            return
        }
        let deviation = GeometryMath.distanceToSegment(sm, s0, s1)
        if deviation <= tolerancePixels {
            let turn = GeometryMath.turnAngle(s0, sm, s1)
            if turn <= angleTolerance {
                out.append(p1)
                return
            }
        }
        refine(f, t0: t0, p0: p0, t1: tm, p1: pm, depth: depth + 1, into: &out)
        refine(f, t0: tm, p0: pm, t1: t1, p1: p1, depth: depth + 1, into: &out)
    }
}
