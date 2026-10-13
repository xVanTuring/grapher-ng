import Foundation

/// A scalar field sampled on a regular grid that lines up with the viewport's
/// pixel grid. This single grid serves both the implicit-contour solver and the
/// region filler, so a layer only ever pays for one pass of evaluations.
public struct FieldGrid: Sendable {
    public let cols: Int
    public let rows: Int
    /// Data-space position of grid point (0, 0) — the top-left of the viewport.
    public let originX: Double
    public let originY: Double
    public let stepX: Double
    public let stepY: Double
    /// Row-major, `values[j * cols + i]`. `originY + stepY * j` decreases as `j`
    /// grows, because screen rows run downwards.
    public var values: [Double]

    public init(
        cols: Int,
        rows: Int,
        originX: Double,
        originY: Double,
        stepX: Double,
        stepY: Double,
        values: [Double]
    ) {
        self.cols = cols
        self.rows = rows
        self.originX = originX
        self.originY = originY
        self.stepX = stepX
        self.stepY = stepY
        self.values = values
    }

    /// Lays out a grid whose points sit on the viewport's pixel lattice.
    public init(viewport: Viewport2D, quality: SampleQuality, extraMargin: Double = 0) {
        let pixelStep = 1.0 / quality.samplesPerPixel
        let width = viewport.widthPixels + extraMargin * 2
        let height = viewport.heightPixels + extraMargin * 2
        let cols = max(2, Int((width / pixelStep).rounded(.up)) + 1)
        let rows = max(2, Int((height / pixelStep).rounded(.up)) + 1)

        let firstScreenX = -extraMargin
        let firstScreenY = -extraMargin
        let lastScreenX = firstScreenX + Double(cols - 1) * pixelStep
        let lastScreenY = firstScreenY + Double(rows - 1) * pixelStep

        let x0 = viewport.screenToDataX(firstScreenX)
        let x1 = viewport.screenToDataX(lastScreenX)
        let y0 = viewport.screenToDataY(firstScreenY)
        let y1 = viewport.screenToDataY(lastScreenY)

        self.cols = cols
        self.rows = rows
        self.originX = x0
        self.originY = y0
        self.stepX = (x1 - x0) / Double(cols - 1)
        self.stepY = (y1 - y0) / Double(rows - 1)
        self.values = []
    }

    public func dataX(_ i: Int) -> Double { originX + stepX * Double(i) }
    public func dataY(_ j: Int) -> Double { originY + stepY * Double(j) }
    public func value(_ i: Int, _ j: Int) -> Double { values[j * cols + i] }
    public var pointCount: Int { cols * rows }

    /// The screen-pixel position of a data-space point, for a grid built from
    /// that same viewport. Kept here so callers do not have to carry it around.
    public func screenPoint(_ i: Int, _ j: Int, viewport: Viewport2D) -> SIMD2<Double> {
        viewport.toScreen(x: dataX(i), y: dataY(j))
    }
}

public enum FieldEvaluator {
    /// Chunk size balances per-call overhead against peak memory.
    private static let chunkPoints = 8192

    /// Evaluates `expr` over the grid. The expression must be compiled against
    /// variables that include `"x"` and `"y"`.
    ///
    /// 分块摊到所有核上并行求值：`evaluateBatch` 可重入、无共享可变状态，每块只写自己那段
    /// 输出，互不重叠。全精度一屏几百万个点，单线程要上百毫秒，是重算里最大的一笔。
    public static func fill(_ grid: inout FieldGrid, expr: CompiledExpression) {
        guard let xSlot = expr.variables.firstIndex(of: "x"),
              let ySlot = expr.variables.firstIndex(of: "y")
        else {
            grid.values = [Double](repeating: .nan, count: grid.pointCount)
            return
        }

        let slotCount = expr.variables.count
        let total = grid.pointCount
        let cols = grid.cols
        let originX = grid.originX
        let originY = grid.originY
        let stepX = grid.stepX
        let stepY = grid.stepY
        let chunkCount = (total + chunkPoints - 1) / chunkPoints

        var values = [Double](repeating: .nan, count: total)
        values.withUnsafeMutableBufferPointer { output in
            guard let outputBase = output.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                let start = chunk * chunkPoints
                let count = min(chunkPoints, total - start)
                withUnsafeTemporaryAllocation(of: Double.self, capacity: count * slotCount) { input in
                    guard let inputBase = input.baseAddress else { return }
                    inputBase.initialize(repeating: 0, count: count * slotCount)
                    for k in 0..<count {
                        let index = start + k
                        let base = k * slotCount
                        inputBase[base + xSlot] = originX + stepX * Double(index % cols)
                        inputBase[base + ySlot] = originY + stepY * Double(index / cols)
                    }
                    expr.evaluateBatch(
                        UnsafeBufferPointer(input),
                        count: count,
                        into: UnsafeMutableBufferPointer(start: outputBase + start, count: count)
                    )
                }
            }
        }
        grid.values = values
    }
}

/// Extracts iso-contours from a `FieldGrid` and chains the resulting cell
/// segments into continuous polylines, so a contour is stroked as one path
/// rather than a shower of loose segments.
public enum MarchingSquares {
    /// Identifies a grid edge so that neighbouring cells agree on the crossing
    /// point bit-for-bit. `orientation` 0 is a horizontal edge (along x),
    /// 1 is vertical.
    struct EdgeKey: Hashable {
        let orientation: Int
        let a: Int
        let b: Int
    }

    struct Segment {
        var startKey: EdgeKey
        var endKey: EdgeKey
        var startPoint: SIMD2<Double>
        var endPoint: SIMD2<Double>
    }

    public static func contours(
        grid: FieldGrid,
        level: Double = 0,
        limit: Int = 4_000_000
    ) -> [[SIMD2<Double>]] {
        guard grid.cols >= 2, grid.rows >= 2, grid.values.count == grid.pointCount else { return [] }

        var segments: [Segment] = []
        segments.reserveCapacity(1024)

        let cols = grid.cols
        let rows = grid.rows

        // Corner state for the four cell corners in walk order.
        var inside = [Bool](repeating: false, count: 4)

        for j in 0..<(rows - 1) {
            for i in 0..<(cols - 1) {
                let va = grid.value(i, j)
                let vb = grid.value(i + 1, j)
                let vc = grid.value(i + 1, j + 1)
                let vd = grid.value(i, j + 1)
                let corners = [va, vb, vc, vd]
                guard corners.allSatisfy({ $0.isFinite }) else { continue }

                for k in 0..<4 { inside[k] = corners[k] > level }
                if inside[0] == inside[1] && inside[1] == inside[2] && inside[2] == inside[3] {
                    continue
                }

                let pa = SIMD2(grid.dataX(i), grid.dataY(j))
                let pb = SIMD2(grid.dataX(i + 1), grid.dataY(j))
                let pc = SIMD2(grid.dataX(i + 1), grid.dataY(j + 1))
                let pd = SIMD2(grid.dataX(i), grid.dataY(j + 1))
                let points = [pa, pb, pc, pd]
                let edgeKeys = [
                    EdgeKey(orientation: 0, a: j, b: i),          // a - b
                    EdgeKey(orientation: 1, a: i + 1, b: j),      // b - c
                    EdgeKey(orientation: 0, a: j + 1, b: i),      // d - c
                    EdgeKey(orientation: 1, a: i, b: j),          // a - d
                ]

                var crossingEdges: [Int] = []
                var crossingPoints: [SIMD2<Double>] = []
                for k in 0..<4 {
                    let next = (k + 1) % 4
                    guard inside[k] != inside[next] else { continue }
                    let v0 = corners[k]
                    let v1 = corners[next]
                    let denominator = v1 - v0
                    guard denominator != 0, denominator.isFinite else { continue }
                    var t = (level - v0) / denominator
                    if !t.isFinite { t = 0.5 }
                    t = min(max(t, 0), 1)
                    let p0 = points[k]
                    let p1 = points[next]
                    crossingEdges.append(k)
                    crossingPoints.append(SIMD2(p0.x + (p1.x - p0.x) * t, p0.y + (p1.y - p0.y) * t))
                }

                switch crossingEdges.count {
                case 2:
                    segments.append(Segment(
                        startKey: edgeKeys[crossingEdges[0]],
                        endKey: edgeKeys[crossingEdges[1]],
                        startPoint: crossingPoints[0],
                        endPoint: crossingPoints[1]
                    ))
                case 4:
                    // Ambiguous saddle: the cell-centre value decides whether the
                    // two arcs connect around the inside or the outside corners.
                    let centerInside = (va + vb + vc + vd) * 0.25 > level
                    let isCase5 = inside[0] && !inside[1] && inside[2] && !inside[3]
                    let pairFirst = isCase5 ? centerInside : !centerInside
                    let pairs: [(Int, Int)] = pairFirst
                        ? [(0, 1), (2, 3)]
                        : [(1, 2), (3, 0)]
                    for (m, n) in pairs {
                        segments.append(Segment(
                            startKey: edgeKeys[crossingEdges[m]],
                            endKey: edgeKeys[crossingEdges[n]],
                            startPoint: crossingPoints[m],
                            endPoint: crossingPoints[n]
                        ))
                    }
                default:
                    break
                }

                if segments.count > limit { return chain(segments) }
            }
        }

        return chain(segments)
    }

    /// Stitches cell segments into polylines by matching shared edges. Because
    /// an edge is shared by at most two cells, each edge carries at most two
    /// segment ends, which makes the walk unambiguous.
    static func chain(_ segments: [Segment]) -> [[SIMD2<Double>]] {
        guard !segments.isEmpty else { return [] }

        struct EndRef {
            var segment: Int
            var isStart: Bool
        }

        var adjacency: [EdgeKey: [EndRef]] = [:]
        adjacency.reserveCapacity(segments.count * 2)
        for (index, segment) in segments.enumerated() {
            adjacency[segment.startKey, default: []].append(EndRef(segment: index, isStart: true))
            adjacency[segment.endKey, default: []].append(EndRef(segment: index, isStart: false))
        }

        var visited = [Bool](repeating: false, count: segments.count)
        var polylines: [[SIMD2<Double>]] = []

        func nextStep(from key: EdgeKey, comingFrom segmentIndex: Int) -> EndRef? {
            guard let ends = adjacency[key] else { return nil }
            for end in ends where end.segment != segmentIndex && !visited[end.segment] {
                return end
            }
            return nil
        }

        for startIndex in 0..<segments.count where !visited[startIndex] {
            visited[startIndex] = true
            var forward: [SIMD2<Double>] = [segments[startIndex].startPoint, segments[startIndex].endPoint]
            var currentKey = segments[startIndex].endKey
            var currentSegment = startIndex
            while let next = nextStep(from: currentKey, comingFrom: currentSegment) {
                visited[next.segment] = true
                if next.isStart {
                    forward.append(segments[next.segment].endPoint)
                    currentKey = segments[next.segment].endKey
                } else {
                    forward.append(segments[next.segment].startPoint)
                    currentKey = segments[next.segment].startKey
                }
                currentSegment = next.segment
            }

            var backward: [SIMD2<Double>] = []
            var backKey = segments[startIndex].startKey
            var backSegment = startIndex
            while let next = nextStep(from: backKey, comingFrom: backSegment) {
                visited[next.segment] = true
                if next.isStart {
                    backward.append(segments[next.segment].endPoint)
                    backKey = segments[next.segment].endKey
                } else {
                    backward.append(segments[next.segment].startPoint)
                    backKey = segments[next.segment].startKey
                }
                backSegment = next.segment
            }

            var polyline = Array(backward.reversed())
            polyline.append(contentsOf: forward)
            if polyline.count >= 2 { polylines.append(polyline) }
        }

        return polylines
    }
}
