import Foundation
import GrapherKit
import GrapherRender

/// Headless entry points used for verification and for generating images
/// without opening a window:
///
///     GrapherNG --render out.png [--width 1600] [--height 1200] [--zoom 46]
///     GrapherNG --benchmark
///
/// Exits the process when a mode is requested, so the app never reaches the UI.
enum HeadlessRunner {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.contains("--render") || arguments.contains("--benchmark") else { return }

        if arguments.contains("--benchmark") {
            runBenchmark()
        }
        if let path = value(for: "--render", in: arguments) {
            runRender(path: path, arguments: arguments)
        }
        exit(0)
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        let candidate = arguments[index + 1]
        return candidate.hasPrefix("--") ? nil : candidate
    }

    private static func number(_ flag: String, _ arguments: [String], default fallback: Double) -> Double {
        optionalNumber(flag, arguments) ?? fallback
    }

    private static func optionalNumber(_ flag: String, _ arguments: [String]) -> Double? {
        guard let raw = value(for: flag, in: arguments), let parsed = Double(raw) else { return nil }
        return parsed
    }

    // MARK: - Render

    private static func runRender(path: String, arguments: [String]) {
        let quality: SampleQuality = value(for: "--quality", in: arguments) == "full" ? .full : .high

        var document: GrapherDocument
        if let documentPath = value(for: "--doc", in: arguments) {
            do {
                document = try DocumentStore.load(from: URL(fileURLWithPath: documentPath))
            } catch {
                FileHandle.standardError.write(Data("无法读取文档 \(documentPath): \(error)\n".utf8))
                exit(1)
            }
        } else {
            document = arguments.contains("--space") ? .sample3D() : .sample()
        }

        if document.dimension == .space {
            runRender3D(path: path, document: document, quality: quality, arguments: arguments)
            return
        }

        // Flags override the document's own canvas, so rendering the same
        // document at several sizes is a one-line change.
        let width = optionalNumber("--width", arguments) ?? document.viewport.widthPixels
        let height = optionalNumber("--height", arguments) ?? document.viewport.heightPixels
        let zoom = optionalNumber("--zoom", arguments) ?? document.viewport.scale

        document.viewport.widthPixels = width
        document.viewport.heightPixels = height
        document.viewport.scale = zoom

        let compiler = LayerCompiler()
        let compiled = compiler.compile(document)
        for layer in compiled {
            if let error = layer.primaryError {
                FileHandle.standardError.write(Data("公式错误 [\(layer.layer.name)]: \(error.description)\n".utf8))
            }
        }

        let request = SceneBuildRequest(
            document: document,
            compiled: compiled,
            viewport: document.viewport,
            quality: quality,
            backingScale: 2
        )

        let started = Date()
        let built = SceneBuilder2D.build(request)
        let elapsed = Date().timeIntervalSince(started)

        var polylineCount = 0
        var pointCount = 0
        var rectCount = 0
        for command in built.scene.commands {
            switch command {
            case .polyline(let primitive):
                polylineCount += 1
                pointCount += primitive.points.count
            case .rects(let batch):
                rectCount += batch.count
            case .markers(let batch):
                pointCount += batch.positions.count
            }
        }

        guard let context = MetalContext.shared,
              let renderer = OffscreenRenderer2D(
                context: context,
                pixelWidth: Int(width),
                pixelHeight: Int(height),
                supersample: 1
              )
        else {
            FileHandle.standardError.write(Data("无法初始化 Metal 渲染器\n".utf8))
            exit(1)
        }

        do {
            try renderer.writePNG(built.scene, to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("写入 PNG 失败: \(error)\n".utf8))
            exit(1)
        }

        print("""
        已渲染 \(path)
          画布      \(Int(width))×\(Int(height)) 像素，\(String(format: "%.2f", zoom)) px/单位
          采样耗时  \(String(format: "%.1f", elapsed * 1000)) ms（\(quality.rawValue)）
          折线      \(polylineCount) 条，\(pointCount) 个点
          填充矩形  \(rectCount) 个
          曲线      \(built.probeCurves.count) 条
        """)
    }

    /// 立体图：`--azimuth` / `--elevation`（弧度）可以换个角度看。
    private static func runRender3D(path: String, document: GrapherDocument, quality: SampleQuality, arguments: [String]) {
        var view = document.view3D
        view.widthPixels = optionalNumber("--width", arguments) ?? 1600
        view.heightPixels = optionalNumber("--height", arguments) ?? 1200
        if let azimuth = optionalNumber("--azimuth", arguments) { view.azimuth = azimuth }
        if let elevation = optionalNumber("--elevation", arguments) { view.elevation = elevation }

        let started = Date()
        let built = SceneBuilder3D.build(SceneBuild3DRequest(
            document: document, compiled: LayerCompiler().compile(document),
            view: view, quality: quality, backingScale: 2))
        let elapsed = Date().timeIntervalSince(started)
        let chrome = Chrome3D.make(view: view, document: document, backingScale: 2)

        guard let context = MetalContext.shared,
              let renderer = OffscreenRenderer3D(context: context, pixelWidth: Int(view.widthPixels), pixelHeight: Int(view.heightPixels))
        else {
            FileHandle.standardError.write(Data("无法初始化 Metal 渲染器\n".utf8))
            exit(1)
        }
        do {
            try renderer.writePNG(content: built.scene, contentView: built.view, chrome: chrome.scene,
                                  view: view, background: document.theme.background, to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("写入 PNG 失败: \(error)\n".utf8))
            exit(1)
        }
        let triangles = built.scene.meshes.reduce(0) { $0 + $1.triangleCount }
        print("""
        已渲染 \(path)（立体图）
          画布      \(Int(view.widthPixels))×\(Int(view.heightPixels)) 像素，坐标盒 ±\(view.halfExtent)
          采样耗时  \(String(format: "%.1f", elapsed * 1000)) ms（\(quality.rawValue)）
          曲面      \(built.scene.meshes.count) 张，\(triangles) 个三角形
          曲线      \(built.scene.polylines.count) 条
        """)
    }

    // MARK: - Benchmark

    private static func runBenchmark() {
        let width = 1600.0
        let height = 1200.0
        let viewport = Viewport2D(centerX: 0, centerY: 0, scale: 46, widthPixels: width, heightPixels: height)

        let cases: [(String, String)] = [
            ("x^2 + y^2 - 1", "圆"),
            ("x^3 + y^3 - 3*x*y", "笛卡尔叶形线"),
            ("sin(3*x)*cos(3*y) - 0.2", "三角函数乘积"),
            ("x*y - sin(x)*sin(y)", "混合"),
        ]

        for (source, label) in cases {
            do {
                let expression = try CompiledExpression(
                    source: source,
                    context: ExpressionContext(variables: ["x", "y"])
                )
                var grid = FieldGrid(viewport: viewport, quality: .full)
                let started = Date()
                FieldEvaluator.fill(&grid, expr: expression)
                let elapsed = Date().timeIntervalSince(started)
                let rate = Double(grid.pointCount) / max(elapsed, 1e-9) / 1e6
                let pad = String(repeating: " ", count: max(0, 16 - label.count))
                print(String(
                    format: "网格 %d×%d  %@%@%7.1f ms  %6.1f M点/秒",
                    grid.cols, grid.rows, label, pad, elapsed * 1000, rate
                ))
            } catch {
                print("编译失败 \(source): \(error)")
            }
        }

        // Contour + region cost on top of the field evaluation.
        do {
            let expression = try CompiledExpression(
                source: "x^2 + y^2 - 1",
                context: ExpressionContext(variables: ["x", "y"])
            )
            var grid = FieldGrid(viewport: viewport, quality: .full)
            FieldEvaluator.fill(&grid, expr: expression)

            var started = Date()
            let contours = MarchingSquares.contours(grid: grid, level: 0)
            print(String(format: "等值线      %6.1f ms  %d 条", Date().timeIntervalSince(started) * 1000, contours.count))

            started = Date()
            let fill = RegionFiller.fill(grid: grid, relation: .lessOrEqual, pixelStep: 1.0)
            print(String(format: "区域填充    %6.1f ms  %d 个矩形", Date().timeIntervalSince(started) * 1000, fill.count))
        } catch {
            print("区域基准失败: \(error)")
        }

        // Interactive quality is what a drag actually pays.
        do {
            let expression = try CompiledExpression(
                source: "sin(3*x)*cos(3*y) - 0.2",
                context: ExpressionContext(variables: ["x", "y"])
            )
            var grid = FieldGrid(viewport: viewport, quality: .interactive)
            let started = Date()
            FieldEvaluator.fill(&grid, expr: expression)
            let elapsed = Date().timeIntervalSince(started)
            print(String(
                format: "流畅档网格 %d×%d  %6.1f ms",
                grid.cols, grid.rows, elapsed * 1000
            ))
        } catch {
            print("流畅档基准失败: \(error)")
        }

        // Explicit curve sampling.
        do {
            let expression = try CompiledExpression(
                source: "sin(x)/x*a",
                context: ExpressionContext(variables: ["x"], parameters: ["a": 1.5])
            )
            let started = Date()
            var total = 0
            for _ in 0..<10 {
                let curve = CurveSampler.sampleExplicit(
                    f: { expression.evaluate([$0]) },
                    xRange: viewport.xRange,
                    viewport: viewport,
                    quality: .full
                )
                total = curve.pointCount
            }
            print(String(
                format: "显函数采样  %6.1f ms/次  %d 个点",
                Date().timeIntervalSince(started) * 100, total
            ))
        } catch {
            print("显函数基准失败: \(error)")
        }

        // 交互画布一次重算的真实开销：示例文档、Retina 一屏、含视口外那一圈。
        // 拖动时画面靠变换即时跟手，这个数决定的是「边上露出来的部分多久补上」。
        var document = GrapherDocument.sample()
        document.viewport.widthPixels = 2400
        document.viewport.heightPixels = 1600
        let compiled = LayerCompiler().compile(document)
        for quality in [SampleQuality.interactive, .full] {
            let request = SceneBuildRequest(
                document: document,
                compiled: compiled,
                viewport: document.viewport,
                quality: quality,
                backingScale: 2,
                overscan: AppState.overscan,
                includesChrome: false
            )
            _ = SceneBuilder2D.build(request)
            let started = Date()
            let rounds = 5
            for _ in 0..<rounds { _ = SceneBuilder2D.build(request) }
            print(String(
                format: "整屏重算（%@，2400×1600 含外扩）%6.1f ms/次",
                quality.displayName, Date().timeIntervalSince(started) * 1000 / Double(rounds)
            ))
        }

        // 立体图示例文档（显式曲面、环面、螺旋线、隐式球面）整个重算一次。
        let space = GrapherDocument.sample3D()
        let spaceCompiled = LayerCompiler().compile(space)
        for quality in [SampleQuality.interactive, .full] {
            let request = SceneBuild3DRequest(
                document: space, compiled: spaceCompiled, view: space.view3D, quality: quality, backingScale: 2
            )
            _ = SceneBuilder3D.build(request)
            let started = Date()
            let rounds = 5
            var triangles = 0
            for _ in 0..<rounds {
                triangles = SceneBuilder3D.build(request).scene.meshes.reduce(0) { $0 + $1.triangleCount }
            }
            print(String(
                format: "立体图重算（%@）%6.1f ms/次  %d 个三角形",
                quality.displayName, Date().timeIntervalSince(started) * 1000 / Double(rounds), triangles
            ))
        }
    }
}
