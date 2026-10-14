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
    /// 两个曲面图层的交线（引用另外两个图层，自己没有公式）
    case surfaceIntersection
    /// 空间里的一个点 (x, y, z)，三个公式只能含参数（不含变量）
    case point
    /// 另一个图层（点、空间曲线、曲面交线）在平面上的正投影，没有公式
    case projection
    /// 平面图：显函数 / 参数方程 / 极坐标上一点的切线或法线，没有公式
    case tangent
    /// 立体图：显式曲面或参数曲面上一点的切平面（连同法线），没有公式
    case tangentPlane
    /// 自由文字标注：文字写在 `formula` 里（不当公式编译），位置是 `anchorU/V/W`。平面图、立体图都能放
    case text
    /// 平面图：散点数据，`formula` 里每行一个点（"x, y"，逗号 / 空格 / 制表符分隔），可选画最小二乘拟合直线
    case scatter
    /// 立体图：显式曲面 z = f(x, y) 的梯度场，在网格上画箭头，箭头越长颜色越暖梯度越大，没有公式
    case gradientField
    /// 立体图：从几个起点沿梯度一路上升（或下降）的流线。`formula` 里每行一个起点 "x, y"，
    /// `secondaryFormula` 是小球在路径上的位置（0…1，可以写参数），其余引用显式曲面
    case gradientFlow

    public var id: String { rawValue }

    public var dimension: DocumentDimension {
        switch self {
        case .explicit, .parametric, .polar, .implicit, .region, .tangent, .text, .scatter: return .plane
        case .surface, .parametricSurface, .spaceCurve, .implicitSurface, .surfaceIntersection, .point, .projection,
             .tangentPlane, .gradientField, .gradientFlow:
            return .space
        }
    }

    /// 某种文档能用的图型，顺序即「新建」菜单与类型下拉框里的顺序。立体图里也能放平面曲线
    /// （显函数、参数方程、极坐标、隐函数）：画在 z = 0 平面上，或沿 z 延伸成竖直的曲面（同 Desmos 3D）。
    public static func cases(for dimension: DocumentDimension) -> [PlotKind] {
        switch dimension {
        case .plane: return allCases.filter { $0.dimension == .plane }
        case .space: return allCases.filter { $0.dimension == .space } + allCases.filter(\.canExtrude) + [.text]
        }
    }

    /// 平面曲线：放进立体图时可以选「延伸到 3D」。不等式区域不进立体图。
    public var canExtrude: Bool {
        switch self {
        case .explicit, .parametric, .polar, .implicit: return true
        case .region, .surface, .parametricSurface, .spaceCurve, .implicitSurface, .surfaceIntersection, .point,
             .projection, .tangent, .tangentPlane, .text, .scatter, .gradientField, .gradientFlow:
            return false
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
        case .surfaceIntersection: return L("Surface intersection")
        case .point: return L("Point (x, y, z)")
        case .projection: return L("Projection onto a plane")
        case .tangent: return L("Tangent / normal line")
        case .tangentPlane: return L("Tangent plane")
        case .text: return L("Text label")
        case .scatter: return L("Scatter data")
        case .gradientField: return L("Gradient field")
        case .gradientFlow: return L("Gradient flow lines")
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
        case .surfaceIntersection: return L("Intersection")
        case .point: return L("Point")
        case .projection: return L("Projection")
        case .tangent: return L("Tangent")
        case .tangentPlane: return L("Tangent plane")
        case .text: return L("Text")
        case .scatter: return L("Scatter")
        case .gradientField: return L("Gradient")
        case .gradientFlow: return L("Flow")
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
        case .surfaceIntersection, .point, .projection, .tangent, .tangentPlane, .text, .scatter, .gradientField,
             .gradientFlow:
            return []
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
        case .surfaceIntersection, .projection, .tangent, .tangentPlane, .gradientField: return ""
        case .gradientFlow: return "1.5, 0.5\n-2, 2\n0.5, -3\n-3, -1.5"
        case .text: return "Text"
        case .scatter: return "1, 2.1\n2, 3.9\n3, 6.2\n4, 7.8"
        case .point: return "1"
        }
    }

    public var secondaryPlaceholder: String {
        switch self {
        case .parametric: return "sin(t)"
        case .parametricSurface: return "(2 + cos(v))*sin(u)"
        case .spaceCurve: return "2*sin(t)"
        case .gradientFlow: return "1"
        case .point: return "2"
        default: return ""
        }
    }

    public var tertiaryPlaceholder: String {
        switch self {
        case .parametricSurface: return "sin(v)"
        case .spaceCurve: return "t/3"
        case .point: return "3"
        default: return ""
        }
    }

    /// 交线、投影、切线、切平面图层没有公式，只引用别的图层；文字标注的 `formula` 是要写的字，不当公式编译。
    public var needsFormula: Bool {
        switch self {
        case .surfaceIntersection, .projection, .tangent, .tangentPlane, .text, .scatter, .gradientField, .gradientFlow:
            return false
        default: return true
        }
    }

    /// 能当梯度场来源的曲面：显式曲面 z = f(x, y)。
    public var isGradientSource: Bool { self == .surface }

    /// 能当切线来源的平面曲线。
    public var isTangentSource: Bool { self == .explicit || self == .parametric || self == .polar }

    /// 能当切平面来源的曲面。
    public var isTangentPlaneSource: Bool { self == .surface || self == .parametricSurface }

    /// 能当投影来源的图型：点、空间曲线、曲面交线。
    public var isProjectable: Bool {
        switch self {
        case .point, .spaceCurve, .surfaceIntersection: return true
        default: return false
        }
    }

    /// 能当交线来源的图型：立体图里画成一张面的那几种（平面曲线「延伸到 3D」之后也是一张面）。
    public var isSurfaceSource: Bool {
        switch self {
        case .surface, .parametricSurface, .implicitSurface: return true
        default: return false
        }
    }

    public var needsSecondaryFormula: Bool {
        self == .parametric || self == .parametricSurface || self == .spaceCurve || self == .point
    }

    public var needsTertiaryFormula: Bool {
        self == .parametricSurface || self == .spaceCurve || self == .point
    }

    /// 用到参数范围（定义域）的图型。显式曲面与隐式曲面的范围就是坐标盒，不另设。
    public var usesDomain: Bool {
        switch self {
        case .explicit, .parametric, .polar, .spaceCurve, .parametricSurface: return true
        case .implicit, .region, .surface, .implicitSurface, .surfaceIntersection, .point, .projection,
             .tangent, .tangentPlane, .text, .scatter, .gradientField, .gradientFlow:
            return false
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

/// 投影图层往哪张平面上投：三张坐标面（位置由 `projectionOffset` 定，如 z = c），或另一个平面图层（`sourceB`）。
public enum ProjectionTarget: String, Codable, CaseIterable, Sendable {
    /// z = offset 平面（俯视）
    case xy
    /// x = offset 平面（侧视）
    case yz
    /// y = offset 平面（正视）
    case xz
    case plane

    public var displayName: String {
        switch self {
        case .xy: return L("xy plane (z = c)")
        case .yz: return L("yz plane (x = c)")
        case .xz: return L("xz plane (y = c)")
        case .plane: return L("A plane layer")
        }
    }

    /// 坐标面的单位法向；`plane` 没有。
    public var normal: SIMD3<Double>? {
        switch self {
        case .xy: return SIMD3(0, 0, 1)
        case .yz: return SIMD3(1, 0, 0)
        case .xz: return SIMD3(0, 1, 0)
        case .plane: return nil
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
    /// 交线图层的两个来源（另外两个图层的 id）。来源被删掉或不是曲面时，交线什么都不画。
    public var sourceA: UUID?
    public var sourceB: UUID?
    /// 投影图层：投到哪里、坐标面的位置、是否画出投影线（从原图形连到投影的细线）。
    public var projectionTarget: ProjectionTarget
    public var projectionOffset: Double
    public var showsProjectors: Bool
    /// 投影图层：沿这个方向做斜投影；nil 是正投影（垂直于目标平面）。
    public var projectionDirection: SIMD3<Double>?
    /// 点图层：在点旁边写出图层名（A、B、C……）。
    public var showsLabel: Bool
    /// 切线 / 切平面图层：切点的位置（切线：显函数的 x、参数方程的 t、极坐标的 θ；
    /// 切平面：显式曲面的 x、y，参数曲面的 u、v），以及切线图层画法线而不是切线。
    public var anchorU: Double
    public var anchorV: Double
    public var drawsNormal: Bool
    /// 文字标注：位置的第三个坐标（立体图的 z）与字号（点）。
    public var anchorW: Double
    public var fontSize: Double
    /// 散点图：画最小二乘拟合直线。
    public var showsFit: Bool
    /// 梯度场图层：每个方向画多少个箭头、箭头长度的倍数（负数画下降方向 −∇f）、箭头画在曲面上还是投到地面。
    public var gridDensity: Int
    public var arrowScale: Double
    public var gradientOnFloor: Bool
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
        sourceA: UUID? = nil,
        sourceB: UUID? = nil,
        projectionTarget: ProjectionTarget = .xy,
        projectionOffset: Double = 0,
        showsProjectors: Bool = true,
        projectionDirection: SIMD3<Double>? = nil,
        showsLabel: Bool = false,
        anchorU: Double = 0,
        anchorV: Double = 0,
        drawsNormal: Bool = false,
        anchorW: Double = 0,
        fontSize: Double = 14,
        showsFit: Bool = false,
        gridDensity: Int = 12,
        arrowScale: Double = 1,
        gradientOnFloor: Bool = false,
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
        self.sourceA = sourceA
        self.sourceB = sourceB
        self.projectionTarget = projectionTarget
        self.projectionOffset = projectionOffset
        self.showsProjectors = showsProjectors
        self.projectionDirection = projectionDirection
        self.showsLabel = showsLabel
        self.anchorU = anchorU
        self.anchorV = anchorV
        self.drawsNormal = drawsNormal
        self.anchorW = anchorW
        self.fontSize = fontSize
        self.showsFit = showsFit
        self.gridDensity = gridDensity
        self.arrowScale = arrowScale
        self.gradientOnFloor = gradientOnFloor
        self.lineStyle = lineStyle
        self.fillStyle = fillStyle
        self.extraLevels = extraLevels
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, isVisible, formula, secondaryFormula, tertiaryFormula, relation
        case domainLower, domainUpper, domain2Lower, domain2Upper, usesExplicitDomain, extrudesInSpace
        case sourceA, sourceB, projectionTarget, projectionOffset, showsProjectors, showsLabel
        case anchorU, anchorV, drawsNormal, projectionDirection, anchorW, fontSize, showsFit
        case gridDensity, arrowScale, gradientOnFloor
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
        sourceA = try container.decodeIfPresent(UUID.self, forKey: .sourceA)
        sourceB = try container.decodeIfPresent(UUID.self, forKey: .sourceB)
        projectionTarget = try container.decodeIfPresent(ProjectionTarget.self, forKey: .projectionTarget) ?? .xy
        projectionOffset = try container.decodeIfPresent(Double.self, forKey: .projectionOffset) ?? 0
        showsProjectors = try container.decodeIfPresent(Bool.self, forKey: .showsProjectors) ?? true
        showsLabel = try container.decodeIfPresent(Bool.self, forKey: .showsLabel) ?? false
        anchorU = try container.decodeIfPresent(Double.self, forKey: .anchorU) ?? 0
        anchorV = try container.decodeIfPresent(Double.self, forKey: .anchorV) ?? 0
        drawsNormal = try container.decodeIfPresent(Bool.self, forKey: .drawsNormal) ?? false
        projectionDirection = try container.decodeIfPresent(SIMD3<Double>.self, forKey: .projectionDirection)
        anchorW = try container.decodeIfPresent(Double.self, forKey: .anchorW) ?? 0
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 14
        showsFit = try container.decodeIfPresent(Bool.self, forKey: .showsFit) ?? false
        gridDensity = try container.decodeIfPresent(Int.self, forKey: .gridDensity) ?? 12
        arrowScale = try container.decodeIfPresent(Double.self, forKey: .arrowScale) ?? 1
        gradientOnFloor = try container.decodeIfPresent(Bool.self, forKey: .gradientOnFloor) ?? false
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
        var lineWidth = 1.8

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
        case .surface, .parametricSurface, .implicitSurface, .surfaceIntersection, .projection, .tangent, .tangentPlane:
            break
        case .gradientField:
            lineWidth = 2
        case .gradientFlow:
            lineWidth = 2.6
        case .text:
            lineWidth = 1.8
        case .scatter:
            // 点的大小用线宽；默认比线粗一些。
            lineWidth = 2.4
        case .point:
            // 默认大小比线宽大一点，一眼能看见。
            lineWidth = 3
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
            showsLabel: kind == .point,
            lineStyle: LineStyle(color: color, width: lineWidth),
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
