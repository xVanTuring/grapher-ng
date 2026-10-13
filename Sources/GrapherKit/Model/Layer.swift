import Foundation

/// 文档是平面图还是立体图。新建时定下，之后不变；两种文档各有各的图型和画布。
public enum DocumentDimension: String, Codable, CaseIterable, Sendable {
    case plane
    case space
}

public enum PlotKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case explicit
    case parametric
    case polar
    case implicit
    case region
    /// z = f(x, y)
    case surface
    /// (x, y, z) = F(u, v)
    case parametricSurface
    /// (x, y, z) = F(t)
    case spaceCurve
    /// F(x, y, z) = 0
    case implicitSurface

    public var id: String { rawValue }

    public var dimension: DocumentDimension {
        switch self {
        case .explicit, .parametric, .polar, .implicit, .region: return .plane
        case .surface, .parametricSurface, .spaceCurve, .implicitSurface: return .space
        }
    }

    /// 某种文档能用的图型，顺序即「新建」菜单与类型下拉框里的顺序。立体图里也能放平面曲线
    /// （显函数、参数方程、极坐标、隐函数）：画在 z = 0 平面上，或沿 z 延伸成竖直的曲面（同 Desmos 3D）。
    public static func cases(for dimension: DocumentDimension) -> [PlotKind] {
        switch dimension {
        case .plane: return allCases.filter { $0.dimension == .plane }
        case .space: return allCases.filter { $0.dimension == .space } + allCases.filter(\.canExtrude)
        }
    }

    /// 平面曲线：放进立体图时可以选「延伸到 3D」。不等式区域不进立体图。
    public var canExtrude: Bool {
        switch self {
        case .explicit, .parametric, .polar, .implicit: return true
        case .region, .surface, .parametricSurface, .spaceCurve, .implicitSurface: return false
        }
    }

    public var displayName: String {
        switch self {
        case .explicit: return L("Explicit y=f(x)")
        case .parametric: return L("Parametric")
        case .polar: return L("Polar r=f(θ)")
        case .implicit: return L("Implicit F(x,y)=0")
        case .region: return L("Inequality region")
        case .surface: return L("Surface z=f(x,y)")
        case .parametricSurface: return L("Parametric surface")
        case .spaceCurve: return L("Space curve")
        case .implicitSurface: return L("Implicit surface F(x,y,z)=0")
        }
    }

    public var shortName: String {
        switch self {
        case .explicit: return L("Explicit")
        case .parametric: return L("Parametric")
        case .polar: return L("Polar")
        case .implicit: return L("Implicit")
        case .region: return L("Region")
        case .surface: return L("Surface")
        case .parametricSurface: return L("Parametric surface")
        case .spaceCurve: return L("Space curve")
        case .implicitSurface: return L("Implicit surface")
        }
    }

    /// Variables the primary formula is compiled against. Note that polar
    /// layers accept both `theta` and `t`, so both slots receive the angle.
    public var primaryVariables: [String] {
        switch self {
        case .explicit: return ["x"]
        case .parametric, .spaceCurve: return ["t"]
        case .polar: return ["theta", "t"]
        case .implicit, .region, .surface: return ["x", "y"]
        case .parametricSurface: return ["u", "v"]
        case .implicitSurface: return ["x", "y", "z"]
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
        case .parametric, .spaceCurve: return ["t"]
        case .parametricSurface: return ["u", "v"]
        default: return []
        }
    }

    /// 第三个公式（z 分量）的变量：参数曲面与空间曲线才有。
    public var tertiaryVariables: [String] {
        switch self {
        case .spaceCurve: return ["t"]
        case .parametricSurface: return ["u", "v"]
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
        case .surface: return "sin(x)*cos(y)"
        case .parametricSurface: return "(2 + cos(v))*cos(u)"
        case .spaceCurve: return "2*cos(t)"
        case .implicitSurface: return "x^2 + y^2 + z^2 - 4"
        }
    }

    public var secondaryPlaceholder: String {
        switch self {
        case .parametric: return "sin(t)"
        case .parametricSurface: return "(2 + cos(v))*sin(u)"
        case .spaceCurve: return "2*sin(t)"
        default: return ""
        }
    }

    public var tertiaryPlaceholder: String {
        switch self {
        case .parametricSurface: return "sin(v)"
        case .spaceCurve: return "t/3"
        default: return ""
        }
    }

    public var needsSecondaryFormula: Bool {
        self == .parametric || self == .parametricSurface || self == .spaceCurve
    }

    public var needsTertiaryFormula: Bool { self == .parametricSurface || self == .spaceCurve }

    /// 用到参数范围（定义域）的图型。显式曲面与隐式曲面的范围就是坐标盒，不另设。
    public var usesDomain: Bool {
        switch self {
        case .explicit, .parametric, .polar, .spaceCurve, .parametricSurface: return true
        case .implicit, .region, .surface, .implicitSurface: return false
        }
    }

    /// 参数曲面还有第二个参数 v 的范围。
    public var usesSecondDomain: Bool { self == .parametricSurface }
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
    /// 第三个公式：参数曲面、空间曲线的 z 分量。
    public var tertiaryFormula: String
    public var relation: RegionRelation
    public var domainLower: Double
    public var domainUpper: Double
    /// 第二个参数的范围：参数曲面的 v。
    public var domain2Lower: Double
    public var domain2Upper: Double
    /// When false the domain defaults to whatever the viewport currently shows.
    public var usesExplicitDomain: Bool
    /// 平面曲线放在立体图里时：false 画成 z = 0 平面上的一条曲线，true 沿 z 延伸成竖直曲面。
    public var extrudesInSpace: Bool
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
        tertiaryFormula: String = "",
        relation: RegionRelation = .lessOrEqual,
        domainLower: Double = 0,
        domainUpper: Double = 2 * Double.pi,
        domain2Lower: Double = 0,
        domain2Upper: Double = 2 * Double.pi,
        usesExplicitDomain: Bool = false,
        extrudesInSpace: Bool = false,
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
        self.tertiaryFormula = tertiaryFormula
        self.relation = relation
        self.domainLower = domainLower
        self.domainUpper = domainUpper
        self.domain2Lower = domain2Lower
        self.domain2Upper = domain2Upper
        self.usesExplicitDomain = usesExplicitDomain
        self.extrudesInSpace = extrudesInSpace
        self.lineStyle = lineStyle
        self.fillStyle = fillStyle
        self.extraLevels = extraLevels
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, isVisible, formula, secondaryFormula, tertiaryFormula, relation
        case domainLower, domainUpper, domain2Lower, domain2Upper, usesExplicitDomain, extrudesInSpace
        case lineStyle, fillStyle, extraLevels
    }

    /// 只有 3D 才用到的字段（第三个公式、第二个定义域、延伸到 3D）在 2D 时代的文件里没有，读到缺省值。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(PlotKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        isVisible = try container.decode(Bool.self, forKey: .isVisible)
        formula = try container.decode(String.self, forKey: .formula)
        secondaryFormula = try container.decode(String.self, forKey: .secondaryFormula)
        tertiaryFormula = try container.decodeIfPresent(String.self, forKey: .tertiaryFormula) ?? ""
        relation = try container.decode(RegionRelation.self, forKey: .relation)
        domainLower = try container.decode(Double.self, forKey: .domainLower)
        domainUpper = try container.decode(Double.self, forKey: .domainUpper)
        domain2Lower = try container.decodeIfPresent(Double.self, forKey: .domain2Lower) ?? 0
        domain2Upper = try container.decodeIfPresent(Double.self, forKey: .domain2Upper) ?? 2 * Double.pi
        usesExplicitDomain = try container.decode(Bool.self, forKey: .usesExplicitDomain)
        extrudesInSpace = try container.decodeIfPresent(Bool.self, forKey: .extrudesInSpace) ?? false
        lineStyle = try container.decode(LineStyle.self, forKey: .lineStyle)
        fillStyle = try container.decode(FillStyle.self, forKey: .fillStyle)
        extraLevels = try container.decode([Double].self, forKey: .extraLevels)
    }

    /// A ready-to-edit layer for the given plot kind, styled with the palette entry.
    public static func makeDefault(kind: PlotKind, index: Int) -> Layer {
        let color = RGBAColor.paletteColor(index)
        var formula = kind.primaryPlaceholder
        var secondary = kind.secondaryPlaceholder
        let name = "\(kind.shortName) \(index + 1)"
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
        case .polar:
            formula = "1 + cos(theta)"
        case .implicit:
            formula = "x^2 + y^2 - 1"
        case .region:
            formula = "x^2 + y^2 - 1"
        case .spaceCurve:
            // 螺旋线：t 走两圈。
            lower = -2 * Double.pi
            upper = 2 * Double.pi
        case .surface, .parametricSurface, .implicitSurface:
            break
        }

        return Layer(
            kind: kind,
            name: name,
            formula: formula,
            secondaryFormula: secondary,
            tertiaryFormula: kind.tertiaryPlaceholder,
            domainLower: lower,
            domainUpper: upper,
            domain2Lower: 0,
            domain2Upper: 2 * Double.pi,
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
