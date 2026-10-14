import Foundation
import simd

/// 在规则网格上批量求值，分块摊到所有核上（同 `FieldEvaluator.fill`）。曲面的二维参数网格、
/// 隐式曲面的三维体网格都走这里。
enum GridEvaluator {
    private static let chunkPoints = 8192

    /// - Parameters:
    ///   - counts: 每一维的点数，第一维变化最快。
    ///   - origins / steps: 每一维的起点与步长。
    ///   - names: 每一维的值填进表达式的哪个变量。
    /// - Returns: 按网格顺序排好的值；表达式里没有对应变量时全为 NaN。
    static func evaluate(
        _ expr: CompiledExpression,
        counts: [Int],
        origins: [Double],
        steps: [Double],
        names: [String]
    ) -> [Double] {
        let total = counts.reduce(1, *)
        guard total > 0 else { return [] }
        let slots = names.map { expr.variables.firstIndex(of: $0) }
        guard slots.allSatisfy({ $0 != nil }) else { return [Double](repeating: .nan, count: total) }
        let slotIndices = slots.map { $0! }
        let slotCount = expr.variables.count
        let dimensions = counts.count
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
                        var rest = start + k
                        let base = k * slotCount
                        for d in 0..<dimensions {
                            let index = rest % counts[d]
                            rest /= counts[d]
                            inputBase[base + slotIndices[d]] = origins[d] + steps[d] * Double(index)
                        }
                    }
                    expr.evaluateBatch(
                        UnsafeBufferPointer(input),
                        count: count,
                        into: UnsafeMutableBufferPointer(start: outputBase + start, count: count)
                    )
                }
            }
        }
        return values
    }
}

/// 规则网格上的点（数据坐标）连成三角网格。显式曲面与参数曲面共用。
enum SurfaceMesher {
    /// 归一化坐标夹在这个范围里：极点处的值会飞到 1e300，进 Float 就成了 inf。夹住之后盒内那一段的
    /// 形状几乎不变（网格很细），盒外的部分反正要被裁掉。
    static let coordinateLimit: Float = 1e4
    /// 一条边比这还长（归一化单位，盒子对角线约 3.5）就当成断开处，比如 1/x 在 x=0 两侧一正一负、
    /// 中间会被一面竖墙连起来。
    static let breakLength: Float = 4

    /// - Parameters:
    ///   - points: `cols × rows` 个点，第一维变化最快；非有限的点不出三角形。
    ///   - parameters: 每个点的网格线参数坐标（取整数处画线），nil 表示不画网格线。
    static func mesh(
        points: [SIMD3<Double>],
        cols: Int,
        rows: Int,
        parameters: [SIMD2<Float>]?,
        view: View3D,
        color: RGBAColor,
        scalars: [Float]? = nil
    ) -> Mesh3D {
        var mesh = Mesh3D(color: color, colorsByScalar: scalars != nil)
        guard cols >= 2, rows >= 2, points.count == cols * rows else { return mesh }

        let limit = coordinateLimit
        var positions = [SIMD3<Float>](repeating: .zero, count: points.count)
        var valid = [Bool](repeating: false, count: points.count)
        for (index, p) in points.enumerated() where p.x.isFinite && p.y.isFinite && p.z.isFinite {
            let n = view.normalized(p)
            positions[index] = simd_clamp(SIMD3<Float>(n), SIMD3(repeating: -limit), SIMD3(repeating: limit))
            valid[index] = true
        }

        var indices: [UInt32] = []
        indices.reserveCapacity((cols - 1) * (rows - 1) * 6)
        var normals = [SIMD3<Float>](repeating: .zero, count: points.count)
        let breakSquared = breakLength * breakLength

        func addTriangle(_ a: Int, _ b: Int, _ c: Int) {
            guard valid[a], valid[b], valid[c] else { return }
            let pa = positions[a], pb = positions[b], pc = positions[c]
            let longest = max(simd_length_squared(pb - pa), simd_length_squared(pc - pb), simd_length_squared(pa - pc))
            if longest > breakSquared { return }
            // 参数曲面的极点处（球面的 v = π）一排格点理论上重合、实际差 1e-17，那里的三角形面积几乎为零，
            // 算出的法向全是噪声：整个丢掉。其余三角形的法向按面积加权累加到顶点上。
            let cross = simd_cross(pb - pa, pc - pa)
            let length = simd_length(cross)
            guard length.isFinite, length > 1e-7 * longest else { return }
            normals[a] += cross
            normals[b] += cross
            normals[c] += cross
            indices.append(UInt32(a))
            indices.append(UInt32(b))
            indices.append(UInt32(c))
        }

        for j in 0..<(rows - 1) {
            for i in 0..<(cols - 1) {
                let a = j * cols + i
                let b = a + 1
                let d = a + cols
                let c = d + 1
                addTriangle(a, b, c)
                addTriangle(a, c, d)
            }
        }

        let none = SIMD2<Float>(.nan, .nan)
        mesh.vertices = (0..<points.count).map { index in
            let sum = normals[index]
            let length = simd_length(sum)
            return MeshVertex3D(
                position: positions[index],
                normal: length > 0 ? sum / length : SIMD3(0, 0, 1),
                parameter: parameters?[index] ?? none,
                scalar: scalars?[index] ?? 0
            )
        }
        mesh.indices = indices
        return mesh
    }
}
