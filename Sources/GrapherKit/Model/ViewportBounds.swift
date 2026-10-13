import Foundation

/// 数据坐标里的一个矩形，用来表示「所有曲线采样点的包围盒」。
public struct DataBounds: Equatable, Sendable {
    public var minX: Double
    public var maxX: Double
    public var minY: Double
    public var maxY: Double

    public init(minX: Double, maxX: Double, minY: Double, maxY: Double) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var midX: Double { (minX + maxX) / 2 }
    public var midY: Double { (minY + maxY) / 2 }
    public var isEmpty: Bool { !(width > 0) && !(height > 0) }

    public func union(_ other: DataBounds?) -> DataBounds {
        guard let other else { return self }
        return DataBounds(
            minX: Swift.min(minX, other.minX),
            maxX: Swift.max(maxX, other.maxX),
            minY: Swift.min(minY, other.minY),
            maxY: Swift.max(maxY, other.maxY)
        )
    }

    /// 两个矩形的交；不相交时为 nil（只在一条边上相切也算相交，退化成一条线）。
    public func intersection(_ other: DataBounds) -> DataBounds? {
        let result = DataBounds(
            minX: Swift.max(minX, other.minX),
            maxX: Swift.min(maxX, other.maxX),
            minY: Swift.max(minY, other.minY),
            maxY: Swift.min(maxY, other.maxY)
        )
        guard result.minX <= result.maxX, result.minY <= result.maxY else { return nil }
        return result
    }

    /// 收集一批折线（数据坐标）的包围盒。
    public static func enclosing(_ segments: [[SIMD2<Double>]]) -> DataBounds? {
        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity
        var found = false
        for segment in segments {
            for point in segment where point.x.isFinite && point.y.isFinite {
                found = true
                minX = Swift.min(minX, point.x)
                maxX = Swift.max(maxX, point.x)
                minY = Swift.min(minY, point.y)
                maxY = Swift.max(maxY, point.y)
            }
        }
        guard found else { return nil }
        return DataBounds(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }
}

/// 无限画布的**软边界**（抄 UniReader 的 `ScratchBounds`）：真无限会让人一路滚进空无一物的
/// 远方再也找不回来。规则只有一条——可见区必须与「内容包围盒外扩 `slackScreens` 个视口」相交；
/// 越界即拉回。内容为空时退化为「围着原点的一块」，于是新文档只能在原点附近小范围移动。
///
/// 换算：`Viewport2D` 存的是视口**中心**（UniReader 那边存的是左上角 `origin`），所以把它的
/// `origin ∈ [base.min - slack - vis, base.max + slack]` 平移到中心口径，正好是
/// `center ∈ [base.min - 4·half, base.max + 4·half]`。
public enum ViewportBounds {
    public static let slackScreens: Double = 1.5

    /// 视口中心允许落在的数据范围。
    public static func allowedCenterRange(content: DataBounds?, viewport: Viewport2D) -> DataBounds {
        let halfW = viewport.halfWidthData
        let halfH = viewport.halfHeightData
        let base = content ?? DataBounds(minX: 0, maxX: 0, minY: 0, maxY: 0)
        let reachX = halfW * (1 + 2 * slackScreens)
        let reachY = halfH * (1 + 2 * slackScreens)
        return DataBounds(
            minX: base.minX - reachX,
            maxX: base.maxX + reachX,
            minY: base.minY - reachY,
            maxY: base.maxY + reachY
        )
    }

    public static func clamp(_ viewport: Viewport2D, content: DataBounds?) -> Viewport2D {
        let range = allowedCenterRange(content: content, viewport: viewport)
        var out = viewport
        out.centerX = Swift.min(Swift.max(viewport.centerX, range.minX), range.maxX)
        out.centerY = Swift.min(Swift.max(viewport.centerY, range.minY), range.maxY)
        return out
    }
}
