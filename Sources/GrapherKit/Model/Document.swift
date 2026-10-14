import Foundation

/// How much work the samplers are allowed to do. Interactive gestures drop to a
/// coarser setting so that dragging stays responsive.
public enum SampleQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    /// One sample every few pixels — used while a gesture is in flight.
    case interactive
    /// One sample per pixel.
    case full
    /// Two samples per pixel along each axis; used for stills.
    case high

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .interactive: return L("Smooth (while dragging)")
        case .full: return L("Standard")
        case .high: return L("Fine")
        }
    }

    /// Pixels between adjacent grid samples for the implicit/region solvers.
    public var samplesPerPixel: Double {
        switch self {
        case .interactive: return 0.35
        case .full: return 1.0
        case .high: return 2.0
        }
    }
}

public struct GrapherDocument: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    /// 平面图还是立体图：新建时定下，之后不变。
    public var dimension: DocumentDimension
    public var layers: [Layer]
    public var parameters: [ParameterDefinition]
    public var viewport: Viewport2D
    /// 立体图的视角与坐标盒；平面图不用它。
    public var view3D: View3D
    public var theme: Theme
    public var showGrid: Bool
    public var showMinorGrid: Bool
    public var showAxes: Bool
    public var showTickLabels: Bool

    public init(
        formatVersion: Int = GrapherDocument.currentFormatVersion,
        dimension: DocumentDimension = .plane,
        layers: [Layer] = [],
        parameters: [ParameterDefinition] = [],
        viewport: Viewport2D = Viewport2D(),
        view3D: View3D = .standard,
        theme: Theme = .light,
        showGrid: Bool = true,
        showMinorGrid: Bool = false,
        showAxes: Bool = true,
        showTickLabels: Bool = true
    ) {
        self.formatVersion = formatVersion
        self.dimension = dimension
        self.layers = layers
        self.parameters = parameters
        self.viewport = viewport
        self.view3D = view3D
        self.theme = theme
        self.showGrid = showGrid
        self.showMinorGrid = showMinorGrid
        self.showAxes = showAxes
        self.showTickLabels = showTickLabels
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, dimension, layers, parameters, viewport, view3D
        case theme, showGrid, showMinorGrid, showAxes, showTickLabels
    }

    /// 2D 时代的文件没有 `dimension` 与 `view3D`：读成平面图、默认视角。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        dimension = try container.decodeIfPresent(DocumentDimension.self, forKey: .dimension) ?? .plane
        layers = try container.decode([Layer].self, forKey: .layers)
        parameters = try container.decode([ParameterDefinition].self, forKey: .parameters)
        viewport = try container.decode(Viewport2D.self, forKey: .viewport)
        view3D = try container.decodeIfPresent(View3D.self, forKey: .view3D) ?? .standard
        theme = try container.decode(Theme.self, forKey: .theme)
        showGrid = try container.decode(Bool.self, forKey: .showGrid)
        showMinorGrid = try container.decode(Bool.self, forKey: .showMinorGrid)
        showAxes = try container.decode(Bool.self, forKey: .showAxes)
        showTickLabels = try container.decode(Bool.self, forKey: .showTickLabels)
    }

    public var parameterValues: [String: Double] {
        var result: [String: Double] = [:]
        for parameter in parameters where parameter.isNameValid {
            result[parameter.name] = parameter.value
        }
        return result
    }

    public var visibleLayers: [Layer] {
        layers.filter(\.isVisible)
    }

    /// A document that shows off each plot kind, used by Load Example and the
    /// headless renderer.
    public static func sample() -> GrapherDocument {
        var document = GrapherDocument()
        document.parameters = [
            ParameterDefinition(name: "a", value: 1.6, lowerBound: 0, upperBound: 4)
        ]

        var sine = Layer.makeDefault(kind: .explicit, index: 0)
        sine.name = "y = a·sin(x)/x"
        sine.formula = "a*sin(x)/x"
        sine.usesExplicitDomain = true
        sine.domainLower = -12
        sine.domainUpper = 12

        var heart = Layer.makeDefault(kind: .parametric, index: 1)
        heart.name = L("Cardioid")
        heart.usesExplicitDomain = true
        heart.domainLower = 0
        heart.domainUpper = 2 * Double.pi

        var rose = Layer.makeDefault(kind: .polar, index: 2)
        rose.name = L("Rose r = cos(3θ)")
        rose.formula = "cos(3*theta)"
        rose.usesExplicitDomain = true
        rose.domainLower = 0
        rose.domainUpper = 2 * Double.pi

        let leaf = Layer(
            kind: .implicit,
            name: L("Folium of Descartes"),
            formula: "x^3 + y^3 - 3*x*y",
            lineStyle: LineStyle(color: RGBAColor.paletteColor(3), width: 1.8)
        )

        document.layers = [sine, heart, rose, leaf]
        document.viewport.centerX = 0
        document.viewport.centerY = 0
        // Wide enough that the heart curve is not cut off on first launch.
        document.viewport.scale = 28
        return document
    }

    /// 立体图的示例（「加载示例」与无界面渲染用）：四种 3D 图型各一个，错开摆在默认坐标盒（±4）里。
    public static func sample3D() -> GrapherDocument {
        var document = GrapherDocument(dimension: .space)
        document.parameters = [
            ParameterDefinition(name: "a", value: 1.5, lowerBound: 0, upperBound: 3)
        ]

        var surface = Layer.makeDefault(kind: .surface, index: 0)
        surface.name = "z = a·sin(x)·cos(y)"
        surface.formula = "a*sin(x)*cos(y)"

        var torus = Layer.makeDefault(kind: .parametricSurface, index: 1)
        torus.name = L("Torus")
        torus.formula = "(2.4 + 0.7*cos(v))*cos(u)"
        torus.secondaryFormula = "(2.4 + 0.7*cos(v))*sin(u)"
        torus.tertiaryFormula = "2.6 + 0.7*sin(v)"
        torus.usesExplicitDomain = true

        var helix = Layer.makeDefault(kind: .spaceCurve, index: 2)
        helix.name = L("Helix")
        helix.formula = "3.3*cos(t)"
        helix.secondaryFormula = "3.3*sin(t)"
        helix.tertiaryFormula = "t/4"
        helix.domainLower = -4 * Double.pi
        helix.domainUpper = 4 * Double.pi
        helix.usesExplicitDomain = true

        var sphere = Layer.makeDefault(kind: .implicitSurface, index: 3)
        sphere.name = L("Sphere")
        sphere.formula = "x^2 + y^2 + (z + 2.6)^2 - 1.2"

        document.layers = [surface, torus, helix, sphere]
        return document
    }
}

public enum DocumentStore {
    public static func encode(_ document: GrapherDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> GrapherDocument {
        try JSONDecoder().decode(GrapherDocument.self, from: data)
    }

    public static func load(from url: URL) throws -> GrapherDocument {
        try decode(try Data(contentsOf: url))
    }

    public static func save(_ document: GrapherDocument, to url: URL) throws {
        try encode(document).write(to: url, options: .atomic)
    }
}
