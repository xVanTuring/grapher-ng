import Foundation
import simd

/// 梯度流线：从一个起点出发，沿 ∇f（上升）或 −∇f（下降）一路走，像小球顺着山坡滚（下降）或一路爬到山顶（上升）。
///
/// 在 xy 平面上积分 dp/ds = ±∇f/|∇f|（按弧长匀速，四阶龙格–库塔），步长取坐标盒边长的 1/160：
/// 走到梯度几乎为 0（到了山顶 / 谷底 / 平地）、出了坐标盒、步数用完或值没有定义就停。
public enum GradientFlow {

    /// 梯度小于这个就当到了临界点，停下。
    static let stopMagnitude = 1e-3
    static let maxSteps = 900

    /// - Returns: 路径上的点（xy，起点在内）；起点自己就在临界点或没定义时只有起点一个点。
    public static func path(
        of f: CompiledExpression,
        from start: SIMD2<Double>,
        center: SIMD3<Double>,
        halfExtent: Double,
        descent: Bool
    ) -> [SIMD2<Double>] {
        let sign = descent ? -1.0 : 1.0
        let h = 2 * halfExtent / 160
        func direction(_ p: SIMD2<Double>) -> SIMD2<Double>? {
            guard let g = GradientField.gradient(of: f, x: p.x, y: p.y) else { return nil }
            let length = simd_length(g)
            guard length > stopMagnitude else { return nil }
            return sign * g / length
        }
        func inside(_ p: SIMD2<Double>) -> Bool {
            abs(p.x - center.x) <= halfExtent && abs(p.y - center.y) <= halfExtent
        }

        var points = [start]
        guard f.evaluate([start.x, start.y]).isFinite, inside(start) else { return points }
        var p = start
        for _ in 0..<maxSteps {
            guard let k1 = direction(p),
                  let k2 = direction(p + k1 * (h / 2)),
                  let k3 = direction(p + k2 * (h / 2)),
                  let k4 = direction(p + k3 * h) else { break }
            let next = p + (k1 + 2 * k2 + 2 * k3 + k4) * (h / 6)
            guard next.x.isFinite, next.y.isFinite, f.evaluate([next.x, next.y]).isFinite else { break }
            guard inside(next) else {
                // 最后一步正好出界：补一个落在盒面上的点，线才画到边。
                if let edge = clipToBox(from: p, to: next, center: center, halfExtent: halfExtent) { points.append(edge) }
                break
            }
            points.append(next)
            p = next
        }
        return points
    }

    private static func clipToBox(from a: SIMD2<Double>, to b: SIMD2<Double>, center: SIMD3<Double>, halfExtent: Double) -> SIMD2<Double>? {
        var t = 1.0
        let d = b - a
        for (axis, c) in [(0, center.x), (1, center.y)] {
            let low = c - halfExtent, high = c + halfExtent
            if b[axis] > high, d[axis] != 0 { t = min(t, (high - a[axis]) / d[axis]) }
            if b[axis] < low, d[axis] != 0 { t = min(t, (low - a[axis]) / d[axis]) }
        }
        return t > 0 ? a + d * t : nil
    }

    /// 折线上走了 `fraction`（0…1，按弧长）的那个点。
    public static func point(along line: [SIMD3<Double>], fraction: Double) -> SIMD3<Double>? {
        guard let first = line.first else { return nil }
        guard line.count >= 2 else { return first }
        var total = 0.0
        for i in 1..<line.count { total += simd_length(line[i] - line[i - 1]) }
        guard total > 0 else { return first }
        var remaining = min(max(fraction, 0), 1) * total
        for i in 1..<line.count {
            let segment = simd_length(line[i] - line[i - 1])
            if remaining <= segment || i == line.count - 1 {
                let k = segment > 0 ? min(remaining / segment, 1) : 0
                return line[i - 1] + (line[i] - line[i - 1]) * k
            }
            remaining -= segment
        }
        return line.last
    }
}
