import Foundation
import simd

/// Compiles a document's formulas and remembers the results, keyed by the
/// inputs that actually affect compilation. Changing a parameter changes the
/// compiled constants, so it is part of the key.
public final class LayerCompiler {
    public struct CompiledLayer {
        public var layer: Layer
        public var primary: CompiledExpression?
        public var secondary: CompiledExpression?
        public var tertiary: CompiledExpression?
        public var primaryError: ExpressionError?
        public var secondaryError: ExpressionError?
        public var tertiaryError: ExpressionError?

        public var hasError: Bool { primaryError != nil || secondaryError != nil || tertiaryError != nil }

        /// 三个公式里第一个出错的那个，界面上的错误标记用它。
        public var firstError: ExpressionError? { primaryError ?? secondaryError ?? tertiaryError }
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
            guard layer.kind.needsFormula else {
                result.append(compiled)
                continue
            }
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

            if layer.kind.needsTertiaryFormula {
                let tertiaryOutcome = compileOne(
                    source: layer.tertiaryFormula,
                    variables: layer.kind.tertiaryVariables,
                    parameters: parameters
                )
                compiled.tertiary = tertiaryOutcome.0
                compiled.tertiaryError = tertiaryOutcome.1
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
            entry = (nil, ExpressionError(
                message: String(format: L("Could not parse the expression: %@"), String(describing: error)),
                column: 0,
                length: 1
            ))
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
    /// 视口四周各外扩多少个视口宽 / 高一起采样（见 `Viewport2D.expanded`）。交互画布给一圈，
    /// 拖动时露出来的边上已经有图；导出与离屏渲染保持 0，几何正好铺满画布。
    public var overscan: Double
    /// 是否把网格与坐标轴也画进场景。交互画布不要：那两样每一帧都按当前视口现画
    /// （`SceneBuilder2D.chromeScene`），不能等后台。导出、离屏渲染要。
    public var includesChrome: Bool

    public init(
        document: GrapherDocument,
        compiled: [LayerCompiler.CompiledLayer],
        viewport: Viewport2D,
        quality: SampleQuality,
        backingScale: Double,
        overscan: Double = 0,
        includesChrome: Bool = true
    ) {
        self.document = document
        self.compiled = compiled
        self.viewport = viewport
        self.quality = quality
        self.backingScale = backingScale
        self.overscan = overscan
        self.includesChrome = includesChrome
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
    /// `scene` 的几何所在的像素空间：请求视口外扩 `overscan` 之后的那个视口。
    /// 画到别的视口上时用 `Viewport2D.screenTransform(from:)` 换算。
    public var viewport: Viewport2D
    /// 按请求视口（不含外扩）排的刻度。
    public var chrome: ChromeLayout
    public var probeCurves: [ProbeCurve]
    /// 软边界用的内容包围盒。有界图层（限定了定义域的显函数、参数方程、极坐标）按整条曲线算；
    /// 无界图层（不限定义域的显函数、隐函数、区域）只采了视口附近那一片，只认落在采样窗口里的
    /// 部分（极点附近飞到 1e15 的点不算）。
    /// 在建场景时算一次，别放在拖动路径上现算（那条路径每帧都会走）。
    public var contentBounds: DataBounds?
    /// 「适应内容」用：有界图层整条，无界图层只取**可见区**里的部分。不能直接用
    /// `contentBounds`——那里含外扩的一圈，按它适配，每按一次 F 都会再缩小一圈。
    public var fitBounds: DataBounds?
}

public enum SceneBuilder2D {
    /// Guards against a pole flinging a point to infinity and turning float
    /// conversion into garbage.
    static let coordinateLimit = 1.0e7

    public static func build(_ request: SceneBuildRequest) -> BuiltScene {
        let theme = request.document.theme
        var scene = Scene2D(background: theme.background, commands: [])
        var probeCurves: [ProbeCurve] = []
        // 采样与几何都在外扩后的视口里做；刻度读数仍按可见视口排。
        let visible = request.viewport
        let viewport = visible.expanded(by: request.overscan)

        if request.includesChrome {
            appendChrome(&scene, document: request.document, chrome: ChromeLayout.make(viewport: viewport),
                         viewport: viewport, backingScale: request.backingScale)
        }

        let window = viewport.dataBounds
        let visibleWindow = visible.dataBounds
        var contentBounds: DataBounds?
        var fitBounds: DataBounds?
        for compiled in request.compiled where compiled.layer.isVisible {
            let before = probeCurves.count
            append(layer: compiled, request: request, viewport: viewport, into: &scene, probeCurves: &probeCurves)
            guard probeCurves.count > before,
                  let extent = DataBounds.enclosing(probeCurves[before].segments)
            else { continue }
            if isBounded(compiled.layer) {
                contentBounds = extent.union(contentBounds)
                fitBounds = extent.union(fitBounds)
            } else {
                contentBounds = extent.intersection(window)?.union(contentBounds) ?? contentBounds
                fitBounds = extent.intersection(visibleWindow)?.union(fitBounds) ?? fitBounds
            }
        }

        return BuiltScene(
            scene: scene,
            viewport: viewport,
            chrome: ChromeLayout.make(viewport: visible),
            probeCurves: probeCurves,
            contentBounds: contentBounds,
            fitBounds: fitBounds
        )
    }

    /// 曲线是否整条都采到了：限定定义域的显函数、参数方程、极坐标按整个定义域采样，与视口无关；
    /// 其余的只采视口附近，曲线本身可能一直延伸到无穷远。
    static func isBounded(_ layer: Layer) -> Bool {
        switch layer.kind {
        case .explicit: return layer.usesExplicitDomain
        case .parametric, .polar: return true
        case .implicit, .region: return false
        case .surface, .parametricSurface, .spaceCurve, .implicitSurface, .surfaceIntersection, .point, .projection,
             .tangent, .tangentPlane, .text:
            return false
        case .scatter: return true
        }
    }

    // MARK: - Chrome

    /// 只有网格与坐标轴的场景，几何是 `viewport` 的屏幕像素。交互画布每次视口变化都按当前
    /// 视口现画这一层（几十条线，微秒级），所以拖动时网格与刻度读数始终对齐、不等后台。
    public static func chromeScene(
        document: GrapherDocument,
        viewport: Viewport2D,
        backingScale: Double
    ) -> (scene: Scene2D, layout: ChromeLayout) {
        let chrome = ChromeLayout.make(viewport: viewport)
        var scene = Scene2D(background: document.theme.background, commands: [])
        appendChrome(&scene, document: document, chrome: chrome, viewport: viewport, backingScale: backingScale)
        return (scene, chrome)
    }

    private static func appendChrome(
        _ scene: inout Scene2D,
        document: GrapherDocument,
        chrome: ChromeLayout,
        viewport: Viewport2D,
        backingScale: Double
    ) {
        if document.showGrid {
            appendGrid(&scene, chrome: chrome, viewport: viewport, theme: document.theme,
                       showMinor: document.showMinorGrid, backingScale: backingScale)
        }
        if document.showAxes {
            appendAxes(&scene, chrome: chrome, viewport: viewport, theme: document.theme,
                       backingScale: backingScale)
        }
    }

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
        viewport: Viewport2D,
        into scene: inout Scene2D,
        probeCurves: inout [ProbeCurve]
    ) {
        let layer = compiled.layer
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
            if layer.usesExplicitDomain {
                appendDomainEnds(f: f, range: range, color: layer.lineStyle.color,
                                 strokeWidth: strokeWidth, backingScale: request.backingScale,
                                 viewport: viewport, into: &scene)
            }

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

        case .tangent:
            guard let id = layer.sourceA,
                  let source = request.compiled.first(where: { $0.layer.id == id }),
                  let tangent = Tangents.tangent(of: source, at: layer.anchorU) else { return }
            let direction = layer.drawsNormal ? tangent.normal : tangent.direction
            // 直线两头各伸出一个视口对角线那么长（再加上切点离视口中心的距离），保证铺满画面。
            let window = viewport.dataBounds
            let diagonal = hypot(window.maxX - window.minX, window.maxY - window.minY)
            let centre = SIMD2((window.minX + window.maxX) / 2, (window.minY + window.maxY) / 2)
            let reach = diagonal + simd_length(tangent.point - centre)
            collected = [[tangent.point - direction * reach, tangent.point + direction * reach]]
            appendCurve(collected, color: layer.lineStyle.color, width: strokeWidth, viewport: viewport, into: &scene)
            scene.append(.markers(MarkerPrimitiveBatch(
                positions: [viewport.toScreen(x: tangent.point.x, y: tangent.point.y)],
                radius: strokeWidth * 1.6 + 2, color: layer.lineStyle.color)))

        case .scatter:
            let points = ScatterData.parse(layer.formula)
            guard !points.isEmpty else { return }
            // 每个点是零长度的一段：让悬停读数、适应内容、CSV 导出都认得这些点。
            collected = points.map { [$0, $0] }
            if layer.showsFit, let fit = ScatterData.fit(points) {
                // 拟合直线铺满视口的 x 范围，画成细一点的虚线风格（实线、半透明）。
                let range = viewport.xRange
                let a = SIMD2(range.lowerBound, fit.slope * range.lowerBound + fit.intercept)
                let b = SIMD2(range.upperBound, fit.slope * range.upperBound + fit.intercept)
                appendCurve([[a, b]], color: layer.lineStyle.color.withAlpha(0.7),
                            width: max(strokeWidth * 0.7, 1), viewport: viewport, into: &scene)
            }
            scene.append(.markers(MarkerPrimitiveBatch(
                positions: points.map { viewport.toScreen(x: $0.x, y: $0.y) },
                radius: strokeWidth * 1.3 + 1.5, color: layer.lineStyle.color)))

        case .text:
            // 文字由画布叠加层与导出的图片写（`TextAnnotations`），不进 Metal 场景。
            return

        case .surface, .parametricSurface, .spaceCurve, .implicitSurface, .surfaceIntersection, .point, .projection,
             .tangentPlane:
            // 立体图型只在 3D 画布上画（`SceneBuilder3D`）。
            return
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

    /// 限定了定义域的显函数：两端各画一个实心点（闭区间），一眼看出曲线是在这里截止，
    /// 不是没画完。函数在端点处没有定义（非有限值）的那一端就不画。
    private static func appendDomainEnds(
        f: (Double) -> Double,
        range: ClosedRange<Double>,
        color: RGBAColor,
        strokeWidth: Double,
        backingScale: Double,
        viewport: Viewport2D,
        into scene: inout Scene2D
    ) {
        var ends: [SIMD2<Double>] = []
        for x in [range.lowerBound, range.upperBound] {
            let y = f(x)
            guard x.isFinite, y.isFinite else { continue }
            ends.append(screenClamped(SIMD2(x, y), viewport: viewport))
        }
        if range.lowerBound == range.upperBound, ends.count == 2 { ends.removeLast() }
        guard !ends.isEmpty else { return }
        let radius = max(strokeWidth * 1.4, 3 * backingScale)
        scene.append(.markers(MarkerPrimitiveBatch(positions: ends, radius: radius, color: color)))
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
