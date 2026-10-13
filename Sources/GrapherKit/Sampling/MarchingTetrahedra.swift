import Foundation
import simd

/// 隐式曲面 F(x, y, z) = 0：在坐标盒的体网格上求值，每个小立方体按同一条体对角线切成 6 个四面体，
/// 逐个四面体求 F 的零值面。
///
/// 用四面体而不用经典 marching cubes：每个四面体只有 0 / 1 / 2 个三角形三种情况，没有立方体那套
/// 二义性查表；相邻立方体按同一条对角线切，公共面上的三角剖分一致，拼出来的面不漏缝。
/// 法向取 F 的梯度（网格上中心差分，沿边插值），所以即使三角形不共享顶点，光照照样是光滑的。
public enum MarchingTetrahedra {

    /// 立方体 8 个角相对 (i, j, k) 的偏移。
    private static let cornerOffsets: [SIMD3<Int>] = [
        SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
        SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1),
    ]

    /// 沿体对角线 0–6 切出的 6 个四面体（Kuhn 剖分）。
    private static let tetrahedra: [(Int, Int, Int, Int)] = [
        (0, 5, 1, 6), (0, 1, 2, 6), (0, 2, 3, 6), (0, 3, 7, 6), (0, 7, 4, 6), (0, 4, 5, 6),
    ]

    /// - Parameters:
    ///   - values: `n³` 个格点上的 F 值（`n = cells + 1`），x 变化最快、z 最慢。
    ///   - cells: 每一轴的格数；格点铺满整个坐标盒。
    ///   - color: 曲面颜色。
    /// - Returns: 归一化坐标下的三角网格（每个三角形三个独立顶点）。
    public static func extract(values: [Double], cells: Int, color: RGBAColor) -> Mesh3D {
        var mesh = Mesh3D(color: color)
        let n = cells + 1
        guard cells >= 1, values.count == n * n * n else { return mesh }

        let slabCount = min(cells, max(1, ProcessInfo.processInfo.activeProcessorCount * 2))
        var slabs = [[MeshVertex3D]](repeating: [], count: slabCount)

        values.withUnsafeBufferPointer { field in
            slabs.withUnsafeMutableBufferPointer { output in
                DispatchQueue.concurrentPerform(iterations: slabCount) { slab in
                    let kStart = cells * slab / slabCount
                    let kEnd = cells * (slab + 1) / slabCount
                    var local: [MeshVertex3D] = []
                    for k in kStart..<kEnd {
                        march(layer: k, field: field, cells: cells, into: &local)
                    }
                    output[slab] = local
                }
            }
        }

        let total = slabs.reduce(0) { $0 + $1.count }
        mesh.vertices.reserveCapacity(total)
        for slab in slabs { mesh.vertices.append(contentsOf: slab) }
        mesh.indices = (0..<UInt32(total)).map { $0 }
        return mesh
    }

    /// 处理第 k 层的所有小立方体。
    private static func march(
        layer k: Int,
        field: UnsafeBufferPointer<Double>,
        cells: Int,
        into out: inout [MeshVertex3D]
    ) {
        let n = cells + 1
        let scale = 2.0 / Double(cells)
        let none = SIMD2<Float>(.nan, .nan)

        func index(_ p: SIMD3<Int>) -> Int { p.x + n * (p.y + n * p.z) }

        /// 格点处 F 的梯度（只要方向，不管单位）：中心差分，边界上用单侧差分。
        func gradient(_ p: SIMD3<Int>) -> SIMD3<Double> {
            var g = SIMD3<Double>.zero
            for axis in 0..<3 {
                var lo = p, hi = p
                if p[axis] > 0 { lo[axis] -= 1 }
                if p[axis] < cells { hi[axis] += 1 }
                let span = Double(hi[axis] - lo[axis])
                let difference = field[index(hi)] - field[index(lo)]
                g[axis] = span > 0 && difference.isFinite ? difference / span : 0
            }
            return g
        }

        func vertex(_ a: SIMD3<Int>, _ fa: Double, _ b: SIMD3<Int>, _ fb: Double) -> MeshVertex3D {
            let t = fa / (fa - fb)
            let ta = SIMD3<Double>(a), tb = SIMD3<Double>(b)
            let grid = ta + (tb - ta) * t
            let position = grid * scale - 1
            var normal = gradient(a) * (1 - t) + gradient(b) * t
            let length = simd_length(normal)
            normal = length > 0 ? normal / length : SIMD3(0, 0, 1)
            return MeshVertex3D(position: SIMD3<Float>(position), normal: SIMD3<Float>(normal), parameter: none)
        }

        var corners = [SIMD3<Int>](repeating: .zero, count: 8)
        var values = [Double](repeating: 0, count: 8)

        for j in 0..<cells {
            for i in 0..<cells {
                let origin = SIMD3(i, j, k)
                var anyInside = false
                var anyOutside = false
                var finite = true
                for c in 0..<8 {
                    let p = origin &+ cornerOffsets[c]
                    corners[c] = p
                    let v = field[index(p)]
                    values[c] = v
                    if !v.isFinite { finite = false; break }
                    if v < 0 { anyInside = true } else { anyOutside = true }
                }
                // 整个立方体在同一侧（绝大多数格子）就跳过。
                guard finite, anyInside, anyOutside else { continue }

                for (t0, t1, t2, t3) in tetrahedra {
                    let ids = [t0, t1, t2, t3]
                    var inside: [Int] = []
                    var outside: [Int] = []
                    for id in ids {
                        if values[id] < 0 { inside.append(id) } else { outside.append(id) }
                    }
                    switch inside.count {
                    case 1, 3:
                        // 一个角独自在一侧：三条边上各一个交点，一个三角形。
                        let lone = inside.count == 1 ? inside[0] : outside[0]
                        let others = inside.count == 1 ? outside : inside
                        for other in others {
                            out.append(vertex(corners[lone], values[lone], corners[other], values[other]))
                        }
                    case 2:
                        // 两两分开：四条边上的交点围成一个四边形，切成两个三角形。
                        let a = inside[0], b = inside[1], c = outside[0], d = outside[1]
                        let ac = vertex(corners[a], values[a], corners[c], values[c])
                        let ad = vertex(corners[a], values[a], corners[d], values[d])
                        let bd = vertex(corners[b], values[b], corners[d], values[d])
                        let bc = vertex(corners[b], values[b], corners[c], values[c])
                        out.append(contentsOf: [ac, ad, bd, ac, bd, bc])
                    default:
                        break
                    }
                }
            }
        }
    }
}
