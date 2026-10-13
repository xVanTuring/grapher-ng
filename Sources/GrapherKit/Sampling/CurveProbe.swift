import Foundation

/// Result of pointing at the canvas: the point on the nearest curve, plus
/// enough context for the read-out.
public struct ProbeHit: Sendable {
    public var layerID: UUID
    public var layerName: String
    public var color: RGBAColor
    public var kind: PlotKind
    public var dataPoint: SIMD2<Double>
    public var screenPoint: SIMD2<Double>
    public var distancePixels: Double
    /// dy/dx at the hit, when the curve is a graph over x.
    public var slope: Double?
}

public enum CurveProbe {
    /// Finds the closest point on any of the sampled curves.
    ///
    /// The viewport transform is a uniform scale plus a translation, so a
    /// distance in data space converts to pixels by multiplying by `scale`.
    /// Working in data space avoids projecting every sample.
    public static func nearest(
        curves: [ProbeCurve],
        toPixel pixel: SIMD2<Double>,
        viewport: Viewport2D,
        maxDistancePixels: Double = 28
    ) -> ProbeHit? {
        guard viewport.scale > 0, !curves.isEmpty else { return nil }
        let target = viewport.toData(pixel)
        let thresholdData = maxDistancePixels / viewport.scale
        let thresholdSquared = thresholdData * thresholdData

        var bestDistanceSquared = thresholdSquared
        var best: ProbeHit?

        for curve in curves {
            for segment in curve.segments {
                guard segment.count >= 2 else { continue }
                for index in 0..<(segment.count - 1) {
                    let a = segment[index]
                    let b = segment[index + 1]
                    let closest = closestPointOnSegment(target, a, b)
                    let dx = closest.x - target.x
                    let dy = closest.y - target.y
                    let distanceSquared = dx * dx + dy * dy
                    guard distanceSquared < bestDistanceSquared else { continue }
                    bestDistanceSquared = distanceSquared

                    var slope: Double?
                    if curve.kind == .explicit, b.x != a.x {
                        slope = (b.y - a.y) / (b.x - a.x)
                    }
                    best = ProbeHit(
                        layerID: curve.layerID,
                        layerName: curve.layerName,
                        color: curve.color,
                        kind: curve.kind,
                        dataPoint: closest,
                        screenPoint: viewport.toScreen(x: closest.x, y: closest.y),
                        distancePixels: distanceSquared.squareRoot() * viewport.scale,
                        slope: slope
                    )
                }
            }
        }

        return best
    }

    static func closestPointOnSegment(
        _ p: SIMD2<Double>,
        _ a: SIMD2<Double>,
        _ b: SIMD2<Double>
    ) -> SIMD2<Double> {
        let ab = b - a
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        guard lengthSquared > 0, lengthSquared.isFinite else { return a }
        var t = ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lengthSquared
        t = min(max(t, 0), 1)
        return a + ab * t
    }
}
