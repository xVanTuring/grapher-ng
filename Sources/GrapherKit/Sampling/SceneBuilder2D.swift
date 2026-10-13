import Foundation

/// Compiles a document's formulas and remembers the results, keyed by the
/// inputs that actually affect compilation. Changing a parameter changes the
/// compiled constants, so it is part of the key.
public final class LayerCompiler {
    public struct CompiledLayer {
        public var layer: Layer
        public var primary: CompiledExpression?
        public var secondary: CompiledExpression?
        public var primaryError: ExpressionError?
        public var secondaryError: ExpressionError?

        public var hasError: Bool { primaryError != nil || secondaryError != nil }
    }

    private struct Key: Hashable {
        var formula: String
        var variables: [String]
        var parameters: [String: Double]
    }

    private var cache: [Key: (expression: CompiledExpression?, error: ExpressionError?)] = [:]

    public init() {}

    public func compile(_ document: GrapherDocument) -> [CompiledLayer] {
        let parameters = document.parameterValues
        var result: [CompiledLayer] = []
        result.reserveCapacity(document.layers.count)

        for layer in document.layers {
            var compiled = CompiledLayer(layer: layer)
            let primaryOutcome = compileOne(
                source: layer.formula,
                variables: layer.kind.primaryVariables,
                parameters: parameters
            )
            compiled.primary = primaryOutcome.0
            compiled.primaryError = primaryOutcome.1

            if layer.kind.needsSecondaryFormula {
                let secondaryOutcome = compileOne(
                    source: layer.secondaryFormula,
                    variables: layer.kind.secondaryVariables,
                    parameters: parameters
                )
                compiled.secondary = secondaryOutcome.0
                compiled.secondaryError = secondaryOutcome.1
            }
            result.append(compiled)
        }
        return result
    }

    private func compileOne(
        source: String,
        variables: [String],
        parameters: [String: Double]
    ) -> (CompiledExpression?, ExpressionError?) {
        let key = Key(formula: source, variables: variables, parameters: parameters)
        if let cached = cache[key] { return (cached.expression, cached.error) }

        let entry: (expression: CompiledExpression?, error: ExpressionError?)
        let context = ExpressionContext(variables: variables, parameters: parameters)
        do {
            entry = (try CompiledExpression(source: source, context: context), nil)
        } catch let error as ExpressionError {
            entry = (nil, error)
        } catch {
            entry = (nil, ExpressionError(message: "表达式无法解析：\(error)", column: 0, length: 1))
        }
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[key] = entry
        return (entry.expression, entry.error)
    }
}

/// Everything the 2D scene builder needs for one frame.
public struct SceneBuildRequest {
    public var document: GrapherDocument
    public var compiled: [LayerCompiler.CompiledLayer]
    public var viewport: Viewport2D
    public var quality: SampleQuality
    /// Backing pixels per point; converts point-denominated widths.
    public var backingScale: Double

    public init(
        document: GrapherDocument,
        compiled: [LayerCompiler.CompiledLayer],
        viewport: Viewport2D,
        quality: SampleQuality,
        backingScale: Double
    ) {
        self.document = document
        self.compiled = compiled
        self.viewport = viewport
        self.quality = quality
        self.backingScale = backingScale
    }
}

/// Tick positions and axis placement, shared by the Metal renderer (which draws
/// the lines) and the Core Graphics overlay (which draws the numbers).
public struct ChromeLayout: Sendable {
    public var xTicks: AxisTicks.Ticks
    public var yTicks: AxisTicks.Ticks
    public var originPixel: SIMD2<Double>
    public var showsVerticalAxis: Bool
    public var showsHorizontalAxis: Bool

    public static func make(viewport: Viewport2D) -> ChromeLayout {
        let xTicks = AxisTicks.ticks(range: viewport.xRange, pixelsPerUnit: viewport.scale)
        let yTicks = AxisTicks.ticks(range: viewport.yRange, pixelsPerUnit: viewport.scale)
        let origin = viewport.toScreen(x: 0, y: 0)
        return ChromeLayout(
            xTicks: xTicks,
            yTicks: yTicks,
            originPixel: origin,
            showsVerticalAxis: (0...viewport.widthPixels).contains(origin.x),
            showsHorizontalAxis: (0...viewport.heightPixels).contains(origin.y)
        )
    }
}

/// A curve kept in data space so the UI can find the point nearest the cursor.
public struct ProbeCurve: Sendable {
    public var layerID: UUID
    public var layerName: String
    public var color: RGBAColor
    public var kind: PlotKind
    public var segments: [[SIMD2<Double>]]
}

/// Everything one rebuild produces: what to draw, where the ticks landed, and
/// the geometry the probe uses for its read-out.
public struct BuiltScene {
    public var scene: Scene2D
    public var chrome: ChromeLayout
    public var probeCurves: [ProbeCurve]
    /// 所有可见曲线采样点的数据包围盒。软边界与「适应内容」共用它，所以在建场景时算一次，
    /// 别放在拖动路径上现算（那条路径每帧都会走）。
    public var contentBounds: DataBounds?
}

public enum SceneBuilder2D {
    /// Guards against a pole flinging a point to infinity and turning float
    /// conversion into garbage.
    static let coordinateLimit = 1.0e7

    public static func build(_ request: SceneBuildRequest) -> BuiltScene {
        let theme = request.document.theme
        var scene = Scene2D(background: theme.background, commands: [])
        var probeCurves: [ProbeCurve] = []
        let viewport = request.viewport

        let chrome = ChromeLayout.make(viewport: viewport)
        if request.document.showGrid {
            appendGrid(&scene, chrome: chrome, viewport: viewport, theme: theme,
                       showMinor: request.document.showMinorGrid,
                       backingScale: request.backingScale)
        }
        if request.document.showAxes {
            appendAxes(&scene, chrome: chrome, viewport: viewport, theme: theme,
                       backingScale: request.backingScale)
        }

        for compiled in request.compiled where compiled.layer.isVisible {
            append(layer: compiled, request: request, into: &scene, probeCurves: &probeCurves)
        }

        let contentBounds = DataBounds.enclosing(probeCurves.flatMap(\.segments))
        return BuiltScene(
            scene: scene,
            chrome: chrome,
            probeCurves: probeCurves,
            contentBounds: contentBounds
        )
    }

    // MARK: - Chrome

    private static func appendGrid(
        _ scene: inout Scene2D,
        chrome: ChromeLayout,
        viewport: Viewport2D,
        theme: Theme,
        showMinor: Bool,
        backingScale: Double
    ) {
        let width = max(0.6 * backingScale, 0.5)
        if showMinor {
            appendTickLines(&scene, ticks: chrome.xTicks.minor, vertical: true,
                            viewport: viewport, color: theme.minorGrid, width: width * 0.75)
            appendTickLines(&scene, ticks: chrome.yTicks.minor, vertical: false,
                            viewport: viewport, color: theme.minorGrid, width: width * 0.75)
        }
        appendTickLines(&scene, ticks: chrome.xTicks.major, vertical: true,
                        viewport: viewport, color: theme.grid, width: width)
        appendTickLines(&scene, ticks: chrome.yTicks.major, vertical: false,
                        viewport: viewport, color: theme.grid, width: width)
    }

    private static func appendTickLines(
        _ scene: inout Scene2D,
        ticks: [Double],
        vertical: Bool,
        viewport: Viewport2D,
        color: RGBAColor,
        width: Double
    ) {
        guard !ticks.isEmpty else { return }
        for tick in ticks {
            let points: [SIMD2<Double>]
            if vertical {
                let x = viewport.dataToScreenX(tick)
                guard x >= -1, x <= viewport.widthPixels + 1 else { continue }
                points = [SIMD2(x, 0), SIMD2(x, viewport.heightPixels)]
            } else {
                let y = viewport.dataToScreenY(tick)
                guard y >= -1, y <= viewport.heightPixels + 1 else { continue }
                points = [SIMD2(0, y), SIMD2(viewport.widthPixels, y)]
            }
            scene.append(.polyline(PolylinePrimitive(points: points, color: color, width: width)))
        }
    }

    private static func appendAxes(
        _ scene: inout Scene2D,
        chrome: ChromeLayout,
        viewport: Viewport2D,
        theme: Theme,
        backingScale: Double
    ) {
        let width = max(1.1 * backingScale, 1.0)
        if chrome.showsHorizontalAxis {
            let y = chrome.originPixel.y
            scene.append(.polyline(PolylinePrimitive(
                points: [SIMD2(0, y), SIMD2(viewport.widthPixels, y)],
                color: theme.axes,
                width: width
            )))
        }
        if chrome.showsVerticalAxis {
            let x = chrome.originPixel.x
            scene.append(.polyline(PolylinePrimitive(
                points: [SIMD2(x, 0), SIMD2(x, viewport.heightPixels)],
                color: theme.axes,
                width: width
            )))
        }
    }

    // MARK: - Layers

    private static func append(
        layer compiled: LayerCompiler.CompiledLayer,
        request: SceneBuildRequest,
        into scene: inout Scene2D,
        probeCurves: inout [ProbeCurve]
    ) {
        let layer = compiled.layer
        let viewport = request.viewport
        let strokeWidth = max(layer.lineStyle.width * request.backingScale, 0.5)
        var collected: [[SIMD2<Double>]] = []

        switch layer.kind {
        case .explicit:
            guard let expression = compiled.primary else { return }
            let kind = layer.kind
            let f: (Double) -> Double = { expression.evaluate(kind.primaryValues(argument: $0)) }
            let range = layer.usesExplicitDomain
                ? min(layer.domainLower, layer.domainUpper)...max(layer.domainLower, layer.domainUpper)
                : viewport.xRange
            let curve = CurveSampler.sampleExplicit(
                f: f, xRange: range, viewport: viewport, quality: request.quality
            )
            collected = curve.segments
            appendCurve(curve.segments, color: layer.lineStyle.color, width: strokeWidth,
                        viewport: viewport, into: &scene)

        case .parametric:
            guard let primary = compiled.primary, let secondary = compiled.secondary else { return }
            let primarySlots = layer.kind.primaryVariables.count
            let secondarySlots = layer.kind.secondaryVariables.count
            let f: (Double) -> SIMD2<Double> = { argument in
                SIMD2(
                    primary.evaluate([Double](repeating: argument, count: primarySlots)),
                    secondary.evaluate([Double](repeating: argument, count: secondarySlots))
                )
            }
            let range = min(layer.domainLower, layer.domainUpper)...max(layer.domainLower, layer.domainUpper)
            let curve = CurveSampler.sampleParametric(
                tRange: range, f: f, viewport: viewport, quality: request.quality
            )
            collected = curve.segments
            appendCurve(curve.segments, color: layer.lineStyle.color, width: strokeWidth,
                        viewport: viewport, into: &scene)

        case .polar:
            guard let expression = compiled.primary else { return }
            let kind = layer.kind
            let r: (Double) -> Double = { expression.evaluate(kind.primaryValues(argument: $0)) }
            let range = min(layer.domainLower, layer.domainUpper)...max(layer.domainLower, layer.domainUpper)
            let curve = CurveSampler.samplePolar(
                r: r, thetaRange: range, viewport: viewport, quality: request.quality
            )
            collected = curve.segments
            appendCurve(curve.segments, color: layer.lineStyle.color, width: strokeWidth,
                        viewport: viewport, into: &scene)

        case .implicit:
            guard let expression = compiled.primary else { return }
            var grid = FieldGrid(viewport: viewport, quality: request.quality)
            FieldEvaluator.fill(&grid, expr: expression)
            collected = MarchingSquares.contours(grid: grid, level: 0)
            appendCurve(collected, color: layer.lineStyle.color, width: strokeWidth,
                        viewport: viewport, into: &scene)
            for level in layer.extraLevels where level != 0 {
                let extra = MarchingSquares.contours(grid: grid, level: level)
                appendCurve(extra, color: layer.lineStyle.color.withAlpha(0.65),
                            width: strokeWidth * 0.8, viewport: viewport, into: &scene)
            }

        case .region:
            guard let expression = compiled.primary else { return }
            var grid = FieldGrid(viewport: viewport, quality: request.quality)
            FieldEvaluator.fill(&grid, expr: expression)
            if layer.fillStyle.isFilled {
                let fill = RegionFiller.fill(
                    grid: grid,
                    relation: layer.relation,
                    pixelStep: 1.0 / request.quality.samplesPerPixel
                )
                if !fill.geometry.isEmpty {
                    var color = layer.fillStyle.color
                    color.a *= layer.fillStyle.opacity
                    scene.append(.rects(RectPrimitiveBatch(
                        geometry: fill.geometry, coverage: fill.coverage, color: color
                    )))
                }
            }
            if layer.lineStyle.width > 0 {
                collected = MarchingSquares.contours(grid: grid, level: 0)
                appendCurve(collected, color: layer.lineStyle.color, width: strokeWidth,
                            viewport: viewport, into: &scene)
            }
        }

        if !collected.isEmpty {
            probeCurves.append(ProbeCurve(
                layerID: layer.id,
                layerName: layer.name,
                color: layer.lineStyle.color,
                kind: layer.kind,
                segments: collected
            ))
        }
    }

    private static func appendCurve(
        _ segments: [[SIMD2<Double>]],
        color: RGBAColor,
        width: Double,
        viewport: Viewport2D,
        into scene: inout Scene2D
    ) {
        for segment in segments where segment.count >= 2 {
            let points = segment.map { screenClamped($0, viewport: viewport) }
            scene.append(.polyline(PolylinePrimitive(points: points, color: color, width: width)))
        }
    }

    static func screenClamped(_ point: SIMD2<Double>, viewport: Viewport2D) -> SIMD2<Double> {
        let screen = viewport.toScreen(x: point.x, y: point.y)
        let limit = coordinateLimit
        return SIMD2(
            min(max(screen.x, -limit), limit),
            min(max(screen.y, -limit), limit)
        )
    }
}
