import Foundation
import simd

/// 立体几何里的三种基本对象。点、直线（空间曲线是线性的）、平面（隐式 / 显式曲面是线性的）
/// 不另设图型，而是从已有图层里认出来（`SpaceObject.recognize`）。
public enum SpaceObject: Equatable, Sendable {
    case point(SIMD3<Double>)
    /// 过 `origin`、方向为单位向量 `direction` 的直线。
    case line(origin: SIMD3<Double>, direction: SIMD3<Double>)
    /// 平面 `normal · p = offset`，`normal` 是单位向量。
    case plane(normal: SIMD3<Double>, offset: Double)

    public var kindName: String {
        switch self {
        case .point: return L("point")
        case .line: return L("line")
        case .plane: return L("plane")
        }
    }

    /// 平面上的一点（离原点最近的那一个）。
    public var anchor: SIMD3<Double> {
        switch self {
        case .point(let p): return p
        case .line(let origin, _): return origin
        case .plane(let normal, let offset): return normal * offset
        }
    }
}

/// 一个量：名字、数值、单位（长度没有单位，角度是度）。
public struct GeometryMeasure: Equatable, Sendable {
    public var name: String
    public var value: Double
    public var isAngle: Bool

    public init(_ name: String, _ value: Double, isAngle: Bool = false) {
        self.name = name
        self.value = value
        self.isAngle = isAngle
    }
}

/// 一个能画出来的辅助对象：算出来的垂足、交点、公垂线、交线。
public enum GeometryConstruction: Equatable, Sendable {
    case point(SIMD3<Double>, name: String)
    case segment(SIMD3<Double>, SIMD3<Double>, name: String)
    /// 无限长的直线（画出来时按坐标盒截取）。
    case line(origin: SIMD3<Double>, direction: SIMD3<Double>, name: String)

    public var name: String {
        switch self {
        case .point(_, let name), .segment(_, _, let name), .line(_, _, let name): return name
        }
    }
}

/// 两个对象之间的关系：一句话结论、几个量、可以画出来的辅助对象。
public struct GeometryRelation: Equatable, Sendable {
    public var summary: String
    public var measures: [GeometryMeasure]
    public var constructions: [GeometryConstruction]
}

public enum SpaceGeometry {

    /// 比这小的量当成 0（长度、方向分量都按数据坐标；公式求值的误差远小于它）。
    static let epsilon = 1e-9

    // MARK: - 从图层认出几何对象

    /// 认出一个图层是点、直线还是平面；不是（或公式有错、不是线性的）返回 nil。
    /// 空间曲线按 t 的定义域取点，检验它是不是 `p0 + t d`；隐式 / 显式曲面检验是不是 x、y、z 的一次式。
    public static func recognize(_ compiled: LayerCompiler.CompiledLayer) -> SpaceObject? {
        let layer = compiled.layer
        switch layer.kind {
        case .point:
            guard let fx = compiled.primary, let fy = compiled.secondary, let fz = compiled.tertiary else { return nil }
            let p = SIMD3(fx.evaluate([]), fy.evaluate([]), fz.evaluate([]))
            return finite(p) ? .point(p) : nil

        case .spaceCurve:
            guard let fx = compiled.primary, let fy = compiled.secondary, let fz = compiled.tertiary else { return nil }
            let lower = min(layer.domainLower, layer.domainUpper)
            let upper = max(layer.domainLower, layer.domainUpper)
            guard upper > lower else { return nil }
            func at(_ t: Double) -> SIMD3<Double> { SIMD3(fx.evaluate([t]), fy.evaluate([t]), fz.evaluate([t])) }
            let p0 = at(lower)
            let p1 = at(upper)
            guard finite(p0), finite(p1) else { return nil }
            let span = p1 - p0
            let size = max(simd_length(span), 1)
            guard simd_length(span) > epsilon else { return nil }
            // 线性：中间几个点必须落在 p0 + s·span 上。
            for s in [0.17, 0.5, 0.83] {
                let expected = p0 + span * s
                let actual = at(lower + (upper - lower) * s)
                guard finite(actual), simd_length(actual - expected) <= 1e-7 * size else { return nil }
            }
            return .line(origin: p0, direction: simd_normalize(span))

        case .implicitSurface:
            guard let f = compiled.primary else { return nil }
            return linearPlane { f.evaluate([$0.x, $0.y, $0.z]) }

        case .surface:
            guard let f = compiled.primary else { return nil }
            // z = f(x, y) 即 F = f(x, y) - z。
            return linearPlane { f.evaluate([$0.x, $0.y]) - $0.z }

        default:
            return nil
        }
    }

    /// F 是 x、y、z 的一次式 `g·p + c` 时返回平面 `g·p + c = 0`。
    private static func linearPlane(_ f: (SIMD3<Double>) -> Double) -> SpaceObject? {
        let c = f(.zero)
        let g = SIMD3(f(SIMD3(1, 0, 0)) - c, f(SIMD3(0, 1, 0)) - c, f(SIMD3(0, 0, 1)) - c)
        guard c.isFinite, finite(g) else { return nil }
        let length = simd_length(g)
        guard length > epsilon else { return nil }
        for p in [SIMD3(0.7, -1.3, 2.1), SIMD3(-3.1, 0.4, 1.7), SIMD3(5.3, 2.9, -4.4)] {
            let expected = simd_dot(g, p) + c
            let actual = f(p)
            guard actual.isFinite, abs(actual - expected) <= 1e-7 * max(1, abs(expected), length) else { return nil }
        }
        return .plane(normal: g / length, offset: -c / length)
    }

    private static func finite(_ v: SIMD3<Double>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

    // MARK: - 投影与垂足

    /// 点到直线上的垂足。
    public static func foot(of p: SIMD3<Double>, onLine origin: SIMD3<Double>, direction: SIMD3<Double>) -> SIMD3<Double> {
        origin + direction * simd_dot(p - origin, direction)
    }

    /// 点到平面上的垂足（也就是正投影）。
    public static func foot(of p: SIMD3<Double>, onPlane normal: SIMD3<Double>, offset: Double) -> SIMD3<Double> {
        p - normal * (simd_dot(normal, p) - offset)
    }

    /// 点沿 `direction` 方向到平面上的斜投影；方向与平面平行时返回 nil。
    public static func project(
        _ p: SIMD3<Double>, onPlane normal: SIMD3<Double>, offset: Double, along direction: SIMD3<Double>
    ) -> SIMD3<Double>? {
        let s = simd_dot(normal, direction)
        guard abs(s) > epsilon else { return nil }
        return p + direction * ((offset - simd_dot(normal, p)) / s)
    }

    // MARK: - 关系

    public static func relation(_ a: SpaceObject, _ b: SpaceObject) -> GeometryRelation {
        switch (a, b) {
        case (.point(let p), .point(let q)): return pointPoint(p, q)
        case (.point(let p), .line(let o, let d)): return pointLine(p, o, d)
        case (.line(let o, let d), .point(let p)): return pointLine(p, o, d)
        case (.point(let p), .plane(let n, let c)): return pointPlane(p, n, c)
        case (.plane(let n, let c), .point(let p)): return pointPlane(p, n, c)
        case (.line(let o1, let d1), .line(let o2, let d2)): return lineLine(o1, d1, o2, d2)
        case (.line(let o, let d), .plane(let n, let c)): return linePlane(o, d, n, c)
        case (.plane(let n, let c), .line(let o, let d)): return linePlane(o, d, n, c)
        case (.plane(let n1, let c1), .plane(let n2, let c2)): return planePlane(n1, c1, n2, c2)
        }
    }

    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// 夹角，单位度；点积浮点误差夹到 [-1, 1] 里。
    private static func angle(cosine: Double) -> Double { degrees(acos(min(1, max(-1, cosine)))) }

    private static func pointPoint(_ p: SIMD3<Double>, _ q: SIMD3<Double>) -> GeometryRelation {
        let distance = simd_length(p - q)
        return GeometryRelation(
            summary: distance <= epsilon ? L("The two points coincide.") : L("Two distinct points."),
            measures: [GeometryMeasure(L("Distance"), distance)],
            constructions: distance <= epsilon ? [] : [
                .segment(p, q, name: L("Segment")),
                .point((p + q) / 2, name: L("Midpoint")),
            ]
        )
    }

    private static func pointLine(_ p: SIMD3<Double>, _ o: SIMD3<Double>, _ d: SIMD3<Double>) -> GeometryRelation {
        let foot = foot(of: p, onLine: o, direction: d)
        let distance = simd_length(p - foot)
        let on = distance <= epsilon
        return GeometryRelation(
            summary: on ? L("The point lies on the line.") : L("The point is off the line."),
            measures: [GeometryMeasure(L("Distance"), distance)],
            constructions: on ? [] : [
                .point(foot, name: L("Foot of perpendicular")),
                .segment(p, foot, name: L("Perpendicular")),
            ]
        )
    }

    private static func pointPlane(_ p: SIMD3<Double>, _ n: SIMD3<Double>, _ c: Double) -> GeometryRelation {
        let signed = simd_dot(n, p) - c
        let on = abs(signed) <= epsilon
        let foot = foot(of: p, onPlane: n, offset: c)
        return GeometryRelation(
            summary: on ? L("The point lies in the plane.") : L("The point is off the plane."),
            measures: [GeometryMeasure(L("Distance"), abs(signed))],
            constructions: on ? [] : [
                .point(foot, name: L("Foot of perpendicular")),
                .segment(p, foot, name: L("Perpendicular")),
            ]
        )
    }

    private static func lineLine(
        _ o1: SIMD3<Double>, _ d1: SIMD3<Double>, _ o2: SIMD3<Double>, _ d2: SIMD3<Double>
    ) -> GeometryRelation {
        let w = o1 - o2
        let cross = simd_cross(d1, d2)
        let b = simd_dot(d1, d2)
        let lineAngle = angle(cosine: abs(b))

        if simd_length(cross) <= 1e-9 {
            // 平行：距离是 O1 到直线 2 的距离。
            let offset = w - d2 * simd_dot(w, d2)
            let distance = simd_length(offset)
            if distance <= epsilon {
                return GeometryRelation(
                    summary: L("The lines coincide."),
                    measures: [GeometryMeasure(L("Angle"), 0, isAngle: true), GeometryMeasure(L("Distance"), 0)],
                    constructions: []
                )
            }
            let foot = foot(of: o1, onLine: o2, direction: d2)
            return GeometryRelation(
                summary: L("The lines are parallel."),
                measures: [GeometryMeasure(L("Angle"), 0, isAngle: true), GeometryMeasure(L("Distance"), distance)],
                constructions: [.segment(o1, foot, name: L("Common perpendicular"))]
            )
        }

        // 两直线上最近的两点：对 |O1 + t1 d1 - O2 - t2 d2|² 求最小（d1、d2 是单位向量）。
        let d = simd_dot(d1, w)
        let e = simd_dot(d2, w)
        let denominator = 1 - b * b
        let t1 = (b * e - d) / denominator
        let t2 = (e - b * d) / denominator
        let p1 = o1 + d1 * t1
        let p2 = o2 + d2 * t2
        let distance = simd_length(p1 - p2)

        if distance <= 1e-8 {
            return GeometryRelation(
                summary: L("The lines intersect."),
                measures: [GeometryMeasure(L("Angle"), lineAngle, isAngle: true)],
                constructions: [.point((p1 + p2) / 2, name: L("Intersection point"))]
            )
        }
        return GeometryRelation(
            summary: L("The lines are skew."),
            measures: [GeometryMeasure(L("Angle"), lineAngle, isAngle: true), GeometryMeasure(L("Distance"), distance)],
            constructions: [
                .segment(p1, p2, name: L("Common perpendicular")),
                .point(p1, name: L("Foot on line A")),
                .point(p2, name: L("Foot on line B")),
            ]
        )
    }

    private static func linePlane(
        _ o: SIMD3<Double>, _ d: SIMD3<Double>, _ n: SIMD3<Double>, _ c: Double
    ) -> GeometryRelation {
        let s = simd_dot(d, n)
        let offset = simd_dot(n, o) - c
        if abs(s) <= 1e-9 {
            if abs(offset) <= epsilon {
                return GeometryRelation(
                    summary: L("The line lies in the plane."),
                    measures: [GeometryMeasure(L("Angle"), 0, isAngle: true), GeometryMeasure(L("Distance"), 0)],
                    constructions: []
                )
            }
            let foot = foot(of: o, onPlane: n, offset: c)
            return GeometryRelation(
                summary: L("The line is parallel to the plane."),
                measures: [GeometryMeasure(L("Angle"), 0, isAngle: true), GeometryMeasure(L("Distance"), abs(offset))],
                constructions: [.segment(o, foot, name: L("Perpendicular"))]
            )
        }
        let t = -offset / s
        let hit = o + d * t
        let angleDegrees = degrees(asin(min(1, abs(s))))
        var constructions: [GeometryConstruction] = [.point(hit, name: L("Intersection point"))]
        if abs(abs(s) - 1) <= 1e-9 { constructions.append(.line(origin: hit, direction: n, name: L("Normal"))) }
        return GeometryRelation(
            summary: abs(abs(s) - 1) <= 1e-9 ? L("The line is perpendicular to the plane.") : L("The line meets the plane at one point."),
            measures: [GeometryMeasure(L("Angle"), angleDegrees, isAngle: true)],
            constructions: constructions
        )
    }

    private static func planePlane(
        _ n1: SIMD3<Double>, _ c1: Double, _ n2: SIMD3<Double>, _ c2: Double
    ) -> GeometryRelation {
        let cross = simd_cross(n1, n2)
        let dihedral = angle(cosine: abs(simd_dot(n1, n2)))
        if simd_length(cross) <= 1e-9 {
            // 平行：把 n2 调成与 n1 同向再比位置。
            let sameSide = simd_dot(n1, n2) > 0 ? c2 : -c2
            let distance = abs(c1 - sameSide)
            if distance <= epsilon {
                return GeometryRelation(
                    summary: L("The planes coincide."),
                    measures: [GeometryMeasure(L("Angle"), 0, isAngle: true), GeometryMeasure(L("Distance"), 0)],
                    constructions: []
                )
            }
            let p = n1 * c1
            return GeometryRelation(
                summary: L("The planes are parallel."),
                measures: [GeometryMeasure(L("Angle"), 0, isAngle: true), GeometryMeasure(L("Distance"), distance)],
                constructions: [.segment(p, n1 * sameSide, name: L("Perpendicular"))]
            )
        }
        let squared = simd_length_squared(cross)
        let point = (simd_cross(n2, cross) * c1 + simd_cross(cross, n1) * c2) / squared
        return GeometryRelation(
            summary: abs(simd_dot(n1, n2)) <= 1e-9 ? L("The planes are perpendicular.") : L("The planes intersect in a line."),
            measures: [GeometryMeasure(L("Dihedral angle"), dihedral, isAngle: true)],
            constructions: [.line(origin: point, direction: cross / sqrt(squared), name: L("Line of intersection"))]
        )
    }
}
