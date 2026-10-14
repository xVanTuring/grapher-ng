import Foundation
import simd

/// 切线、法线与切平面：对采样用的同一份编译好的公式做数值求导（中心差分）。
public enum Tangents {

    /// 中心差分的步长：相对参数大小取，免得大数上被舍入吃掉、小数上又太粗。
    private static func step(_ x: Double) -> Double { 1e-5 * max(1, abs(x)) }

    /// 平面曲线上一点与该点的切向（单位向量）。
    public struct Tangent2D: Equatable, Sendable {
        public var point: SIMD2<Double>
        public var direction: SIMD2<Double>
        /// 切线斜率 dy/dx；竖直切线为 nil。
        public var slope: Double? {
            abs(direction.x) > 1e-9 ? direction.y / direction.x : nil
        }
        /// 法向（切向逆时针转 90°）。
        public var normal: SIMD2<Double> { SIMD2(-direction.y, direction.x) }
    }

    /// 在显函数 / 参数方程 / 极坐标的 `parameter` 处求切线：显函数的参数是 x，参数方程是 t，极坐标是 θ。
    /// 公式有错、该点没定义、导数为 0 / 无穷时返回 nil。
    public static func tangent(of source: LayerCompiler.CompiledLayer, at parameter: Double) -> Tangent2D? {
        let layer = source.layer
        let h = step(parameter)
        let kind = layer.kind

        // 点与导数向量 (dx, dy)/dparameter
        let point: SIMD2<Double>
        let derivative: SIMD2<Double>
        switch kind {
        case .explicit:
            guard let f = source.primary else { return nil }
            func y(_ x: Double) -> Double { f.evaluate(kind.primaryValues(argument: x)) }
            point = SIMD2(parameter, y(parameter))
            derivative = SIMD2(1, (y(parameter + h) - y(parameter - h)) / (2 * h))
        case .parametric:
            guard let fx = source.primary, let fy = source.secondary else { return nil }
            func p(_ t: Double) -> SIMD2<Double> { SIMD2(fx.evaluate([t]), fy.evaluate([t])) }
            point = p(parameter)
            derivative = (p(parameter + h) - p(parameter - h)) / (2 * h)
        case .polar:
            guard let r = source.primary else { return nil }
            func p(_ theta: Double) -> SIMD2<Double> {
                let radius = r.evaluate(kind.primaryValues(argument: theta))
                return SIMD2(radius * cos(theta), radius * sin(theta))
            }
            point = p(parameter)
            derivative = (p(parameter + h) - p(parameter - h)) / (2 * h)
        default:
            return nil
        }
        guard point.x.isFinite, point.y.isFinite, derivative.x.isFinite, derivative.y.isFinite else { return nil }
        let length = simd_length(derivative)
        guard length > 1e-9 else { return nil }
        return Tangent2D(point: point, direction: derivative / length)
    }

    /// 曲面上一点、该点的单位法向（朝上的那一侧：z 分量 ≥ 0，水平时取 +x 一侧），以及两个切向（单位）。
    public struct TangentPlane: Equatable, Sendable {
        public var point: SIMD3<Double>
        public var normal: SIMD3<Double>
        public var tangentU: SIMD3<Double>
        public var tangentV: SIMD3<Double>

        /// 平面方程 `normal · p = offset` 里的 offset。
        public var offset: Double { simd_dot(normal, point) }
    }

    /// 显式曲面 z = f(x, y) 在 (u, v) = (x, y) 处，或参数曲面在 (u, v) 处的切平面。
    /// 没定义、奇异（两个切向平行）时返回 nil。
    public static func tangentPlane(of source: LayerCompiler.CompiledLayer, u: Double, v: Double) -> TangentPlane? {
        let kind = source.layer.kind
        let hu = step(u)
        let hv = step(v)

        let point: SIMD3<Double>
        let du: SIMD3<Double>
        let dv: SIMD3<Double>
        switch kind {
        case .surface:
            guard let f = source.primary else { return nil }
            func p(_ x: Double, _ y: Double) -> SIMD3<Double> { SIMD3(x, y, f.evaluate([x, y])) }
            point = p(u, v)
            du = (p(u + hu, v) - p(u - hu, v)) / (2 * hu)
            dv = (p(u, v + hv) - p(u, v - hv)) / (2 * hv)
        case .parametricSurface:
            guard let fx = source.primary, let fy = source.secondary, let fz = source.tertiary else { return nil }
            func p(_ a: Double, _ b: Double) -> SIMD3<Double> {
                SIMD3(fx.evaluate([a, b]), fy.evaluate([a, b]), fz.evaluate([a, b]))
            }
            point = p(u, v)
            du = (p(u + hu, v) - p(u - hu, v)) / (2 * hu)
            dv = (p(u, v + hv) - p(u, v - hv)) / (2 * hv)
        default:
            return nil
        }
        for vector in [point, du, dv] where !(vector.x.isFinite && vector.y.isFinite && vector.z.isFinite) { return nil }
        var normal = simd_cross(du, dv)
        let length = simd_length(normal)
        guard length > 1e-9 * max(simd_length(du) * simd_length(dv), 1e-300), length > 1e-12 else { return nil }
        normal /= length
        if normal.z < -1e-12 || (abs(normal.z) <= 1e-12 && normal.x < 0) { normal = -normal }
        let tu = simd_length(du) > 0 ? du / simd_length(du) : du
        let tv = simd_length(dv) > 0 ? dv / simd_length(dv) : dv
        return TangentPlane(point: point, normal: normal, tangentU: tu, tangentV: tv)
    }
}
