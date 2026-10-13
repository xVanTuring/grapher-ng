import Foundation
import simd

/// 3D 坐标盒上的一个文字：刻度数字或轴名。位置是**当前盒子的归一化坐标**，叠加层每帧投影到屏幕上摆。
public struct AxisLabel3D: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 刻度数字：值与建议的小数位数，由叠加层格式化。
        case tick(value: Double, decimals: Int)
        /// 轴名 x / y / z。
        case axisName(String)
    }

    public var kind: Kind
    public var position: SIMD3<Double>
    /// 0 = x，1 = y，2 = z。
    public var axis: Int
}

/// 坐标盒的线框与刻度（Grapher、Desmos 3D 的样子）：
///
/// - 12 条棱，淡色细线；
/// - 背向相机的三面「墙」上画主刻度网格（`showGrid`），随相机转动换到对面；
/// - 过原点的三根坐标轴（`showAxes`，原点在盒内才画）；
/// - 刻度数字标在盒底朝向相机的两条棱、以及屏幕上最左边那条竖棱上，棱的末端标轴名。
///
/// 每次视图变化都按当前视图重算（几十条线），几何直接是当前盒子的归一化坐标，渲染时不裁剪。
public enum Chrome3D {

    public struct Result: Sendable {
        public var scene: Scene3D
        public var labels: [AxisLabel3D]
    }

    /// 刻度之间至少隔这么多像素。
    static let minimumTickSpacing = 70.0
    /// 刻度数字离开棱线多远（归一化单位）。
    static let labelOffset = 0.12

    public static func make(view: View3D, document: GrapherDocument, backingScale: Double) -> Result {
        let theme = document.theme
        var lines: [Polyline3D] = []
        var labels: [AxisLabel3D] = []
        let eye = view.eye
        /// 朝向相机的那一侧（±1）。
        let near = SIMD3(eye.x >= 0 ? 1.0 : -1.0, eye.y >= 0 ? 1.0 : -1.0, eye.z >= 0 ? 1.0 : -1.0)
        let ticks = (0..<3).map { axis in
            AxisTicks.ticks(range: view.range(axis: axis), pixelsPerUnit: view.pixelsPerUnit,
                            minimumPixelSpacing: minimumTickSpacing)
        }
        func n(_ axis: Int, _ value: Double) -> Double { (value - view.center[axis]) / view.halfExtent }
        func segment(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ color: RGBAColor, _ widthPoints: Double) {
            lines.append(Polyline3D(points: [SIMD3<Float>(a), SIMD3<Float>(b)], color: color,
                                    width: max(widthPoints * backingScale, 0.5)))
        }

        // 背向相机的三面墙上的网格。
        if document.showGrid {
            for wallAxis in 0..<3 {
                let wall = -near[wallAxis]
                for lineAxis in 0..<3 where lineAxis != wallAxis {
                    let across = 3 - wallAxis - lineAxis
                    for tick in ticks[across].major {
                        var a = SIMD3<Double>.zero, b = SIMD3<Double>.zero
                        a[wallAxis] = wall; b[wallAxis] = wall
                        a[across] = n(across, tick); b[across] = n(across, tick)
                        a[lineAxis] = -1; b[lineAxis] = 1
                        segment(a, b, theme.grid, 0.6)
                    }
                }
            }
        }

        // 12 条棱。
        let edgeColor = theme.axes.withAlpha(0.45)
        for axis in 0..<3 {
            for s1 in [-1.0, 1.0] {
                for s2 in [-1.0, 1.0] {
                    var a = SIMD3<Double>.zero, b = SIMD3<Double>.zero
                    let others = [(axis + 1) % 3, (axis + 2) % 3]
                    a[others[0]] = s1; b[others[0]] = s1
                    a[others[1]] = s2; b[others[1]] = s2
                    a[axis] = -1; b[axis] = 1
                    segment(a, b, edgeColor, 0.8)
                }
            }
        }

        // 过原点的坐标轴。
        let origin = view.normalized(.zero)
        if document.showAxes, (0..<3).allSatisfy({ abs(origin[$0]) <= 1 }) {
            for axis in 0..<3 {
                var a = origin, b = origin
                a[axis] = -1
                b[axis] = 1
                segment(a, b, theme.axes, 1.1)
            }
        }

        // 刻度数字：x、y 标在盒底朝向相机的棱上，z 标在屏幕最左边的竖棱上。
        if document.showTickLabels {
            let floor = -1.0
            func place(axis: Int, edge: SIMD3<Double>, outward: SIMD3<Double>) {
                for tick in ticks[axis].major {
                    var p = edge
                    p[axis] = n(axis, tick)
                    labels.append(AxisLabel3D(
                        kind: .tick(value: tick, decimals: ticks[axis].labelDecimals),
                        position: p + outward * labelOffset,
                        axis: axis
                    ))
                }
                var end = edge
                end[axis] = 1 + labelOffset * 2
                labels.append(AxisLabel3D(kind: .axisName(["x", "y", "z"][axis]),
                                          position: end + outward * labelOffset, axis: axis))
            }
            place(axis: 0, edge: SIMD3(0, near.y, floor), outward: simd_normalize(SIMD3(0, near.y, -1)))
            place(axis: 1, edge: SIMD3(near.x, 0, floor), outward: simd_normalize(SIMD3(near.x, 0, -1)))

            // 四条竖棱里投到屏幕最左边的那条。
            var best = SIMD3(-1.0, -1.0, 0.0)
            var bestX = Double.infinity
            for sx in [-1.0, 1.0] {
                for sy in [-1.0, 1.0] {
                    let corner = SIMD3(sx, sy, 0.0)
                    if let p = view.project(corner), p.x < bestX {
                        bestX = p.x
                        best = corner
                    }
                }
            }
            place(axis: 2, edge: best, outward: simd_normalize(SIMD3(best.x, best.y, 0)))
        }

        return Result(scene: Scene3D(polylines: lines), labels: labels)
    }
}
