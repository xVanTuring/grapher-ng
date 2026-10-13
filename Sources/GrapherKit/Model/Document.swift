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
    public var layers: [Layer]
    public var parameters: [ParameterDefinition]
    public var viewport: Viewport2D
    public var theme: Theme
    public var showGrid: Bool
    public var showMinorGrid: Bool
    public var showAxes: Bool
    public var showTickLabels: Bool

    public init(
        formatVersion: Int = GrapherDocument.currentFormatVersion,
        layers: [Layer] = [],
        parameters: [ParameterDefinition] = [],
        viewport: Viewport2D = Viewport2D(),
        theme: Theme = .light,
        showGrid: Bool = true,
        showMinorGrid: Bool = false,
        showAxes: Bool = true,
        showTickLabels: Bool = true
    ) {
        self.formatVersion = formatVersion
        self.layers = layers
        self.parameters = parameters
        self.viewport = viewport
        self.theme = theme
        self.showGrid = showGrid
        self.showMinorGrid = showMinorGrid
        self.showAxes = showAxes
        self.showTickLabels = showTickLabels
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

    /// A document that shows off each plot kind, used on first launch.
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
