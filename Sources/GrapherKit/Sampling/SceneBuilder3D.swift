import Foundation
import simd

/// 一次 3D 重算所需的全部输入。
public struct SceneBuild3DRequest {
    public var document: GrapherDocument
    public var compiled: [LayerCompiler.CompiledLayer]
    /// 采样用的坐标盒（只看盒子，不看相机朝向：旋转不需要重采）。
    public var view: View3D
    public var quality: SampleQuality
    /// 后备像素 / 点，换算线宽。
    public var backingScale: Double

    public init(
        document: GrapherDocument,
        compiled: [LayerCompiler.CompiledLayer],
        view: View3D,
        quality: SampleQuality,
        backingScale: Double
    ) {
        self.document = document
        self.compiled = compiled
        self.view = view
        self.quality = quality
        self.backingScale = backingScale
    }
}

/// 一次 3D 重算的产物。
public struct BuiltScene3D {
    public var scene: Scene3D
    /// 几何归一化所依据的坐标盒。画到别的盒子上时用 `View3D.boxTransform(from:)` 换算。
    public var view: View3D
    /// 「适应内容」用：有界图层（参数曲面、空间曲线）整个，其余只算盒内部分。
    public var fitBounds: DataBox3D?
}

public enum SceneBuilder3D {

    /// 显式曲面、参数曲面每个方向的格点数。
    static func surfaceResolution(_ quality: SampleQuality) -> Int {
        switch quality {
        case .interactive: return 72
        case .full: return 180
        case .high: return 320
        }
    }

    /// 隐式曲面每一轴的格数。
    static func volumeResolution(_ quality: SampleQuality) -> Int {
        switch quality {
        case .interactive: return 40
        case .full: return 96
        case .high: return 144
        }
    }

    /// 参数曲面每个参数方向画多少条网格线。
    static let parameterLines: Float = 16

    public static func build(_ request: SceneBuild3DRequest) -> BuiltScene3D {
        var scene = Scene3D()
        var fit: DataBox3D?
        let view = request.view
        let box = DataBox3D(min: view.center - view.halfExtent, max: view.center + view.halfExtent)

        // 交线要用到来源曲面的网格：画过的存下来，没画的（来源图层藏起来了）用到时再采。
        var surfaceMeshes: [UUID: Mesh3D] = [:]

        for compiled in request.compiled where compiled.layer.isVisible {
            let layer = compiled.layer
            let (meshFrom, lineFrom) = (scene.meshes.count, scene.polylines.count)
            defer { tag(&scene, layer: layer, meshFrom: meshFrom, lineFrom: lineFrom) }
            switch layer.kind {
            case .surface:
                guard let f = compiled.primary else { continue }
                let (mesh, extent) = explicitSurface(f, layer: layer, request: request)
                if mesh.triangleCount > 0 { scene.meshes.append(mesh) }
                surfaceMeshes[layer.id] = mesh
                fit = extent.flatMap { $0.intersection(box) }?.union(fit) ?? fit

            case .parametricSurface:
                guard let fx = compiled.primary, let fy = compiled.secondary, let fz = compiled.tertiary else { continue }
                let (mesh, extent) = parametricSurface(fx, fy, fz, layer: layer, request: request)
                if mesh.triangleCount > 0 { scene.meshes.append(mesh) }
                surfaceMeshes[layer.id] = mesh
                fit = extent?.union(fit) ?? fit

            case .spaceCurve:
                guard let fx = compiled.primary, let fy = compiled.secondary, let fz = compiled.tertiary else { continue }
                let (lines, extent) = spaceCurve(fx, fy, fz, layer: layer, request: request)
                scene.polylines.append(contentsOf: lines)
                fit = extent?.union(fit) ?? fit

            case .implicitSurface:
                guard let f = compiled.primary else { continue }
                let mesh = implicitSurface(f, layer: layer, request: request)
                surfaceMeshes[layer.id] = mesh
                if mesh.triangleCount > 0 {
                    scene.meshes.append(mesh)
                    let points = mesh.vertices.lazy.map { view.data(SIMD3<Double>($0.position)) }
                    fit = DataBox3D.enclosing(points)?.union(fit) ?? fit
                }

            case .explicit, .parametric, .polar, .implicit:
                // 平面曲线放进立体图：画在 z = 0 上，或沿 z 延伸成贯穿坐标盒的竖直曲面。
                let runs = planeCurve(compiled, request: request)
                guard !runs.isEmpty else { continue }
                let flat = DataBox3D.enclosing(runs.joined().map { SIMD3($0.x, $0.y, 0) })
                if layer.extrudesInSpace {
                    let mesh = extrude(runs, color: layer.lineStyle.color, view: view)
                    if mesh.triangleCount > 0 { scene.meshes.append(mesh) }
                    let tall = flat.map { DataBox3D(min: SIMD3($0.min.x, $0.min.y, box.min.z),
                                                    max: SIMD3($0.max.x, $0.max.y, box.max.z)) }
                    fit = tall.flatMap { $0.intersection(box) }?.union(fit) ?? fit
                } else {
                    scene.polylines.append(contentsOf: lift(runs, layer: layer, request: request))
                    fit = flat.flatMap { $0.intersection(box) }?.union(fit) ?? fit
                }

            case .point:
                guard let fx = compiled.primary, let fy = compiled.secondary, let fz = compiled.tertiary else { continue }
                let p = SIMD3(fx.evaluate([]), fy.evaluate([]), fz.evaluate([]))
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
                scene.meshes.append(PointMarker.mesh(
                    center: SIMD3<Float>(view.normalized(p)),
                    radius: PointMarker.radius(width: layer.lineStyle.width),
                    color: layer.lineStyle.color
                ))
                fit = DataBox3D(min: p, max: p).intersection(box)?.union(fit) ?? fit

            case .gradientFlow:
                guard let id = layer.sourceA,
                      let source = request.compiled.first(where: { $0.layer.id == id }),
                      source.layer.kind.isGradientSource, let f = source.primary else { continue }
                let floorZ = view.center.z - view.halfExtent + 0.02 * view.halfExtent
                let raw = compiled.secondary?.evaluate([]) ?? 1
                let progress = raw.isFinite ? min(max(raw, 0), 1) : 1
                let width = max(layer.lineStyle.width * request.backingScale, 0.5)
                let limit = SurfaceMesher.coordinateLimit
                var extent: [SIMD3<Double>] = []
                for seed in ScatterData.parse(layer.formula).prefix(40) {
                    let xy = GradientFlow.path(
                        of: f, from: seed, center: view.center, halfExtent: view.halfExtent, descent: layer.arrowScale < 0)
                    let line = xy.map { SIMD3($0.x, $0.y, layer.gradientOnFloor ? floorZ : f.evaluate([$0.x, $0.y])) }
                    extent.append(contentsOf: line)
                    if line.count >= 2 {
                        scene.polylines.append(Polyline3D(
                            points: line.map {
                                simd_clamp(SIMD3<Float>(view.normalized($0)), SIMD3(repeating: -limit), SIMD3(repeating: limit))
                            },
                            color: layer.lineStyle.color, width: width))
                    }
                    if let ball = GradientFlow.point(along: line, fraction: progress) {
                        scene.meshes.append(PointMarker.mesh(
                            center: SIMD3<Float>(view.normalized(ball)),
                            radius: PointMarker.radius(width: layer.lineStyle.width * 1.8),
                            color: layer.lineStyle.color))
                    }
                }
                fit = DataBox3D.enclosing(extent)?.intersection(box)?.union(fit) ?? fit

            case .gradientField:
                guard let id = layer.sourceA,
                      let source = request.compiled.first(where: { $0.layer.id == id }),
                      source.layer.kind.isGradientSource, let f = source.primary else { continue }
                let arrows = GradientField.arrows(
                    of: f, center: view.center, halfExtent: view.halfExtent, density: layer.gridDensity,
                    scale: layer.arrowScale, onFloor: layer.gradientOnFloor)
                let width = max(layer.lineStyle.width * request.backingScale, 0.5)
                let limit = SurfaceMesher.coordinateLimit
                for arrow in arrows {
                    scene.polylines.append(Polyline3D(
                        points: arrow.path.map {
                            simd_clamp(SIMD3<Float>(view.normalized($0)), SIMD3(repeating: -limit), SIMD3(repeating: limit))
                        },
                        color: GradientField.color(level: arrow.level), width: width))
                }
                fit = DataBox3D.enclosing(arrows.map(\.tip))?.intersection(box)?.union(fit) ?? fit

            case .tangentPlane:
                guard let id = layer.sourceA,
                      let source = request.compiled.first(where: { $0.layer.id == id }),
                      let plane = Tangents.tangentPlane(of: source, u: layer.anchorU, v: layer.anchorV)
                else { continue }
                let (mesh, lines, extent) = tangentPlaneGeometry(plane, layer: layer, request: request)
                scene.meshes.append(contentsOf: mesh)
                scene.polylines.append(contentsOf: lines)
                fit = extent.intersection(box)?.union(fit) ?? fit

            case .region, .surfaceIntersection, .projection, .tangent, .text, .scatter:
                continue
            }
        }

        for compiled in request.compiled where compiled.layer.isVisible && compiled.layer.kind == .surfaceIntersection {
            let (meshFrom, lineFrom) = (scene.meshes.count, scene.polylines.count)
            let (lines, extent) = surfaceIntersection(compiled.layer, cache: &surfaceMeshes, request: request)
            scene.polylines.append(contentsOf: lines)
            tag(&scene, layer: compiled.layer, meshFrom: meshFrom, lineFrom: lineFrom)
            fit = extent?.intersection(box)?.union(fit) ?? fit
        }

        // 投影在最后画：它的来源可能是交线，要等交线算完。
        for compiled in request.compiled where compiled.layer.isVisible && compiled.layer.kind == .projection {
            let (meshFrom, lineFrom) = (scene.meshes.count, scene.polylines.count)
            let result = projection(compiled.layer, cache: &surfaceMeshes, request: request)
            scene.polylines.append(contentsOf: result.polylines)
            scene.meshes.append(contentsOf: result.meshes)
            tag(&scene, layer: compiled.layer, meshFrom: meshFrom, lineFrom: lineFrom)
            fit = result.extent?.intersection(box)?.union(fit) ?? fit
        }

        return BuiltScene3D(scene: scene, view: view, fitBounds: fit)
    }

    /// 这个图层刚加进场景的几何打上图层 id；曲面图层按「不透明度」把颜色调成半透明
    /// （缓存里给交线用的网格不受影响，它们是在打标记之前存下的）。
    static func tag(_ scene: inout Scene3D, layer: Layer, meshFrom: Int, lineFrom: Int) {
        let translucent = layer.fillStyle.opacity < 0.999
            && (layer.kind.isSurfaceSource || (layer.kind.canExtrude && layer.extrudesInSpace))
        for index in meshFrom..<scene.meshes.count {
            scene.meshes[index].layerID = layer.id
            if translucent {
                scene.meshes[index].color = scene.meshes[index].color.withAlpha(max(layer.fillStyle.opacity, 0.02))
            }
        }
        for index in lineFrom..<scene.polylines.count { scene.polylines[index].layerID = layer.id }
    }

    // MARK: - 平面曲线

    /// 平面曲线在坐标盒 xy 范围上的采样：直接用 2D 的采样器，给它一个铺满盒子 xy 范围的虚拟视口，
    /// 分辨率按画质定（容差、网格密度都按这个视口的「像素」算）。
    static func planeCurve(
        _ compiled: LayerCompiler.CompiledLayer,
        request: SceneBuild3DRequest
    ) -> [[SIMD2<Double>]] {
        let view = request.view
        let resolution: Double
        switch request.quality {
        case .interactive: resolution = 360
        case .full: resolution = 900
        case .high: resolution = 1600
        }
        let viewport = Viewport2D(
            centerX: view.center.x,
            centerY: view.center.y,
            scale: resolution / (2 * view.halfExtent),
            widthPixels: resolution,
            heightPixels: resolution
        )
        let layer = compiled.layer
        let kind = layer.kind
        let lower = min(layer.domainLower, layer.domainUpper)
        let upper = max(layer.domainLower, layer.domainUpper)

        switch kind {
        case .explicit:
            guard let f = compiled.primary else { return [] }
            let range = layer.usesExplicitDomain ? lower...upper : viewport.xRange
            return CurveSampler.sampleExplicit(
                f: { f.evaluate(kind.primaryValues(argument: $0)) },
                xRange: range, viewport: viewport, quality: request.quality
            ).segments
        case .parametric:
            guard let fx = compiled.primary, let fy = compiled.secondary else { return [] }
            return CurveSampler.sampleParametric(
                tRange: lower...upper,
                f: { t in SIMD2(fx.evaluate([t]), fy.evaluate([t])) },
                viewport: viewport, quality: request.quality
            ).segments
        case .polar:
            guard let r = compiled.primary else { return [] }
            return CurveSampler.samplePolar(
                r: { r.evaluate(kind.primaryValues(argument: $0)) },
                thetaRange: lower...upper, viewport: viewport, quality: request.quality
            ).segments
        case .implicit:
            guard let f = compiled.primary else { return [] }
            var grid = FieldGrid(viewport: viewport, quality: request.quality)
            FieldEvaluator.fill(&grid, expr: f)
            return MarchingSquares.contours(grid: grid, level: 0)
        default:
            return []
        }
    }

    /// 平面曲线画在 z = 0 平面上。
    static func lift(_ runs: [[SIMD2<Double>]], layer: Layer, request: SceneBuild3DRequest) -> [Polyline3D] {
        let limit = SurfaceMesher.coordinateLimit
        let width = max(layer.lineStyle.width * request.backingScale, 0.5)
        return runs.filter { $0.count >= 2 }.map { run in
            Polyline3D(
                points: run.map {
                    simd_clamp(SIMD3<Float>(request.view.normalized(SIMD3($0.x, $0.y, 0))),
                               SIMD3(repeating: -limit), SIMD3(repeating: limit))
                },
                color: layer.lineStyle.color,
                width: width
            )
        }
    }

    /// 平面曲线沿 z 拉成竖直的曲面，上下各伸出盒子一点，由盒面裁齐。网格线：竖直方向落在 z 的刻度上，
    /// 水平方向沿曲线按弧长等距。
    static func extrude(_ runs: [[SIMD2<Double>]], color: RGBAColor, view: View3D) -> Mesh3D {
        var mesh = Mesh3D(color: color)
        let z0 = view.center.z - view.halfExtent * 1.02
        let z1 = view.center.z + view.halfExtent * 1.02
        let lineStep = AxisTicks.niceStep(minimumDataStep: 2 * view.halfExtent / 8)
        let limit = SurfaceMesher.coordinateLimit
        func place(_ p: SIMD3<Double>) -> SIMD3<Float> {
            simd_clamp(SIMD3<Float>(view.normalized(p)), SIMD3(repeating: -limit), SIMD3(repeating: limit))
        }

        for run in runs where run.count >= 2 {
            let base = UInt32(mesh.vertices.count)
            var arc = 0.0
            for i in run.indices {
                if i > 0 { arc += simd_length(run[i] - run[i - 1]) }
                let tangent = run[min(i + 1, run.count - 1)] - run[max(i - 1, 0)]
                let length = simd_length(tangent)
                let normal = length > 0 ? SIMD3<Float>(Float(-tangent.y / length), Float(tangent.x / length), 0) : SIMD3(1, 0, 0)
                let along = Float(arc / lineStep)
                mesh.vertices.append(MeshVertex3D(
                    position: place(SIMD3(run[i].x, run[i].y, z0)),
                    normal: normal,
                    parameter: SIMD2(along, Float(z0 / lineStep))
                ))
                mesh.vertices.append(MeshVertex3D(
                    position: place(SIMD3(run[i].x, run[i].y, z1)),
                    normal: normal,
                    parameter: SIMD2(along, Float(z1 / lineStep))
                ))
            }
            for i in 0..<UInt32(run.count - 1) {
                let bottom = base + 2 * i, top = bottom + 1
                let nextBottom = bottom + 2, nextTop = bottom + 3
                mesh.indices.append(contentsOf: [bottom, nextBottom, nextTop, bottom, nextTop, top])
            }
        }
        return mesh
    }

    // MARK: - 图型

    /// z = f(x, y)：在坐标盒的 x、y 范围上铺网格。网格线落在刻度的整数倍上，与盒壁的刻度对齐。
    static func explicitSurface(
        _ f: CompiledExpression,
        layer: Layer,
        request: SceneBuild3DRequest
    ) -> (Mesh3D, DataBox3D?) {
        let view = request.view
        let n = surfaceResolution(request.quality)
        let x0 = view.center.x - view.halfExtent
        let y0 = view.center.y - view.halfExtent
        let step = 2 * view.halfExtent / Double(n - 1)
        let zs = GridEvaluator.evaluate(f, counts: [n, n], origins: [x0, y0], steps: [step, step], names: ["x", "y"])

        let lineStep = AxisTicks.niceStep(minimumDataStep: 2 * view.halfExtent / 8)
        var points: [SIMD3<Double>] = []
        var parameters: [SIMD2<Float>] = []
        points.reserveCapacity(n * n)
        parameters.reserveCapacity(n * n)
        for j in 0..<n {
            for i in 0..<n {
                let x = x0 + step * Double(i)
                let y = y0 + step * Double(j)
                points.append(SIMD3(x, y, zs[j * n + i]))
                parameters.append(SIMD2(Float(x / lineStep), Float(y / lineStep)))
            }
        }
        let scalars = layer.colorsBySlope ? slopeLevels(zs, n: n, step: step) : nil
        let mesh = SurfaceMesher.mesh(points: points, cols: n, rows: n, parameters: parameters,
                                      view: view, color: layer.lineStyle.color, scalars: scalars)
        return (mesh, DataBox3D.enclosing(points))
    }

    /// 网格上每点的坡度 |∇f|（中心差分，边上单侧），按第 99 百分位归一化到 0…1：
    /// 个别极点飞到天上的梯度不会把其余地方全压成蓝色。
    static func slopeLevels(_ zs: [Double], n: Int, step: Double) -> [Float] {
        guard n >= 2, zs.count == n * n else { return [] }
        func z(_ i: Int, _ j: Int) -> Double { zs[min(max(j, 0), n - 1) * n + min(max(i, 0), n - 1)] }
        var slopes = [Double](repeating: 0, count: n * n)
        for j in 0..<n {
            for i in 0..<n {
                let spanX = Double(min(i + 1, n - 1) - max(i - 1, 0)) * step
                let spanY = Double(min(j + 1, n - 1) - max(j - 1, 0)) * step
                let gx = (z(i + 1, j) - z(i - 1, j)) / spanX
                let gy = (z(i, j + 1) - z(i, j - 1)) / spanY
                let g = (gx * gx + gy * gy).squareRoot()
                slopes[j * n + i] = g.isFinite ? g : 0
            }
        }
        let sorted = slopes.sorted()
        let reference = max(sorted[min(Int(Double(sorted.count - 1) * 0.99), sorted.count - 1)], 1e-12)
        return slopes.map { Float(min($0 / reference, 1)) }
    }

    /// (x, y, z) = F(u, v)：在 u、v 的范围上铺网格，整张曲面都采（与坐标盒无关）。
    static func parametricSurface(
        _ fx: CompiledExpression,
        _ fy: CompiledExpression,
        _ fz: CompiledExpression,
        layer: Layer,
        request: SceneBuild3DRequest
    ) -> (Mesh3D, DataBox3D?) {
        let n = surfaceResolution(request.quality)
        let u0 = min(layer.domainLower, layer.domainUpper)
        let u1 = max(layer.domainLower, layer.domainUpper)
        let v0 = min(layer.domain2Lower, layer.domain2Upper)
        let v1 = max(layer.domain2Lower, layer.domain2Upper)
        guard u1 > u0, v1 > v0, u0.isFinite, u1.isFinite, v0.isFinite, v1.isFinite else {
            return (Mesh3D(color: layer.lineStyle.color), nil)
        }
        let du = (u1 - u0) / Double(n - 1)
        let dv = (v1 - v0) / Double(n - 1)
        let names = ["u", "v"]
        let xs = GridEvaluator.evaluate(fx, counts: [n, n], origins: [u0, v0], steps: [du, dv], names: names)
        let ys = GridEvaluator.evaluate(fy, counts: [n, n], origins: [u0, v0], steps: [du, dv], names: names)
        let zs = GridEvaluator.evaluate(fz, counts: [n, n], origins: [u0, v0], steps: [du, dv], names: names)

        var points: [SIMD3<Double>] = []
        var parameters: [SIMD2<Float>] = []
        points.reserveCapacity(n * n)
        parameters.reserveCapacity(n * n)
        let lines = parameterLines
        for j in 0..<n {
            for i in 0..<n {
                let index = j * n + i
                points.append(SIMD3(xs[index], ys[index], zs[index]))
                parameters.append(SIMD2(Float(i) / Float(n - 1) * lines, Float(j) / Float(n - 1) * lines))
            }
        }
        let mesh = SurfaceMesher.mesh(points: points, cols: n, rows: n, parameters: parameters,
                                      view: request.view, color: layer.lineStyle.color)
        return (mesh, DataBox3D.enclosing(points))
    }

    /// 空间曲线的采样点（数据坐标，断开处分成几段）。
    static func spaceCurveRuns(
        _ fx: CompiledExpression,
        _ fy: CompiledExpression,
        _ fz: CompiledExpression,
        layer: Layer,
        request: SceneBuild3DRequest
    ) -> [[SIMD3<Double>]] {
        let lower = min(layer.domainLower, layer.domainUpper)
        let upper = max(layer.domainLower, layer.domainUpper)
        return SpaceCurveSampler.sample(
            f: { t in SIMD3(fx.evaluate([t]), fy.evaluate([t]), fz.evaluate([t])) },
            tRange: lower...upper,
            view: request.view,
            options: SpaceCurveSampler.options(for: request.quality)
        )
    }

    /// (x, y, z) = F(t)：整条曲线都采，线宽同 2D 描边。
    static func spaceCurve(
        _ fx: CompiledExpression,
        _ fy: CompiledExpression,
        _ fz: CompiledExpression,
        layer: Layer,
        request: SceneBuild3DRequest
    ) -> ([Polyline3D], DataBox3D?) {
        let runs = spaceCurveRuns(fx, fy, fz, layer: layer, request: request)
        let width = max(layer.lineStyle.width * request.backingScale, 0.5)
        let limit = SurfaceMesher.coordinateLimit
        let lines = runs.map { run in
            Polyline3D(
                points: run.map {
                    simd_clamp(SIMD3<Float>(request.view.normalized($0)), SIMD3(repeating: -limit), SIMD3(repeating: limit))
                },
                color: layer.lineStyle.color,
                width: width
            )
        }
        return (lines, DataBox3D.enclosing(runs.joined()))
    }

    /// 来源图层的曲面网格：曲面类图层才有，公式有错或没填的返回 nil。
    static func surfaceMesh(
        of compiled: LayerCompiler.CompiledLayer,
        request: SceneBuild3DRequest
    ) -> Mesh3D? {
        let layer = compiled.layer
        switch layer.kind {
        case .surface:
            guard let f = compiled.primary else { return nil }
            return explicitSurface(f, layer: layer, request: request).0
        case .parametricSurface:
            guard let fx = compiled.primary, let fy = compiled.secondary, let fz = compiled.tertiary else { return nil }
            return parametricSurface(fx, fy, fz, layer: layer, request: request).0
        case .implicitSurface:
            guard let f = compiled.primary else { return nil }
            return implicitSurface(f, layer: layer, request: request)
        default:
            return nil
        }
    }

    /// 两个来源曲面的交线，画成一组空间折线。来源缺失、不是曲面、公式有错、两个是同一个图层时什么都不画。
    static func surfaceIntersection(
        _ layer: Layer,
        cache: inout [UUID: Mesh3D],
        request: SceneBuild3DRequest
    ) -> ([Polyline3D], DataBox3D?) {
        let runs = intersectionRuns(layer, cache: &cache, request: request)
        let limit = SurfaceMesher.coordinateLimit
        let width = max(layer.lineStyle.width * request.backingScale, 0.5)
        let lines = runs.map { run in
            Polyline3D(
                points: run.map {
                    simd_clamp(SIMD3<Float>(request.view.normalized($0)), SIMD3(repeating: -limit), SIMD3(repeating: limit))
                },
                color: layer.lineStyle.color, width: width
            )
        }
        return (lines, DataBox3D.enclosing(runs.joined()))
    }

    /// 交线的折线（数据坐标）。
    static func intersectionRuns(
        _ layer: Layer,
        cache: inout [UUID: Mesh3D],
        request: SceneBuild3DRequest
    ) -> [[SIMD3<Double>]] {
        guard let idA = layer.sourceA, let idB = layer.sourceB, idA != idB else { return [] }
        var meshes: [Mesh3D] = []
        for id in [idA, idB] {
            if let cached = cache[id] {
                meshes.append(cached)
            } else if let source = request.compiled.first(where: { $0.layer.id == id }),
                      let mesh = surfaceMesh(of: source, request: request) {
                cache[id] = mesh
                meshes.append(mesh)
            } else {
                return []
            }
        }
        return MeshIntersection.curves(meshes[0], meshes[1]).map { $0.map { request.view.data($0) } }
    }

    // MARK: - 切平面

    /// 切平面：切点上一小块半透明方片（边长约盒子的 40%）、方片的边框、从切点伸出的法线、切点处的小球。
    static func tangentPlaneGeometry(
        _ plane: Tangents.TangentPlane,
        layer: Layer,
        request: SceneBuild3DRequest
    ) -> (meshes: [Mesh3D], lines: [Polyline3D], extent: DataBox3D) {
        let view = request.view
        let half = 0.3 * view.halfExtent
        let e1 = simd_normalize(plane.tangentU)
        let e2 = simd_cross(plane.normal, e1)
        let limit = SurfaceMesher.coordinateLimit
        func place(_ p: SIMD3<Double>) -> SIMD3<Float> {
            simd_clamp(SIMD3<Float>(view.normalized(p)), SIMD3(repeating: -limit), SIMD3(repeating: limit))
        }

        let color = layer.lineStyle.color
        let corners = [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)].map { a, b in
            plane.point + e1 * (a * half) + e2 * (b * half)
        }
        let normalF = SIMD3<Float>(plane.normal)
        var patch = Mesh3D(color: color.withAlpha(0.38))
        patch.vertices = corners.map {
            MeshVertex3D(position: place($0), normal: normalF, parameter: SIMD2(.nan, .nan))
        }
        patch.indices = [0, 1, 2, 0, 2, 3]

        let width = max(layer.lineStyle.width * request.backingScale, 0.5)
        let outline = Polyline3D(points: (corners + [corners[0]]).map(place), color: color, width: width)
        let tip = plane.point + plane.normal * (1.6 * half)
        let normalLine = Polyline3D(points: [place(plane.point), place(tip)], color: color, width: width)
        let marker = PointMarker.mesh(
            center: place(plane.point), radius: PointMarker.radius(width: layer.lineStyle.width * 1.6), color: color)

        let extent = DataBox3D.enclosing(corners + [tip, plane.point]) ?? DataBox3D(min: plane.point, max: plane.point)
        return ([patch, marker], [outline, normalLine], extent)
    }

    // MARK: - 投影

    /// 投影图层的来源：点、空间曲线、曲面交线的折线（数据坐标）；点是长度为 1 的一段。
    static func projectableRuns(
        of source: LayerCompiler.CompiledLayer,
        cache: inout [UUID: Mesh3D],
        request: SceneBuild3DRequest
    ) -> [[SIMD3<Double>]] {
        let layer = source.layer
        switch layer.kind {
        case .point:
            guard let fx = source.primary, let fy = source.secondary, let fz = source.tertiary else { return [] }
            let p = SIMD3(fx.evaluate([]), fy.evaluate([]), fz.evaluate([]))
            return p.x.isFinite && p.y.isFinite && p.z.isFinite ? [[p]] : []
        case .spaceCurve:
            guard let fx = source.primary, let fy = source.secondary, let fz = source.tertiary else { return [] }
            return spaceCurveRuns(fx, fy, fz, layer: layer, request: request)
        case .surfaceIntersection:
            return intersectionRuns(layer, cache: &cache, request: request)
        default:
            return []
        }
    }

    /// 投影：每一段折线的点落到目标平面上（正投影），再加上从原图形连到投影的细线。
    static func projection(
        _ layer: Layer,
        cache: inout [UUID: Mesh3D],
        request: SceneBuild3DRequest
    ) -> (polylines: [Polyline3D], meshes: [Mesh3D], extent: DataBox3D?) {
        guard let sourceID = layer.sourceA,
              let source = request.compiled.first(where: { $0.layer.id == sourceID }),
              source.layer.kind.isProjectable else { return ([], [], nil) }

        // 目标平面：坐标面（位置由偏移定）或另一个平面图层。
        let normal: SIMD3<Double>
        let offset: Double
        if let axis = layer.projectionTarget.normal {
            normal = axis
            offset = layer.projectionOffset
        } else if let id = layer.sourceB, let target = request.compiled.first(where: { $0.layer.id == id }),
                  case let .plane(n, c)? = SpaceGeometry.recognize(target, in: request.compiled) {
            normal = n
            offset = c
        } else {
            return ([], [], nil)
        }

        let runs = projectableRuns(of: source, cache: &cache, request: request)
        let view = request.view
        let limit = SurfaceMesher.coordinateLimit
        func place(_ p: SIMD3<Double>) -> SIMD3<Float> {
            simd_clamp(SIMD3<Float>(view.normalized(p)), SIMD3(repeating: -limit), SIMD3(repeating: limit))
        }

        let color = layer.lineStyle.color
        let width = max(layer.lineStyle.width * request.backingScale, 0.5)
        let projectorColor = color.withAlpha(color.a * 0.5)
        var polylines: [Polyline3D] = []
        var meshes: [Mesh3D] = []
        var extent: [SIMD3<Double>] = []

        // 斜投影：沿给定方向投到平面上；方向与平面平行时投不出去，什么都不画。
        var slant: SIMD3<Double>?
        if let direction = layer.projectionDirection, simd_length(direction) > 1e-9 {
            slant = simd_normalize(direction)
            if abs(simd_dot(normal, slant!)) <= 1e-9 { return ([], [], nil) }
        }
        for run in runs {
            let feet = run.map { p -> SIMD3<Double> in
                if let slant, let q = SpaceGeometry.project(p, onPlane: normal, offset: offset, along: slant) { return q }
                return SpaceGeometry.foot(of: p, onPlane: normal, offset: offset)
            }
            extent.append(contentsOf: feet)
            if run.count == 1 {
                meshes.append(PointMarker.mesh(
                    center: place(feet[0]), radius: PointMarker.radius(width: layer.lineStyle.width), color: color))
            } else if feet.count >= 2 {
                polylines.append(Polyline3D(points: feet.map(place), color: color, width: width))
            }
            guard layer.showsProjectors else { continue }
            // 投影线：沿折线均匀取不多于 24 根（点只有一根）。
            let count = min(run.count, 24)
            for k in 0..<count {
                let index = count == 1 ? 0 : k * (run.count - 1) / (count - 1)
                polylines.append(Polyline3D(
                    points: [place(run[index]), place(feet[index])],
                    color: projectorColor, width: max(width * 0.4, 0.5)))
            }
        }
        return (polylines, meshes, DataBox3D.enclosing(extent))
    }

    /// F(x, y, z) = 0：在坐标盒的体网格上求值，marching tetrahedra 抽零值面。
    static func implicitSurface(
        _ f: CompiledExpression,
        layer: Layer,
        request: SceneBuild3DRequest
    ) -> Mesh3D {
        let view = request.view
        let cells = volumeResolution(request.quality)
        let origin = view.center - view.halfExtent
        let step = 2 * view.halfExtent / Double(cells)
        let values = GridEvaluator.evaluate(
            f,
            counts: [cells + 1, cells + 1, cells + 1],
            origins: [origin.x, origin.y, origin.z],
            steps: [step, step, step],
            names: ["x", "y", "z"]
        )
        return MarchingTetrahedra.extract(values: values, cells: cells, color: layer.lineStyle.color)
    }
}
