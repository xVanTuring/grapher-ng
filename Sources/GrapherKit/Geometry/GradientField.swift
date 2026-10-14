import Foundation
import simd

/// 显式曲面 z = f(x, y) 的梯度场：在网格上每点画一支箭头。
///
/// - **画在曲面上**：箭头沿曲面的最陡上升方向，即 (fx, fy, fx² + fy²) 的方向——梯度在曲面切平面里的样子。
/// - **投到地面**：箭头是 ∇f = (fx, fy) 本身，平放在坐标盒底面，课本上的梯度场就是这样画的。
/// 箭头长度随梯度大小单调增长（`g / (g + 0.5)`，最长不超过一个格子），颜色从冷到暖按这一批箭头里最大的梯度归一化，
/// 所以「哪里陡」一眼能看出来；梯度为 0 的地方（极值点、鞍点）没有箭头。
public enum GradientField {

    public struct Arrow: Equatable, Sendable {
        public var origin: SIMD3<Double>
        public var tip: SIMD3<Double>
        /// 箭头两翼的端点。
        public var wingA: SIMD3<Double>
        public var wingB: SIMD3<Double>
        /// 这一点的 |∇f|。
        public var magnitude: Double
        /// 0…1：相对这一批里最大梯度的大小，上色用。
        public var level: Double

        /// 一笔画完：起点 → 尖 → 翼 → 尖 → 另一翼。
        public var path: [SIMD3<Double>] { [origin, tip, wingA, tip, wingB] }
    }

    /// 中心差分求 ∇f；该点或邻点没定义时返回 nil。
    public static func gradient(of f: CompiledExpression, x: Double, y: Double) -> SIMD2<Double>? {
        let h = 1e-5 * max(1, abs(x), abs(y))
        let fx = (f.evaluate([x + h, y]) - f.evaluate([x - h, y])) / (2 * h)
        let fy = (f.evaluate([x, y + h]) - f.evaluate([x, y - h])) / (2 * h)
        guard fx.isFinite, fy.isFinite else { return nil }
        return SIMD2(fx, fy)
    }

    /// 最小的有箭头的梯度大小：比它小当作 0（平地、极值点）。
    static let minimumMagnitude = 1e-6

    public static func arrows(
        of f: CompiledExpression,
        center: SIMD3<Double>,
        halfExtent: Double,
        density: Int,
        scale: Double,
        onFloor: Bool
    ) -> [Arrow] {
        let n = min(max(density, 2), 40)
        let cell = 2 * halfExtent / Double(n)
        let floorZ = center.z - halfExtent + 0.02 * halfExtent
        var raw: [(point: SIMD3<Double>, gradient: SIMD2<Double>, magnitude: Double)] = []
        for j in 0..<n {
            for i in 0..<n {
                let x = center.x - halfExtent + cell * (Double(i) + 0.5)
                let y = center.y - halfExtent + cell * (Double(j) + 0.5)
                let z = f.evaluate([x, y])
                guard z.isFinite, let g = gradient(of: f, x: x, y: y) else { continue }
                let magnitude = simd_length(g)
                guard magnitude > minimumMagnitude else { continue }
                raw.append((SIMD3(x, y, onFloor ? floorZ : z), g, magnitude))
            }
        }
        guard let strongest = raw.map(\.magnitude).max() else { return [] }

        var arrows: [Arrow] = []
        arrows.reserveCapacity(raw.count)
        for entry in raw {
            let g = entry.magnitude
            let flat = SIMD3(entry.gradient.x, entry.gradient.y, 0) / g
            // 曲面上的最陡上升方向 (fx, fy, g²)/|…|，和曲面法向 (−fx, −fy, 1)/|…|。
            let climbing = SIMD3(entry.gradient.x, entry.gradient.y, g * g) / (g * (1 + g * g).squareRoot())
            let surfaceNormal = SIMD3(-entry.gradient.x, -entry.gradient.y, 1) / (1 + g * g).squareRoot()
            var direction = onFloor ? flat : climbing
            let up = onFloor ? SIMD3<Double>(0, 0, 1) : surfaceNormal
            if scale < 0 { direction = -direction }

            let length = cell * 0.95 * abs(scale) * g / (g + 0.5)
            let tip = entry.point + direction * length
            let headLength = min(0.3 * length, 0.28 * cell)
            let side = simd_normalize(simd_cross(direction, up))
            let back = tip - direction * headLength
            arrows.append(Arrow(
                origin: entry.point, tip: tip,
                wingA: back + side * (headLength * 0.5), wingB: back - side * (headLength * 0.5),
                magnitude: g, level: g / strongest))
        }
        return arrows
    }

    /// 梯度大小 0…1 的色带：蓝（平缓）→ 黄 → 红（陡）。
    public static func color(level: Double) -> RGBAColor {
        let t = min(max(level, 0), 1)
        let stops: [(Double, SIMD3<Double>)] = [
            (0, SIMD3(0.20, 0.40, 0.90)), (0.5, SIMD3(0.95, 0.80, 0.15)), (1, SIMD3(0.88, 0.15, 0.12)),
        ]
        let upper = stops.firstIndex { $0.0 >= t } ?? stops.count - 1
        let lower = max(upper - 1, 0)
        let span = stops[upper].0 - stops[lower].0
        let k = span > 0 ? (t - stops[lower].0) / span : 0
        let c = stops[lower].1 + (stops[upper].1 - stops[lower].1) * k
        return RGBAColor(c.x, c.y, c.z)
    }
}
