import Foundation
import simd

/// 3D 画布的视角与坐标盒。
///
/// 坐标盒是一个立方体：中心 `center`、半边长 `halfExtent`（数据单位，三轴同一个，图形不变形）。
/// 采样只在盒内做；渲染时一切几何先换算到**盒内归一化坐标** `n = (p − center) / halfExtent`，
/// 盒子就是 [-1, 1]³，盒外的部分由 GPU 按六个面精确裁掉。
///
/// 相机绕盒心转（方位角 + 仰角，z 轴始终朝上），离盒心固定距离、透视投影。
///
/// 两种缩放：
/// - **缩放图形**（改 `halfExtent`）：盒子在屏幕上大小不变，框住的数据范围变了，要重采（Desmos 3D 的缩放）。
///   ⌘+滚轮、捏合、工具栏的放大缩小走这一种，与平面图的 ⌘+滚轮一致。
/// - **放大盒子**（`cameraZoom`）：盒子连同里面的图形一起在屏幕上变大变小，数据范围不变，只换投影、不重采。
///   按住 ⌥ 走这一种（⌥+滚轮、⌥+捏合、⌥+= / ⌥+-）。
/// 旋转只换投影矩阵；平移和改范围改了盒子，才需要重采。
public struct View3D: Equatable, Sendable, Codable {
    /// 坐标盒中心（数据坐标）。
    public var center: SIMD3<Double>
    /// 坐标盒半边长（数据单位）。
    public var halfExtent: Double
    /// 相机方位角：绕 z 轴、从 +x 起逆时针，弧度。
    public var azimuth: Double
    /// 相机仰角：离开 xy 平面的角度，弧度，夹在 ±`elevationLimit`。
    public var elevation: Double
    /// 盒子在屏幕上的放大倍数：1 = 盒子的外接球正好装进未遮挡区的短边。
    public var cameraZoom: Double = 1
    /// 正交投影（没有近大远小）。三个轴向视图用它，平面视图里平行于画面的长度才能直接量。
    public var isOrthographic: Bool = false

    /// 三个轴向的平面视图：沿某根轴往原点方向看，另外两根轴正好水平、竖直。
    public enum AxisView: String, CaseIterable, Sendable {
        /// 沿 x 轴看（从 +x 一侧）：y 向右、z 向上，即 yz 平面。
        case x
        /// 沿 y 轴看（从 -y 一侧）：x 向右、z 向上，即 xz 平面。
        case y
        /// 沿 z 轴看（从 +z 一侧俯视）：x 向右、y 向上，即 xy 平面。
        case z
    }

    /// 画布尺寸（像素）与被浮层盖住的四边（像素）：窗口状态，不进文档，含义同 `Viewport2D`。
    public var widthPixels: Double = 1200
    public var heightPixels: Double = 800
    public var insetLeft: Double = 0
    public var insetTop: Double = 0
    public var insetRight: Double = 0
    public var insetBottom: Double = 0

    private enum CodingKeys: String, CodingKey {
        case center, halfExtent, azimuth, elevation, cameraZoom, isOrthographic
    }

    public init(
        center: SIMD3<Double> = .zero,
        halfExtent: Double = 4,
        azimuth: Double = 0.55,
        elevation: Double = 0.45,
        cameraZoom: Double = 1,
        isOrthographic: Bool = false
    ) {
        self.center = center
        self.halfExtent = halfExtent
        self.azimuth = azimuth
        self.elevation = elevation
        self.cameraZoom = cameraZoom
        self.isOrthographic = isOrthographic
    }

    /// `cameraZoom`、`isOrthographic` 是后加的，早先存下的立体图没有它们，读成 1 和 false。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        center = try container.decode(SIMD3<Double>.self, forKey: .center)
        halfExtent = try container.decode(Double.self, forKey: .halfExtent)
        azimuth = try container.decode(Double.self, forKey: .azimuth)
        elevation = try container.decode(Double.self, forKey: .elevation)
        cameraZoom = try container.decodeIfPresent(Double.self, forKey: .cameraZoom) ?? 1
        isOrthographic = try container.decodeIfPresent(Bool.self, forKey: .isOrthographic) ?? false
    }

    /// 默认视角：x 轴朝左下、y 轴朝右、z 轴朝上，课本上画立体图的样子。
    public static let standard = View3D()

    /// 相机到盒心的距离（归一化单位）。盒子外接球半径 √3，近、远裁剪面夹住它。
    public static let cameraDistance = 5.2
    static let boundingRadius = 3.0.squareRoot()
    static let nearPlane = cameraDistance - 2.2
    static let farPlane = cameraDistance + 2.2
    /// `cameraZoom` = 1 时，盒子外接球的直径占未遮挡区短边的比例：正好装下，任何角度盒角都不出画面。
    static let fillFraction = 1.0
    public static let elevationLimit = 89.0 * Double.pi / 180
    /// 正俯视的仰角：只有「沿 z 轴看」这个视图会用到，拖动旋转仍夹在 `elevationLimit` 内。
    static let topElevation = Double.pi / 2
    public static let halfExtentRange: ClosedRange<Double> = 1e-4...1e6
    public static let cameraZoomRange: ClosedRange<Double> = 0.25...12
    /// 拖动一个点转多少弧度。
    public static let orbitRadiansPerPoint = 0.008

    // MARK: - 盒子

    /// 数据坐标 → 盒内归一化坐标。
    public func normalized(_ p: SIMD3<Double>) -> SIMD3<Double> {
        (p - center) / halfExtent
    }

    /// 盒内归一化坐标 → 数据坐标。
    public func data(_ n: SIMD3<Double>) -> SIMD3<Double> {
        center + n * halfExtent
    }

    /// 某一轴在盒内的数据范围（0 = x，1 = y，2 = z）。
    public func range(axis: Int) -> ClosedRange<Double> {
        (center[axis] - halfExtent)...(center[axis] + halfExtent)
    }

    /// 按 `source` 的盒子归一化的几何，换到本视图的盒子里：`n' = n × scale + translation`。
    /// 平移、缩放时先拿旧几何套这个变换画，不等重新采样（同 2D 的 `screenTransform`）。
    public func boxTransform(from source: View3D) -> (scale: Double, translation: SIMD3<Double>) {
        guard halfExtent > 0, source.halfExtent > 0 else { return (1, .zero) }
        return (source.halfExtent / halfExtent, (source.center - center) / halfExtent)
    }

    // MARK: - 相机

    /// 相机位置（归一化坐标）。
    public var eye: SIMD3<Double> {
        let c = cos(elevation)
        return Self.cameraDistance * SIMD3(c * cos(azimuth), c * sin(azimuth), sin(elevation))
    }

    /// 着色器里算光照用的「相机位置」。透视时就是 `eye`；正交时视线处处平行，放到很远的地方，
    /// 每个像素到相机的方向才一致。
    public var shadingEye: SIMD3<Double> {
        isOrthographic ? eye * 1000 : eye
    }

    /// 相机的右、上、朝前三个单位向量（归一化坐标）。
    public var basis: (right: SIMD3<Double>, up: SIMD3<Double>, forward: SIMD3<Double>) {
        let forward = simd_normalize(-eye)
        // 等于 normalize(forward × z)，但正俯视时那个叉积为零，所以直接用方位角写。
        let right = SIMD3(-sin(azimuth), cos(azimuth), 0)
        let up = simd_cross(right, forward)
        return (right, up, forward)
    }

    /// 切到某根轴的平面视图：正交投影，坐标盒与缩放不动。
    public mutating func look(along axis: AxisView) {
        isOrthographic = true
        switch axis {
        case .x: azimuth = 0; elevation = 0
        case .y: azimuth = -Double.pi / 2; elevation = 0
        case .z: azimuth = -Double.pi / 2; elevation = Self.topElevation
        }
    }

    /// 未遮挡区的中心（像素），盒心投影到这里。
    public var focusX: Double { insetLeft + (widthPixels - insetLeft - insetRight) / 2 }
    public var focusY: Double { insetTop + (heightPixels - insetTop - insetBottom) / 2 }

    /// 透视投影的焦距（NDC 纵向单位）：让盒子的外接球正好占未遮挡区短边的 `fillFraction`。
    var focalNDC: Double {
        let clearWidth = max(widthPixels - insetLeft - insetRight, 1)
        let clearHeight = max(heightPixels - insetTop - insetBottom, 1)
        let d = Self.cameraDistance
        let r = Self.boundingRadius
        let tangent = r / (d * d - r * r).squareRoot()
        return Self.fillFraction * cameraZoom * min(clearWidth, clearHeight) / max(heightPixels, 1) / tangent
    }

    /// 盒心所在深度上，一个像素对应多少归一化单位。
    public var normalizedPerPixel: Double {
        Self.cameraDistance / (focalNDC * max(heightPixels, 1) / 2)
    }

    /// 盒心附近一个数据单位在屏幕上约多少像素（排刻度用）。
    public var pixelsPerUnit: Double {
        1 / (normalizedPerPixel * halfExtent)
    }

    /// 归一化坐标 → 裁剪空间（Metal 约定：深度 0…1，y 朝上），含未遮挡区的偏心。
    public func viewProjection() -> simd_double4x4 {
        let (right, up, forward) = basis
        let e = eye
        // 视图矩阵：列主序，行是 right / up / -forward。
        let view = simd_double4x4(columns: (
            SIMD4(right.x, up.x, -forward.x, 0),
            SIMD4(right.y, up.y, -forward.y, 0),
            SIMD4(right.z, up.z, -forward.z, 0),
            SIMD4(-simd_dot(right, e), -simd_dot(up, e), simd_dot(forward, e), 1)
        ))
        let sy = focalNDC
        let sx = sy * heightPixels / max(widthPixels, 1)
        let n = Self.nearPlane
        let f = Self.farPlane
        let a = f / (n - f)
        let b = n * f / (n - f)
        // 盒心不在画布正中而在未遮挡区中心：把投影整体平移过去（在 w 归一化之后生效）。
        let ox = (focusX - widthPixels / 2) / max(widthPixels / 2, 1)
        let oy = -(focusY - heightPixels / 2) / max(heightPixels / 2, 1)
        if isOrthographic {
            // 正交：盒心处的比例与透视一致（切换投影时盒子大小不跳），深度线性映射到 0…1。
            let scale = 1 / Self.cameraDistance
            let projection = simd_double4x4(columns: (
                SIMD4(sx * scale, 0, 0, 0),
                SIMD4(0, sy * scale, 0, 0),
                SIMD4(0, 0, -1 / (f - n), 0),
                SIMD4(ox, oy, -n / (f - n), 1)
            ))
            return projection * view
        }
        let projection = simd_double4x4(columns: (
            SIMD4(sx, 0, 0, 0),
            SIMD4(0, sy, 0, 0),
            SIMD4(-ox, -oy, a, -1),
            SIMD4(0, 0, b, 0)
        ))
        return projection * view
    }

    /// 归一化坐标投到屏幕：像素（左上角原点）与深度（0 近 … 1 远）。点在相机背后时为 nil。
    public func project(_ n: SIMD3<Double>) -> SIMD3<Double>? {
        let clip = viewProjection() * SIMD4(n, 1)
        guard clip.w > 1e-9 else { return nil }
        let ndc = SIMD3(clip.x, clip.y, clip.z) / clip.w
        return SIMD3(
            (ndc.x + 1) / 2 * widthPixels,
            (1 - ndc.y) / 2 * heightPixels,
            ndc.z
        )
    }

    // MARK: - 交互

    /// 拖动旋转：往右拖场景往右转，往下拖顶面转向自己。
    public mutating func orbit(byPoints delta: SIMD2<Double>) {
        azimuth -= delta.x * Self.orbitRadiansPerPoint
        elevation = min(max(elevation + delta.y * Self.orbitRadiansPerPoint, -Self.elevationLimit), Self.elevationLimit)
        azimuth = remainder(azimuth, 2 * Double.pi)
    }

    /// 平移：内容跟着手走（像素，y 向下）。
    public mutating func pan(byPixels delta: SIMD2<Double>) {
        let (right, up, _) = basis
        let k = normalizedPerPixel * halfExtent
        center += (-right * delta.x + up * delta.y) * k
    }

    /// 改范围：`factor > 1` 放大（盒子框住的范围变小，盒子在屏幕上大小不变）。
    public mutating func zoom(by factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        halfExtent = min(max(halfExtent / factor, Self.halfExtentRange.lowerBound), Self.halfExtentRange.upperBound)
    }

    /// 放大盒子：`factor > 1` 盒子连同图形在屏幕上变大，数据范围不变。
    public mutating func zoomCamera(by factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        cameraZoom = min(max(cameraZoom * factor, Self.cameraZoomRange.lowerBound), Self.cameraZoomRange.upperBound)
    }

    /// 把一个数据包围盒装进坐标盒，留一点边；盒子回到正好装进画面的大小。
    public mutating func fit(min lower: SIMD3<Double>, max upper: SIMD3<Double>, margin: Double = 0.08) {
        let half = (upper - lower) / 2
        let largest = Swift.max(half.x, half.y, half.z)
        guard largest.isFinite else { return }
        center = (lower + upper) / 2
        halfExtent = min(max(largest * (1 + margin), Self.halfExtentRange.lowerBound), Self.halfExtentRange.upperBound)
        if halfExtent < 1e-9 { halfExtent = 1 }
        cameraZoom = 1
    }
}
