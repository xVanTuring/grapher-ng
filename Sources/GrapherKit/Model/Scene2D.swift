import Foundation

/// Geometry handed to the Metal renderer.
///
/// Everything is already in **backing pixels with the origin at the top-left**,
/// because that is what the rasteriser wants. The renderer does no coordinate
/// maths of its own; it only turns these primitives into triangles.
///
/// Commands are kept as an ordered list so that layer stacking order survives
/// all the way to the draw calls.
public enum Draw2D: Equatable, Sendable {
    /// A stroked polyline. The renderer expands it into screen-space quads and
    /// computes exact pixel coverage, so it stays smooth at any zoom.
    case polyline(PolylinePrimitive)
    /// Axis-aligned rectangles, each with its own constant coverage. Used for
    /// filled regions: interior runs come in at coverage 1, edge pixels carry
    /// their sub-pixel area.
    case rects(RectPrimitiveBatch)
    /// Small discs, used for marked points and self-intersections.
    case markers(MarkerPrimitiveBatch)
}

public struct PolylinePrimitive: Equatable, Sendable {
    public var points: [SIMD2<Double>]
    public var color: RGBAColor
    /// Stroke width in backing pixels.
    public var width: Double
    /// When true the last point is joined back to the first.
    public var isClosed: Bool

    public init(points: [SIMD2<Double>], color: RGBAColor, width: Double, isClosed: Bool = false) {
        self.points = points
        self.color = color
        self.width = width
        self.isClosed = isClosed
    }
}

public struct RectPrimitiveBatch: Equatable, Sendable {
    /// x0, x1 are left/right in pixels; y0, y1 are top/bottom in pixels.
    public var geometry: [SIMD4<Float>]
    /// Coverage in 0...1 per rectangle.
    public var coverage: [Float]
    public var color: RGBAColor

    public init(geometry: [SIMD4<Float>] = [], coverage: [Float] = [], color: RGBAColor) {
        self.geometry = geometry
        self.coverage = coverage
        self.color = color
    }

    public var count: Int { geometry.count }
}

public struct MarkerPrimitiveBatch: Equatable, Sendable {
    public var positions: [SIMD2<Double>]
    /// Radius in backing pixels.
    public var radius: Double
    public var color: RGBAColor

    public init(positions: [SIMD2<Double>], radius: Double, color: RGBAColor) {
        self.positions = positions
        self.radius = radius
        self.color = color
    }
}

/// 屏幕像素到屏幕像素的等比变换：`p' = p × scale + translation`。
///
/// 后台采样跟不上手势时，渲染器拿上一份几何套这个变换画到当前视口上；线宽、标记半径
/// 不跟着缩放（它们本来就是屏幕像素口径）。
public struct ScreenTransform2D: Equatable, Sendable {
    public var scale: Double
    public var translation: SIMD2<Double>

    public init(scale: Double, translation: SIMD2<Double>) {
        self.scale = scale
        self.translation = translation
    }

    public static let identity = ScreenTransform2D(scale: 1, translation: .zero)

    public func apply(_ point: SIMD2<Double>) -> SIMD2<Double> {
        point * scale + translation
    }
}

public struct Scene2D: Equatable, Sendable {
    public var background: RGBAColor
    public var commands: [Draw2D]

    public init(background: RGBAColor = .white, commands: [Draw2D] = []) {
        self.background = background
        self.commands = commands
    }

    public mutating func append(_ command: Draw2D) {
        commands.append(command)
    }

    /// Total pixel count of the geometry, used to decide whether a re-render is
    /// worth its cost during interactive dragging.
    public var approximatePrimitiveCount: Int {
        var n = 0
        for command in commands {
            switch command {
            case .polyline(let p): n += p.points.count
            case .rects(let r): n += r.count
            case .markers(let m): n += m.positions.count
            }
        }
        return n
    }
}
