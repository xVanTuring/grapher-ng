import Foundation
import simd

/// 讲解的一步：把一份图拆成几步，一步一步讲推导（比如曲面面积元 dS 是怎么来的）。
///
/// 每一步有标题、一段讲解文字（可以夹 TeX 公式：行内 `$…$`，单独成行 `$$…$$`），并规定：
/// - 这一步**显示哪些图层**（`visibleLayers`）；
/// - 相机转到哪（`camera`，nil = 不动，沿用上一步）；
/// - 参数取什么值（`parameters`，进这一步时从当前值平滑过渡过去），以及自动播放哪些参数（`plays`）。
///
/// 「正在看第几步」是窗口状态，不进文档；进入某一步时图层的显示由这一步决定，图层自己的显示开关不动
/// （见 `GrapherDocument.presenting(step:)`）。
public struct LessonStep: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    /// 讲解文字。空行分段；`$…$` 是行内公式，`$$…$$` 单独一行居中；`**…**` 加粗。
    public var text: String
    /// 这一步显示的图层。只在至少一步里出现过的图层才「归讲解管」，见 `GrapherDocument.lessonManagedLayers`。
    public var visibleLayers: [UUID]
    /// 这一步要突出的图层（选中它，画布上加一圈高亮）；nil 不改选中。
    public var focus: UUID?
    /// 进入这一步时相机转到哪；nil = 不动。
    public var camera: LessonCamera?
    /// 进入这一步时参数要变成的值（参数名 → 值），从当前值平滑过渡过去。没写的参数不动。
    public var parameters: [String: Double]
    /// 进入这一步后自动播放的参数名（同参数面板里的播放按钮）。
    public var plays: [String]

    public init(
        id: UUID = UUID(),
        title: String = "",
        text: String = "",
        visibleLayers: [UUID] = [],
        focus: UUID? = nil,
        camera: LessonCamera? = nil,
        parameters: [String: Double] = [:],
        plays: [String] = []
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.visibleLayers = visibleLayers
        self.focus = focus
        self.camera = camera
        self.parameters = parameters
        self.plays = plays
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, text, visibleLayers, focus, camera, parameters, plays
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        visibleLayers = try container.decodeIfPresent([UUID].self, forKey: .visibleLayers) ?? []
        focus = try container.decodeIfPresent(UUID.self, forKey: .focus)
        camera = try container.decodeIfPresent(LessonCamera.self, forKey: .camera)
        parameters = try container.decodeIfPresent([String: Double].self, forKey: .parameters) ?? [:]
        plays = try container.decodeIfPresent([String].self, forKey: .plays) ?? []
    }
}

/// 一步的取景。立体图存相机与坐标盒（`View3D` 只编码这五项，不含画布尺寸）；平面图存中心与横向看到多宽
/// （数据单位，按画布没被遮住的那块宽度换成倍率，所以与画布大小无关）。
public struct LessonCamera: Codable, Equatable, Sendable {
    public var space: View3D?
    public var planeCenter: SIMD2<Double>?
    public var planeWidth: Double?

    public init(space: View3D? = nil, planeCenter: SIMD2<Double>? = nil, planeWidth: Double? = nil) {
        self.space = space
        self.planeCenter = planeCenter
        self.planeWidth = planeWidth
    }

    /// 文档当前的取景。
    public init(of document: GrapherDocument) {
        if document.dimension == .space {
            var view = View3D.standard
            view.center = document.view3D.center
            view.halfExtent = document.view3D.halfExtent
            view.azimuth = document.view3D.azimuth
            view.elevation = document.view3D.elevation
            view.cameraZoom = document.view3D.cameraZoom
            self.init(space: view)
        } else {
            let viewport = document.viewport.unobscured
            self.init(planeCenter: SIMD2(viewport.centerX, viewport.centerY),
                      planeWidth: viewport.widthPixels / viewport.scale)
        }
    }
}

extension GrapherDocument {

    /// 归讲解管的图层：至少在一步里显示过。没出现在任何一步里的图层按它自己的显示开关，
    /// 所以讲解写好之后再加的图层照常显示。
    public var lessonManagedLayers: Set<UUID> {
        var ids = Set<UUID>()
        for step in lessonSteps { ids.formUnion(step.visibleLayers) }
        return ids
    }

    /// 第 `step` 步时这个图层显不显示（`step` 越界时按图层自己的开关）。
    public func isLayer(_ layer: Layer, visibleInStep step: Int) -> Bool {
        guard lessonSteps.indices.contains(step), lessonManagedLayers.contains(layer.id) else { return layer.isVisible }
        return lessonSteps[step].visibleLayers.contains(layer.id)
    }

    /// 讲解第 `step` 步时看到的文档：图层的显示按这一步来，别的不变。采样、写字、导出都用它；不存回文件。
    public func presenting(step: Int) -> GrapherDocument {
        guard lessonSteps.indices.contains(step) else { return self }
        let managed = lessonManagedLayers
        let shown = Set(lessonSteps[step].visibleLayers)
        var copy = self
        for index in copy.layers.indices where managed.contains(copy.layers[index].id) {
            copy.layers[index].isVisible = shown.contains(copy.layers[index].id)
        }
        return copy
    }

    /// 在第 `step` 步里显示 / 隐藏一个图层。原来不归讲解管的图层先「接管」：按它自己的开关补进其余各步，
    /// 这样别的步骤看起来和原来一样，只有这一步变了。
    public mutating func setLayer(_ id: UUID, visible: Bool, inStep step: Int) {
        guard lessonSteps.indices.contains(step), let layer = layers.first(where: { $0.id == id }) else { return }
        if !lessonManagedLayers.contains(id), layer.isVisible {
            for index in lessonSteps.indices where index != step {
                lessonSteps[index].visibleLayers.append(id)
            }
        }
        lessonSteps[step].visibleLayers.removeAll { $0 == id }
        if visible {
            // 按图层列表的顺序存，读起来和列表一致。
            let order = Dictionary(uniqueKeysWithValues: layers.enumerated().map { ($1.id, $0) })
            lessonSteps[step].visibleLayers.append(id)
            lessonSteps[step].visibleLayers.sort { (order[$0] ?? .max) < (order[$1] ?? .max) }
        }
    }

    /// 一路讲到第 `step` 步时的参数值与取景：前面各步写的参数值、相机依次生效，后面的盖掉前面的。
    /// 直接跳到某一步（步骤菜单、出图）时用它，和一步一步翻过来看到的一样。
    public func lessonState(at step: Int) -> (parameters: [String: Double], camera: LessonCamera?) {
        var values: [String: Double] = [:]
        var camera: LessonCamera?
        for index in lessonSteps.indices where index <= step {
            values.merge(lessonSteps[index].parameters) { _, new in new }
            if let next = lessonSteps[index].camera { camera = next }
        }
        return (values, camera)
    }

    /// 用眼前的样子新建一步：当前显示的图层（讲解中就是这一步显示的）、当前取景、所有参数的当前值。
    public func capturedStep(presenting step: Int?, title: String = "", text: String = "") -> LessonStep {
        let shown = step.map { presenting(step: $0) } ?? self
        var values: [String: Double] = [:]
        for parameter in parameters where parameter.isNameValid { values[parameter.name] = parameter.value }
        return LessonStep(
            title: title,
            text: text,
            visibleLayers: shown.layers.filter(\.isVisible).map(\.id),
            camera: LessonCamera(of: self),
            parameters: values
        )
    }
}

/// 两步之间的过渡：相机与参数在 `duration` 秒里平滑地变过去（先加速后减速）。纯数学，App 与嵌入块共用。
public enum LessonTransition {
    public static let duration = 0.8

    /// 0…1 的进度换成先快后慢的缓动。
    public static func ease(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    public static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    /// 方位角走近路：差值折到 (−π, π]。
    public static func mixAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var delta = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi }
        if delta <= -.pi { delta += 2 * .pi }
        return a + delta * t
    }

    /// 立体图的视角插值：只动相机与坐标盒，画布尺寸、遮挡保持 `from` 的。缩放按对数插值，放大缩小看起来匀速。
    public static func view(from: View3D, to: View3D, progress t: Double) -> View3D {
        var view = from
        view.azimuth = mixAngle(from.azimuth, to.azimuth, t)
        view.elevation = mix(from.elevation, to.elevation, t)
        view.center = from.center + (to.center - from.center) * t
        view.halfExtent = exp(mix(log(max(from.halfExtent, 1e-9)), log(max(to.halfExtent, 1e-9)), t))
        view.cameraZoom = exp(mix(log(max(from.cameraZoom, 1e-9)), log(max(to.cameraZoom, 1e-9)), t))
        return view
    }

    /// 平面图：中心线性、横向宽度按对数插值。
    public static func plane(
        fromCenter: SIMD2<Double>, fromWidth: Double, toCenter: SIMD2<Double>, toWidth: Double, progress t: Double
    ) -> (center: SIMD2<Double>, width: Double) {
        let center = fromCenter + (toCenter - fromCenter) * t
        let width = exp(mix(log(max(fromWidth, 1e-12)), log(max(toWidth, 1e-12)), t))
        return (center, width)
    }
}
