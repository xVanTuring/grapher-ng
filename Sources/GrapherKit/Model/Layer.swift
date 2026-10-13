import Foundation

public enum PlotKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case explicit
    case parametric
    case polar
    case implicit
    case region

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .explicit: return "显函数 y=f(x)"
        case .parametric: return "参数方程"
        case .polar: return "极坐标 r=f(θ)"
        case .implicit: return "隐函数 F(x,y)=0"
        case .region: return "不等式区域"
        }
    }

    public var shortName: String {
        switch self {
        case .explicit: return "显函数"
        case .parametric: return "参数方程"
        case .polar: return "极坐标"
        case .implicit: return "隐函数"
        case .region: return "区域"
        }
    }

    /// Variables the primary formula is compiled against. Note that polar
    /// layers accept both `theta` and `t`, so both slots receive the angle.
    public var primaryVariables: [String] {
        switch self {
        case .explicit: return ["x"]
        case .parametric: return ["t"]
        case .polar: return ["theta", "t"]
        case .implicit, .region: return ["x", "y"]
        }
    }

    /// The value list for a primary formula evaluated at one point. Every slot
    /// carries the same argument, which is what the curve samplers want.
    public func primaryValues(argument: Double) -> [Double] {
        [Double](repeating: argument, count: primaryVariables.count)
    }

    /// Variables the secondary formula is compiled against.
    public var secondaryVariables: [String] {
        switch self {
        case .parametric: return ["t"]
        default: return []
        }
    }

    public var primaryPlaceholder: String {
        switch self {
        case .explicit: return "sin(x)"
        case .parametric: return "cos(t)"
        case .polar: return "1 + cos(theta)"
        case .implicit: return "x^2 + y^2 - 1"
        case .region: return "x^2 + y^2 - 1"
        }
    }

    public var secondaryPlaceholder: String {
        switch self {
        case .parametric: return "sin(t)"
        default: return ""
        }
    }

    public var needsSecondaryFormula: Bool { self == .parametric }
    public var usesDomain: Bool { self != .region && self != .implicit }
    public var usesRelation: Bool { self == .region }
}

public enum RegionRelation: String, Codable, CaseIterable, Identifiable, Sendable {
    case less
    case lessOrEqual
    case greater
    case greaterOrEqual

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .less: return "<"
        case .lessOrEqual: return "≤"
        case .greater: return ">"
        case .greaterOrEqual: return "≥"
        }
    }

    /// True when a sample with the given value of F lies inside the region.
    public func contains(_ value: Double) -> Bool {
        switch self {
        case .less: return value < 0
        case .lessOrEqual: return value <= 0
        case .greater: return value > 0
        case .greaterOrEqual: return value >= 0
        }
    }
}

public struct LineStyle: Codable, Equatable, Sendable {
    public var color: RGBAColor
    /// Stroke width in points (multiplied by the backing scale before rendering).
    public var width: Double
    public var isDashed: Bool
    public var dashLength: Double
    public var dashGap: Double

    public init(
        color: RGBAColor = .black,
        width: Double = 1.6,
        isDashed: Bool = false,
        dashLength: Double = 6,
        dashGap: Double = 4
    ) {
        self.color = color
        self.width = width
        self.isDashed = isDashed
        self.dashLength = dashLength
        self.dashGap = dashGap
    }
}

public struct FillStyle: Codable, Equatable, Sendable {
    public var color: RGBAColor
    public var isFilled: Bool
    /// Opacity multiplier applied on top of `color.a`.
    public var opacity: Double

    public init(color: RGBAColor = RGBAColor(0.11, 0.45, 0.85, 0.25), isFilled: Bool = true, opacity: Double = 1) {
        self.color = color
        self.isFilled = isFilled
        self.opacity = opacity
    }
}

public struct Layer: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: PlotKind
    public var name: String
    public var isVisible: Bool
    public var formula: String
    public var secondaryFormula: String
    public var relation: RegionRelation
    public var domainLower: Double
    public var domainUpper: Double
    /// When false the domain defaults to whatever the viewport currently shows.
    public var usesExplicitDomain: Bool
    public var lineStyle: LineStyle
    public var fillStyle: FillStyle
    /// Extra contour levels drawn in addition to zero, for `implicit` layers.
    public var extraLevels: [Double]

    public init(
        id: UUID = UUID(),
        kind: PlotKind,
        name: String,
        isVisible: Bool = true,
        formula: String,
        secondaryFormula: String = "",
        relation: RegionRelation = .lessOrEqual,
        domainLower: Double = 0,
        domainUpper: Double = 2 * Double.pi,
        usesExplicitDomain: Bool = false,
        lineStyle: LineStyle = LineStyle(),
        fillStyle: FillStyle = FillStyle(),
        extraLevels: [Double] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.isVisible = isVisible
        self.formula = formula
        self.secondaryFormula = secondaryFormula
        self.relation = relation
        self.domainLower = domainLower
        self.domainUpper = domainUpper
        self.usesExplicitDomain = usesExplicitDomain
        self.lineStyle = lineStyle
        self.fillStyle = fillStyle
        self.extraLevels = extraLevels
    }

    /// A ready-to-edit layer for the given plot kind, styled with the palette entry.
    public static func makeDefault(kind: PlotKind, index: Int) -> Layer {
        let color = RGBAColor.paletteColor(index)
        var formula = kind.primaryPlaceholder
        var secondary = kind.secondaryPlaceholder
        var name = "\(kind.shortName) \(index + 1)"
        var lower = 0.0
        var upper = 2 * Double.pi

        switch kind {
        case .explicit:
            lower = -10
            upper = 10
        case .parametric:
            // A heart-shaped curve reads well as a first impression.
            formula = "16*sin(t)^3"
            secondary = "13*cos(t) - 5*cos(2*t) - 2*cos(3*t) - cos(4*t)"
            name = "参数方程 \(index + 1)"
        case .polar:
            formula = "1 + cos(theta)"
        case .implicit:
            formula = "x^2 + y^2 - 1"
            name = "隐函数 \(index + 1)"
        case .region:
            formula = "x^2 + y^2 - 1"
            name = "区域 \(index + 1)"
        }

        return Layer(
            kind: kind,
            name: name,
            formula: formula,
            secondaryFormula: secondary,
            domainLower: lower,
            domainUpper: upper,
            usesExplicitDomain: false,
            lineStyle: LineStyle(color: color, width: 1.8),
            fillStyle: FillStyle(color: color.withAlpha(0.22))
        )
    }
}

public struct ParameterDefinition: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var value: Double
    public var lowerBound: Double
    public var upperBound: Double

    public init(
        id: UUID = UUID(),
        name: String,
        value: Double = 1,
        lowerBound: Double = -5,
        upperBound: Double = 5
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    /// Names the expression language already claims, plus the axis variables.
    public static let reservedNames: Set<String> = [
        "pi", "π", "e", "tau", "τ", "x", "y", "z", "t", "theta", "θ", "r", "u", "v",
        "sin", "cos", "tan", "cot", "sec", "csc",
        "asin", "acos", "atan", "atan2",
        "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
        "exp", "ln", "log", "log2", "log10", "sqrt", "cbrt", "abs", "sign",
        "floor", "ceil", "round", "trunc", "erf", "gamma",
        "mod", "pow", "hypot", "min", "max", "clamp", "step", "smoothstep", "if",
    ]

    public var isNameValid: Bool {
        guard !name.isEmpty else { return false }
        guard name.first?.isNumber == false else { return false }
        guard !Self.reservedNames.contains(name) else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
