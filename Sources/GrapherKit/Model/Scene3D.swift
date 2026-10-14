import Foundation
import simd

/// 交给 3D 渲染器的几何。坐标全是**盒内归一化坐标**（见 `View3D.normalized`）：盒子就是 [-1, 1]³，
/// 盒外的部分渲染时按六个面裁掉。用 Float，GPU 直接吃。
public struct MeshVertex3D: Equatable, Sendable {
    public var position: SIMD3<Float>
    /// 单位法向。光照两面都打，所以朝哪一侧无所谓，只要整张面一致。
    public var normal: SIMD3<Float>
    /// 画网格线用的参数坐标：取整数值的地方画线。分量为 NaN 表示这个方向不画。
    public var parameter: SIMD2<Float>
    /// 按数值上色用的 0…1 标量（目前是坡度 |∇f| 相对最大值）。网格的 `colorsByScalar` 为真时着色器用它查色带。
    public var scalar: Float

    public init(position: SIMD3<Float>, normal: SIMD3<Float>, parameter: SIMD2<Float>, scalar: Float = 0) {
        self.position = position
        self.normal = normal
        self.parameter = parameter
        self.scalar = scalar
    }
}

/// 一张曲面：索引三角形。
public struct Mesh3D: Equatable, Sendable {
    public var vertices: [MeshVertex3D]
    /// 每三个一组，一个三角形。
    public var indices: [UInt32]
    /// 颜色的 alpha < 1 时半透明（渲染时单独一轮，不写深度）。
    public var color: RGBAColor
    /// 画出这张面的图层：选中高亮、点选都靠它。坐标盒、辅助线之类不属于任何图层，为 nil。
    public var layerID: UUID?
    /// 颜色按顶点的 `scalar` 查色带（蓝 → 黄 → 红），`color` 只提供不透明度。
    public var colorsByScalar: Bool

    public init(vertices: [MeshVertex3D] = [], indices: [UInt32] = [], color: RGBAColor, layerID: UUID? = nil,
                colorsByScalar: Bool = false) {
        self.vertices = vertices
        self.indices = indices
        self.color = color
        self.layerID = layerID
        self.colorsByScalar = colorsByScalar
    }

    public var triangleCount: Int { indices.count / 3 }
    public var isTranslucent: Bool { color.a < 0.999 }
}

/// 一条空间折线，线宽是屏幕像素（与 2D 描边同一个口径）。
public struct Polyline3D: Equatable, Sendable {
    public var points: [SIMD3<Float>]
    public var color: RGBAColor
    /// 线宽，后备像素。
    public var width: Double
    /// 同 `Mesh3D.layerID`。
    public var layerID: UUID?

    public init(points: [SIMD3<Float>], color: RGBAColor, width: Double, layerID: UUID? = nil) {
        self.points = points
        self.color = color
        self.width = width
        self.layerID = layerID
    }
}

public struct Scene3D: Equatable, Sendable {
    public var meshes: [Mesh3D]
    public var polylines: [Polyline3D]

    public init(meshes: [Mesh3D] = [], polylines: [Polyline3D] = []) {
        self.meshes = meshes
        self.polylines = polylines
    }

    public var isEmpty: Bool { meshes.isEmpty && polylines.isEmpty }
}

/// 数据坐标里的一个长方体。
public struct DataBox3D: Equatable, Sendable {
    public var min: SIMD3<Double>
    public var max: SIMD3<Double>

    public init(min: SIMD3<Double>, max: SIMD3<Double>) {
        self.min = min
        self.max = max
    }

    public func union(_ other: DataBox3D?) -> DataBox3D {
        guard let other else { return self }
        return DataBox3D(min: simd_min(min, other.min), max: simd_max(max, other.max))
    }

    public func intersection(_ other: DataBox3D) -> DataBox3D? {
        let lower = simd_max(min, other.min)
        let upper = simd_min(max, other.max)
        guard lower.x <= upper.x, lower.y <= upper.y, lower.z <= upper.z else { return nil }
        return DataBox3D(min: lower, max: upper)
    }

    /// 一批点的包围盒，非有限值不算。
    public static func enclosing<S: Sequence>(_ points: S) -> DataBox3D? where S.Element == SIMD3<Double> {
        var lower = SIMD3(repeating: Double.infinity)
        var upper = SIMD3(repeating: -Double.infinity)
        var found = false
        for p in points where p.x.isFinite && p.y.isFinite && p.z.isFinite {
            lower = simd_min(lower, p)
            upper = simd_max(upper, p)
            found = true
        }
        return found ? DataBox3D(min: lower, max: upper) : nil
    }
}
