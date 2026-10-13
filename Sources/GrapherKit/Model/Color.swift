import Foundation

/// A color in linear-ish sRGB components, each in 0...1.
public struct RGBAColor: Codable, Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public func withAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(r, g, b, alpha)
    }

    public static let black = RGBAColor(0, 0, 0)
    public static let white = RGBAColor(1, 1, 1)

    public static let defaultPalette: [RGBAColor] = [
        RGBAColor(0.85, 0.20, 0.24),
        RGBAColor(0.11, 0.45, 0.85),
        RGBAColor(0.13, 0.60, 0.31),
        RGBAColor(0.90, 0.53, 0.09),
        RGBAColor(0.55, 0.25, 0.75),
        RGBAColor(0.05, 0.62, 0.66),
        RGBAColor(0.80, 0.30, 0.62),
        RGBAColor(0.42, 0.36, 0.20),
    ]

    public static func paletteColor(_ index: Int) -> RGBAColor {
        defaultPalette[((index % defaultPalette.count) + defaultPalette.count) % defaultPalette.count]
    }
}

/// Theme colors for the chrome drawn underneath the user's plots.
public struct Theme: Codable, Equatable, Sendable {
    public var background: RGBAColor
    public var axes: RGBAColor
    public var grid: RGBAColor
    public var minorGrid: RGBAColor
    public var label: RGBAColor

    public init(
        background: RGBAColor = RGBAColor(1, 1, 1),
        axes: RGBAColor = RGBAColor(0.25, 0.25, 0.27),
        grid: RGBAColor = RGBAColor(0.80, 0.82, 0.85),
        minorGrid: RGBAColor = RGBAColor(0.92, 0.93, 0.95),
        label: RGBAColor = RGBAColor(0.30, 0.30, 0.33)
    ) {
        self.background = background
        self.axes = axes
        self.grid = grid
        self.minorGrid = minorGrid
        self.label = label
    }

    public static let light = Theme()
    public static let dark = Theme(
        background: RGBAColor(0.11, 0.11, 0.13),
        axes: RGBAColor(0.78, 0.79, 0.82),
        grid: RGBAColor(0.30, 0.31, 0.35),
        minorGrid: RGBAColor(0.20, 0.21, 0.24),
        label: RGBAColor(0.75, 0.76, 0.80)
    )
}
