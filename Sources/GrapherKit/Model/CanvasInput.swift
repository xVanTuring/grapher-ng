import Foundation

/// 画布的输入手感：滚轮、捏合、拖动各做什么。App 的画布和 Quick Look 预览共用这一份，两边的按键习惯一致。
/// 只管「做什么」，不碰 `NSEvent`（GrapherKit 不 import 界面框架）：调用方把事件换成这里的参数。
///
/// - 平面图：拖动 / 双指滚动 = 平移，捏合 / ⌘+滚动 = 缩放（以指针为锚）。
/// - 立体图：拖动 = 转相机，⇧+拖动 / 双指滚动 = 平移，捏合 / ⌘+滚动 = 缩放图形，⌥+捏合 / ⌥+滚动 = 放大盒子。
/// - 双指滚动**永远是平移**，不当缩放。
public enum CanvasInput {

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
    }

    /// 一次滚轮事件。
    public struct Scroll: Sendable {
        public var dx: Double
        public var dy: Double
        /// 触控板、妙控鼠标是连续的小量（true）；有级滚轮一格只有 1 左右（false）。
        public var isPrecise: Bool
        /// 手指离开之后的惯性阶段。
        public var isMomentum: Bool
        public var modifiers: Modifiers

        public init(dx: Double, dy: Double, isPrecise: Bool, isMomentum: Bool, modifiers: Modifiers) {
            self.dx = dx
            self.dy = dy
            self.isPrecise = isPrecise
            self.isMomentum = isMomentum
            self.modifiers = modifiers
        }
    }

    public enum Action: Equatable, Sendable {
        case none
        /// 平移，像素口径（平面图 `Viewport2D.pan(byPixels:)`，立体图 `View3D.pan(byPixels:)`）。
        case pan(SIMD2<Double>)
        /// 缩放图形：平面图以指针为锚；立体图改坐标盒框住的范围。
        case zoom(Double)
        /// 立体图放大盒子（只换投影，不重采）。
        case zoomBox(Double)
        /// 立体图转相机，点口径（`View3D.orbit(byPoints:)`）。
        case orbit(SIMD2<Double>)
    }

    /// 滚轮：普通滚动 = 平移，⌘+滚动 = 缩放图形，立体图 ⌥+滚动 = 放大盒子。缩放只在非惯性阶段消费——
    /// 否则触控板一甩会连着放大好几档。平面图按滚动量直接平移像素，立体图再乘屏幕倍率（两边原来的手感）。
    public static func scroll(_ scroll: Scroll, space: Bool, pointScale: Double) -> Action {
        var dx = scroll.dx
        var dy = scroll.dy
        // 有级滚轮一格只有 1 左右，触控板是连续的小量；不放大手感迟钝得离谱。
        if !scroll.isPrecise {
            dx *= 10
            dy *= 10
        }
        let zoomsBox = space && scroll.modifiers.contains(.option)
        if zoomsBox || scroll.modifiers.contains(.command) {
            guard dy != 0, !scroll.isMomentum else { return .none }
            let factor = min(max(exp(-dy * 0.008), 0.5), 2)
            return zoomsBox ? .zoomBox(factor) : .zoom(factor)
        }
        guard dx != 0 || dy != 0 else { return .none }
        return .pan(SIMD2(dx, dy) * (space ? pointScale : 1))
    }

    /// 捏合：缩放图形；立体图按住 ⌥ 放大盒子。
    public static func pinch(magnification: Double, modifiers: Modifiers, space: Bool) -> Action {
        let factor = 1 + magnification
        guard factor.isFinite, factor > 0 else { return .none }
        return space && modifiers.contains(.option) ? .zoomBox(factor) : .zoom(factor)
    }

    /// 拖动（位移是点，按画布的翻转坐标量，左上角原点、y 向下）：平面图平移；立体图转相机，按着 ⇧ 平移。
    /// `pansFromStart`：立体图按下那一刻就按着 ⇧，这一整次拖动都算平移（中途松开 ⇧ 也不变成旋转）。
    public static func drag(
        _ delta: SIMD2<Double>,
        modifiers: Modifiers,
        space: Bool,
        pansFromStart: Bool,
        pointScale: Double
    ) -> Action {
        if !space || pansFromStart || modifiers.contains(.shift) {
            return .pan(delta * pointScale)
        }
        return .orbit(delta)
    }
}
