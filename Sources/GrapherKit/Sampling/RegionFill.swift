import Foundation

/// Fills the set where an inequality on the field holds.
///
/// Interior comes out as a few wide rectangles (cheap), while the boundary is
/// resolved at *screen pixel* resolution: every pixel the boundary passes
/// through gets its coverage from sub-sampling the grid's bilinear interpolant.
/// Filled edges therefore end up as smooth as stroked ones.
public enum RegionFiller {
    public struct Result: Sendable {
        public var geometry: [SIMD4<Float>]
        public var coverage: [Float]

        public init(geometry: [SIMD4<Float>] = [], coverage: [Float] = []) {
            self.geometry = geometry
            self.coverage = coverage
        }

        public var count: Int { geometry.count }
    }

    public static func fill(
        grid: FieldGrid,
        relation: RegionRelation,
        pixelStep: Double,
        subSamples: Int = 8,
        limit: Int = 600_000
    ) -> Result {
        guard grid.cols >= 2, grid.rows >= 2, grid.values.count == grid.pointCount, pixelStep > 0 else {
            return Result()
        }

        // Flip the sign for `F >= 0` regions so that "inside" is always
        // "signed <= 0". That keeps the interpolant monotone in one direction.
        let lowerSide: Bool
        switch relation {
        case .less, .lessOrEqual: lowerSide = true
        case .greater, .greaterOrEqual: lowerSide = false
        }
        let sign: Double = lowerSide ? 1 : -1

        let cols = grid.cols
        let rows = grid.rows
        let blockCols = cols - 1
        let blockRows = rows - 1

        /// Bilinear value of the signed field at an arbitrary screen position.
        /// Values are looked up in whichever block actually contains the sample,
        /// so boundary pixels that straddle a block edge stay accurate.
        func signedAt(_ screenX: Double, _ screenY: Double) -> Double {
            let fx = screenX / pixelStep
            let fy = screenY / pixelStep
            var i = Int(fx.rounded(.down))
            var j = Int(fy.rounded(.down))
            i = min(max(i, 0), blockCols - 1)
            j = min(max(j, 0), blockRows - 1)
            let u = min(max(fx - Double(i), 0), 1)
            let v = min(max(fy - Double(j), 0), 1)
            let sa = sign * grid.value(i, j)
            let sb = sign * grid.value(i + 1, j)
            let sc = sign * grid.value(i + 1, j + 1)
            let sd = sign * grid.value(i, j + 1)
            guard sa.isFinite, sb.isFinite, sc.isFinite, sd.isFinite else { return .nan }
            return sa * (1 - u) * (1 - v) + sb * u * (1 - v) + sc * u * v + sd * (1 - u) * v
        }

        enum BlockClass: UInt8 { case empty = 0, interior = 1, partial = 2 }
        var classes = [BlockClass](repeating: .empty, count: blockCols * blockRows)

        for j in 0..<blockRows {
            for i in 0..<blockCols {
                let sa = sign * grid.value(i, j)
                let sb = sign * grid.value(i + 1, j)
                let sc = sign * grid.value(i + 1, j + 1)
                let sd = sign * grid.value(i, j + 1)
                guard sa.isFinite, sb.isFinite, sc.isFinite, sd.isFinite else { continue }
                let insideCount = (sa <= 0 ? 1 : 0) + (sb <= 0 ? 1 : 0) + (sc <= 0 ? 1 : 0) + (sd <= 0 ? 1 : 0)
                if insideCount == 4 {
                    classes[j * blockCols + i] = .interior
                } else if insideCount > 0 {
                    // A bilinear patch reaches its extrema at the corners, so a
                    // mix of inside/outside corners is exactly the partial case.
                    classes[j * blockCols + i] = .partial
                }
            }
        }

        let pixelWidth = Int((Double(blockCols) * pixelStep).rounded(.up))
        let pixelHeight = Int((Double(blockRows) * pixelStep).rounded(.up))

        var result = Result()
        result.geometry.reserveCapacity(8192)
        result.coverage.reserveCapacity(8192)

        // 1. Interior blocks, merged into horizontal runs.
        for j in 0..<blockRows {
            var i = 0
            while i < blockCols {
                guard classes[j * blockCols + i] == .interior else {
                    i += 1
                    continue
                }
                let runStart = i
                while i < blockCols && classes[j * blockCols + i] == .interior { i += 1 }
                result.geometry.append(SIMD4(
                    Float(Double(runStart) * pixelStep),
                    Float(Double(i) * pixelStep),
                    Float(Double(j) * pixelStep),
                    Float(Double(j + 1) * pixelStep)
                ))
                result.coverage.append(1)
                if result.count >= limit { return result }
            }
        }

        // 2. Boundary pixels. Collect them first so a pixel touched by two
        //    partial blocks is still only emitted once.
        var marked = [Bool](repeating: false, count: max(pixelWidth * pixelHeight, 1))
        var markedIndices: [Int] = []
        markedIndices.reserveCapacity(4096)

        for j in 0..<blockRows {
            for i in 0..<blockCols {
                guard classes[j * blockCols + i] == .partial else { continue }
                let x0 = Int((Double(i) * pixelStep).rounded(.down))
                let x1 = Int((Double(i + 1) * pixelStep).rounded(.up))
                let y0 = Int((Double(j) * pixelStep).rounded(.down))
                let y1 = Int((Double(j + 1) * pixelStep).rounded(.up))
                for py in max(y0, 0)..<min(y1, pixelHeight) {
                    for px in max(x0, 0)..<min(x1, pixelWidth) {
                        let index = py * pixelWidth + px
                        if !marked[index] {
                            marked[index] = true
                            markedIndices.append(index)
                        }
                    }
                }
            }
        }

        let subCount = max(2, subSamples)
        let subTotal = Double(subCount * subCount)
        var offsets = [Double](repeating: 0, count: subCount)
        for k in 0..<subCount { offsets[k] = (Double(k) + 0.5) / Double(subCount) }

        for index in markedIndices {
            let px = index % pixelWidth
            let py = index / pixelWidth
            let baseX = Double(px)
            let baseY = Double(py)
            var hits = 0
            for dy in offsets {
                for dx in offsets {
                    let value = signedAt(baseX + dx, baseY + dy)
                    if value <= 0 { hits += 1 }
                }
            }
            guard hits > 0 else { continue }
            result.geometry.append(SIMD4(
                Float(baseX), Float(baseX + 1), Float(baseY), Float(baseY + 1)
            ))
            result.coverage.append(Float(Double(hits) / subTotal))
            if result.count >= limit { return result }
        }

        return result
    }
}
