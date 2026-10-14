import Foundation
import simd

/// 两张三角网格曲面的交线。显式、参数、隐式曲面采样出来都是 `Mesh3D`，所以不分图型组合，一条路算：
/// 逐对三角形求交得到一堆线段，再按端点拼成折线。
///
/// 精度就是网格的精度：交线上的点落在两张分段线性曲面上，离真曲面的误差是网格间距的平方量级
/// （180 格时约 1e-4 个盒半边长，不到 0.1 像素）。
///
/// 全部在盒内归一化坐标里算（盒子 = [-1, 1]³），结果也是归一化坐标，并按盒子裁齐。
public enum MeshIntersection {

    /// 交线裁到盒子外多出一点，免得线在盒面上留一道缝（渲染时盒面会把多出的部分裁掉）。
    static let boxLimit = 1.001
    /// 加速网格每一轴的格数，覆盖 [-gridExtent, gridExtent]。
    static let gridCells = 48
    static let gridExtent = 1.5
    /// 两个端点近到这个距离（归一化单位）就当成同一个点。
    static let joinTolerance = 1e-6
    /// 比这短的折线（归一化单位）是网格相切处擦出来的渣，不要。
    static let minimumLength = 1e-3

    struct Triangle {
        var a: SIMD3<Double>
        var b: SIMD3<Double>
        var c: SIMD3<Double>
    }

    struct Segment {
        var p: SIMD3<Double>
        var q: SIMD3<Double>
    }

    public static func curves(_ first: Mesh3D, _ second: Mesh3D) -> [[SIMD3<Double>]] {
        let ta = triangles(first)
        let tb = triangles(second)
        guard !ta.isEmpty, !tb.isEmpty else { return [] }
        return stitch(intersect(ta, tb).compactMap(clip))
    }

    static func triangles(_ mesh: Mesh3D) -> [Triangle] {
        var result: [Triangle] = []
        result.reserveCapacity(mesh.triangleCount)
        for t in 0..<mesh.triangleCount {
            let a = SIMD3<Double>(mesh.vertices[Int(mesh.indices[3 * t])].position)
            let b = SIMD3<Double>(mesh.vertices[Int(mesh.indices[3 * t + 1])].position)
            let c = SIMD3<Double>(mesh.vertices[Int(mesh.indices[3 * t + 2])].position)
            result.append(Triangle(a: a, b: b, c: c))
        }
        return result
    }

    // MARK: - 求交

    private static let cellSize = 2 * gridExtent / Double(gridCells)

    private static func cellRange(_ t: Triangle) -> (SIMD3<Int>, SIMD3<Int>) {
        let lower = simd_min(simd_min(t.a, t.b), t.c)
        let upper = simd_max(simd_max(t.a, t.b), t.c)
        func cell(_ v: SIMD3<Double>) -> SIMD3<Int> {
            SIMD3(
                min(max(Int(((v.x + gridExtent) / cellSize).rounded(.down)), 0), gridCells - 1),
                min(max(Int(((v.y + gridExtent) / cellSize).rounded(.down)), 0), gridCells - 1),
                min(max(Int(((v.z + gridExtent) / cellSize).rounded(.down)), 0), gridCells - 1)
            )
        }
        return (cell(lower), cell(upper))
    }

    private static func intersect(_ ta: [Triangle], _ tb: [Triangle]) -> [Segment] {
        // 第二张网格的三角形按包围盒登记进加速网格（CSR 排布）。
        let cellTotal = gridCells * gridCells * gridCells
        var start = [Int32](repeating: 0, count: cellTotal + 1)
        func forEachCell(_ t: Triangle, _ body: (Int) -> Void) {
            let (lo, hi) = cellRange(t)
            for z in lo.z...hi.z {
                for y in lo.y...hi.y {
                    for x in lo.x...hi.x { body((z * gridCells + y) * gridCells + x) }
                }
            }
        }
        for t in tb { forEachCell(t) { start[$0 + 1] += 1 } }
        for i in 0..<cellTotal { start[i + 1] += start[i] }
        var fill = start
        var entries = [Int32](repeating: 0, count: Int(start[cellTotal]))
        for (index, t) in tb.enumerated() {
            forEachCell(t) { cell in
                entries[Int(fill[cell])] = Int32(index)
                fill[cell] += 1
            }
        }

        let chunkCount = max(1, min(ta.count / 1024, ProcessInfo.processInfo.activeProcessorCount * 4))
        var results = [[Segment]](repeating: [], count: chunkCount)
        results.withUnsafeMutableBufferPointer { output in
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                let from = ta.count * chunk / chunkCount
                let to = ta.count * (chunk + 1) / chunkCount
                var stamp = [Int32](repeating: -1, count: tb.count)
                var local: [Segment] = []
                for i in from..<to {
                    let a = ta[i]
                    forEachCell(a) { cell in
                        for k in Int(start[cell])..<Int(start[cell + 1]) {
                            let j = Int(entries[k])
                            if stamp[j] == Int32(i) { continue }
                            stamp[j] = Int32(i)
                            if let s = intersection(a, tb[j]) { local.append(s) }
                        }
                    }
                }
                output[chunk] = local
            }
        }
        return results.flatMap { $0 }
    }

    // MARK: - 三角形对三角形

    private static func lexLess(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
        if a.x != b.x { return a.x < b.x }
        if a.y != b.y { return a.y < b.y }
        return a.z < b.z
    }

    /// 线段 pq 与平面的交点，dp / dq 是两端到平面的有向距离。两端按坐标排好序再算：
    /// 共用这条边的相邻三角形算出来的点逐位相同，拼折线时端点对得上。
    private static func crossing(
        _ p: SIMD3<Double>, _ dp: Double, _ q: SIMD3<Double>, _ dq: Double
    ) -> SIMD3<Double> {
        if lexLess(q, p) { return crossing(q, dq, p, dp) }
        return p + (q - p) * (dp / (dp - dq))
    }

    /// 一个三角形被另一个三角形所在平面截出的线段两端。距离恰为 0 的顶点一律算在正的一侧，
    /// 这样恰好过格点的交线不会漏、也不会算两遍；三个顶点同侧（含共面）返回 nil。
    private static func cut(
        _ t: Triangle, _ d: SIMD3<Double>
    ) -> (SIMD3<Double>, SIMD3<Double>)? {
        let positive = (d.x >= 0, d.y >= 0, d.z >= 0)
        if positive.0 == positive.1 && positive.1 == positive.2 { return nil }
        let corners = [t.a, t.b, t.c]
        let distances = [d.x, d.y, d.z]
        var points: [SIMD3<Double>] = []
        for (i, j) in [(0, 1), (1, 2), (2, 0)] {
            if (distances[i] >= 0) != (distances[j] >= 0) {
                points.append(crossing(corners[i], distances[i], corners[j], distances[j]))
            }
        }
        guard points.count == 2 else { return nil }
        return (points[0], points[1])
    }

    static func intersection(_ a: Triangle, _ b: Triangle) -> Segment? {
        let nb = simd_cross(b.b - b.a, b.c - b.a)
        let na = simd_cross(a.b - a.a, a.c - a.a)
        guard simd_length_squared(nb) > 1e-24, simd_length_squared(na) > 1e-24 else { return nil }

        let da = SIMD3(simd_dot(nb, a.a - b.a), simd_dot(nb, a.b - b.a), simd_dot(nb, a.c - b.a))
        guard let (a1, a2) = cut(a, da) else { return nil }
        let db = SIMD3(simd_dot(na, b.a - a.a), simd_dot(na, b.b - a.a), simd_dot(na, b.c - a.a))
        guard let (b1, b2) = cut(b, db) else { return nil }

        // 两个三角形的截线都落在两个平面的交线上，沿这条线取区间的重叠部分。
        let direction = simd_cross(na, nb)
        guard simd_length_squared(direction) > 0 else { return nil }
        let (aLow, aHigh) = ordered(a1, a2, along: direction)
        let (bLow, bHigh) = ordered(b1, b2, along: direction)
        let low = simd_dot(direction, aLow) >= simd_dot(direction, bLow) ? aLow : bLow
        let high = simd_dot(direction, aHigh) <= simd_dot(direction, bHigh) ? aHigh : bHigh
        guard simd_dot(direction, high) > simd_dot(direction, low) else { return nil }
        return Segment(p: low, q: high)
    }

    private static func ordered(
        _ p: SIMD3<Double>, _ q: SIMD3<Double>, along direction: SIMD3<Double>
    ) -> (SIMD3<Double>, SIMD3<Double>) {
        simd_dot(direction, p) <= simd_dot(direction, q) ? (p, q) : (q, p)
    }

    // MARK: - 裁剪

    /// 线段裁进盒子（Liang–Barsky）；完全在盒外返回 nil。
    private static func clip(_ s: Segment) -> Segment? {
        var t0 = 0.0, t1 = 1.0
        let d = s.q - s.p
        for axis in 0..<3 {
            for (sign, bound) in [(-1.0, -boxLimit), (1.0, boxLimit)] {
                // 要求 sign * (p + t d) <= sign * bound
                let numerator = sign * bound - sign * s.p[axis]
                let denominator = sign * d[axis]
                if denominator == 0 {
                    if numerator < 0 { return nil }
                } else {
                    let t = numerator / denominator
                    if denominator > 0 { t1 = min(t1, t) } else { t0 = max(t0, t) }
                    if t0 > t1 { return nil }
                }
            }
        }
        return Segment(p: s.p + d * t0, q: s.p + d * t1)
    }

    // MARK: - 拼折线

    private struct Edge: Hashable {
        var u: Int
        var v: Int
    }

    /// 把一堆线段按端点拼成折线：端点近到 `joinTolerance` 的合成一个结点，
    /// 沿度为 2 的结点一路走下去；遇到端点（度 1）或分叉（度 ≥ 3）就断，剩下的环单独走一遍。
    static func stitch(_ segments: [Segment]) -> [[SIMD3<Double>]] {
        var points: [SIMD3<Double>] = []
        var buckets: [SIMD3<Int>: [Int]] = [:]
        let tolerance = joinTolerance

        func node(_ p: SIMD3<Double>) -> Int {
            let key = SIMD3<Int>(
                Int((p.x / tolerance).rounded(.down)),
                Int((p.y / tolerance).rounded(.down)),
                Int((p.z / tolerance).rounded(.down))
            )
            for dz in -1...1 {
                for dy in -1...1 {
                    for dx in -1...1 {
                        guard let candidates = buckets[key &+ SIMD3(dx, dy, dz)] else { continue }
                        for id in candidates where simd_length_squared(points[id] - p) <= tolerance * tolerance {
                            return id
                        }
                    }
                }
            }
            points.append(p)
            buckets[key, default: []].append(points.count - 1)
            return points.count - 1
        }

        var edgeSet = Set<Edge>()
        var edges: [Edge] = []
        for s in segments {
            let u = node(s.p)
            let v = node(s.q)
            guard u != v else { continue }
            let edge = Edge(u: min(u, v), v: max(u, v))
            if edgeSet.insert(edge).inserted { edges.append(edge) }
        }

        var adjacency = [[Int]](repeating: [], count: points.count)
        for (id, edge) in edges.enumerated() {
            adjacency[edge.u].append(id)
            adjacency[edge.v].append(id)
        }

        var visited = [Bool](repeating: false, count: edges.count)

        /// 从 `start` 沿边 `first` 走，直到碰上端点 / 分叉，或绕回已走过的边。
        func walk(from start: Int, along first: Int) -> [Int] {
            var path = [start]
            var current = start
            var edge = first
            while true {
                visited[edge] = true
                let e = edges[edge]
                current = e.u == current ? e.v : e.u
                path.append(current)
                guard adjacency[current].count == 2,
                      let next = adjacency[current].first(where: { !visited[$0] }) else { break }
                edge = next
            }
            return path
        }

        var paths: [[Int]] = []
        for n in points.indices where adjacency[n].count != 2 {
            for edge in adjacency[n] where !visited[edge] { paths.append(walk(from: n, along: edge)) }
        }
        for (id, edge) in edges.enumerated() where !visited[id] { paths.append(walk(from: edge.u, along: id)) }

        return paths.compactMap { path in
            let line = path.map { points[$0] }
            var length = 0.0
            for i in 1..<line.count { length += simd_length(line[i] - line[i - 1]) }
            return length >= minimumLength ? line : nil
        }
    }
}
