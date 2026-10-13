import simd
import XCTest
@testable import GrapherKit

/// 3D 采样：网格、法向、断开处理与零值面的精度。坐标盒默认 ±4，归一化后半径 2 的球面落在 0.5。
final class Sampling3DTests: XCTestCase {

    private func compile(_ source: String, _ variables: [String]) throws -> CompiledExpression {
        try CompiledExpression(source: source, context: ExpressionContext(variables: variables))
    }

    private func request(_ layers: [Layer], quality: SampleQuality = .full) -> SceneBuild3DRequest {
        var document = GrapherDocument(dimension: .space)
        document.layers = layers
        return SceneBuild3DRequest(
            document: document,
            compiled: LayerCompiler().compile(document),
            view: .standard,
            quality: quality,
            backingScale: 2
        )
    }

    private func referenced(_ mesh: Mesh3D) -> [MeshVertex3D] {
        Set(mesh.indices).map { mesh.vertices[Int($0)] }
    }

    // MARK: - 显式曲面

    func testPlaneHasAFlatGridAndOneNormal() throws {
        var layer = Layer.makeDefault(kind: .surface, index: 0)
        layer.formula = "0.5*x"
        let (mesh, extent) = SceneBuilder3D.explicitSurface(try compile("0.5*x", ["x", "y"]), layer: layer, request: request([layer]))
        let n = SceneBuilder3D.surfaceResolution(.full)
        XCTAssertEqual(mesh.triangleCount, 2 * (n - 1) * (n - 1))
        let expected = simd_normalize(SIMD3<Float>(-0.5, 0, 1))
        for vertex in referenced(mesh) {
            XCTAssertEqual(abs(simd_dot(vertex.normal, expected)), 1, accuracy: 1e-4)
            XCTAssertEqual(vertex.position.z, 0.5 * vertex.position.x, accuracy: 1e-5)
        }
        XCTAssertEqual(extent?.min.x ?? 0, -4, accuracy: 1e-9)
        XCTAssertEqual(extent?.max.y ?? 0, 4, accuracy: 1e-9)
    }

    /// 1/x 在 x=0 两侧一正一负：不能用一面竖墙把两边连起来。
    func testPoleIsNotBridged() throws {
        var layer = Layer.makeDefault(kind: .surface, index: 0)
        layer.formula = "1/x"
        let (mesh, _) = SceneBuilder3D.explicitSurface(try compile("1/x", ["x", "y"]), layer: layer, request: request([layer]))
        XCTAssertGreaterThan(mesh.triangleCount, 0)
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.vertices[Int(mesh.indices[t])].position
            let b = mesh.vertices[Int(mesh.indices[t + 1])].position
            let c = mesh.vertices[Int(mesh.indices[t + 2])].position
            let zs = [a.z, b.z, c.z]
            XCTAssertFalse(zs.max()! > 1.5 && zs.min()! < -1.5, "三角形跨过了极点")
            for p in [a, b, c] { XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite) }
        }
    }

    /// 无定义的地方（根号下为负）不出三角形。
    func testUndefinedRegionStaysEmpty() throws {
        var layer = Layer.makeDefault(kind: .surface, index: 0)
        layer.formula = "sqrt(4 - x^2 - y^2)"
        let (mesh, _) = SceneBuilder3D.explicitSurface(
            try compile(layer.formula, ["x", "y"]), layer: layer, request: request([layer]))
        XCTAssertGreaterThan(mesh.triangleCount, 0)
        for vertex in referenced(mesh) {
            let r = simd_length(SIMD2(vertex.position.x, vertex.position.y))
            XCTAssertLessThanOrEqual(r, 0.5 + 1e-5, "只在半径 2 的圆盘里有面")
        }
    }

    // MARK: - 参数曲面

    func testParametricSphereLiesOnTheSphereWithRadialNormals() throws {
        var layer = Layer.makeDefault(kind: .parametricSurface, index: 0)
        layer.formula = "2*cos(u)*sin(v)"
        layer.secondaryFormula = "2*sin(u)*sin(v)"
        layer.tertiaryFormula = "2*cos(v)"
        layer.domainLower = 0
        layer.domainUpper = 2 * .pi
        layer.domain2Lower = 0
        layer.domain2Upper = .pi
        let r = request([layer])
        let compiled = r.compiled[0]
        let (mesh, extent) = SceneBuilder3D.parametricSurface(
            try XCTUnwrap(compiled.primary), try XCTUnwrap(compiled.secondary), try XCTUnwrap(compiled.tertiary),
            layer: layer, request: r)
        XCTAssertGreaterThan(mesh.triangleCount, 1000)
        for vertex in referenced(mesh) {
            XCTAssertEqual(simd_length(vertex.position), 0.5, accuracy: 1e-5)
            XCTAssertGreaterThan(abs(simd_dot(vertex.normal, simd_normalize(vertex.position))), 0.99)
        }
        XCTAssertEqual(extent?.max.z ?? 0, 2, accuracy: 1e-9)
    }

    // MARK: - 隐式曲面

    func testImplicitSphereIsAccurateAndPointsOutwards() throws {
        let f = try compile("x^2 + y^2 + z^2 - 4", ["x", "y", "z"])
        let mesh = SceneBuilder3D.implicitSurface(f, layer: Layer.makeDefault(kind: .implicitSurface, index: 0),
                                                  request: request([]))
        XCTAssertGreaterThan(mesh.triangleCount, 1000)
        XCTAssertEqual(mesh.indices.count, mesh.vertices.count)
        for vertex in mesh.vertices {
            // 线性插值的误差远小于一格（2/96 ≈ 0.02）。
            XCTAssertEqual(simd_length(vertex.position), 0.5, accuracy: 0.004)
            XCTAssertGreaterThan(simd_dot(vertex.normal, simd_normalize(vertex.position)), 0.99, "梯度朝外")
            XCTAssertTrue(vertex.parameter.x.isNaN, "隐式曲面没有网格线参数")
        }
    }

    func testImplicitSurfaceWithNoZeroIsEmpty() throws {
        let f = try compile("x^2 + y^2 + z^2 + 1", ["x", "y", "z"])
        let mesh = SceneBuilder3D.implicitSurface(f, layer: Layer.makeDefault(kind: .implicitSurface, index: 0),
                                                  request: request([]))
        XCTAssertEqual(mesh.triangleCount, 0)
    }

    /// 同一个面的两边各数一遍：外侧（F > 0 一侧）拼出的面积约等于球面积。
    func testImplicitSphereAreaMatchesTheFormula() throws {
        let f = try compile("x^2 + y^2 + z^2 - 4", ["x", "y", "z"])
        let mesh = SceneBuilder3D.implicitSurface(f, layer: Layer.makeDefault(kind: .implicitSurface, index: 0),
                                                  request: request([]))
        var area: Float = 0
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.vertices[Int(mesh.indices[t])].position
            let b = mesh.vertices[Int(mesh.indices[t + 1])].position
            let c = mesh.vertices[Int(mesh.indices[t + 2])].position
            area += simd_length(simd_cross(b - a, c - a)) / 2
        }
        // 归一化半径 0.5：4π·0.25 = π。
        XCTAssertEqual(area, .pi, accuracy: 0.03)
    }

    // MARK: - 空间曲线

    func testHelixStartsAndEndsOnTheDomainAndStaysOnItsCylinder() throws {
        let view = View3D.standard
        let runs = SpaceCurveSampler.sample(
            f: { t in SIMD3(3 * cos(t), 3 * sin(t), t / 4) },
            tRange: -4 * .pi...4 * .pi,
            view: view,
            options: SpaceCurveSampler.options(for: .full)
        )
        XCTAssertEqual(runs.count, 1)
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.first?.z ?? 0, -.pi, accuracy: 1e-12)
        XCTAssertEqual(run.last?.z ?? 0, .pi, accuracy: 1e-12)
        for p in run { XCTAssertEqual(simd_length(SIMD2(p.x, p.y)), 3, accuracy: 1e-9) }
        // 相邻点的弦在归一化坐标里离真实曲线不超过容差：用弦中点到圆柱的距离估一下。
        let tolerance = SpaceCurveSampler.options(for: .full).tolerance
        for (a, b) in zip(run, run.dropFirst()) {
            let mid = (a + b) / 2
            let gap = (3 - simd_length(SIMD2(mid.x, mid.y))) / view.halfExtent
            XCTAssertLessThan(gap, tolerance * 1.5)
        }
    }

    func testCurveBreaksWhereItIsUndefined() {
        let runs = SpaceCurveSampler.sample(
            f: { t in SIMD3(t, sqrt(1 - t * t), 0) },
            tRange: -2...2,
            view: .standard,
            options: SpaceCurveSampler.options(for: .full)
        )
        XCTAssertEqual(runs.count, 1, "只有 [-1, 1] 那一段")
        for p in runs[0] { XCTAssertLessThanOrEqual(abs(p.x), 1) }
    }

    // MARK: - 整个场景

    func testSampleDocumentBuildsEveryKind() {
        let document = GrapherDocument.sample3D()
        let built = SceneBuilder3D.build(SceneBuild3DRequest(
            document: document,
            compiled: LayerCompiler().compile(document),
            view: document.view3D,
            quality: .interactive,
            backingScale: 2
        ))
        XCTAssertEqual(built.scene.meshes.count, 3, "显式曲面、环面、球面")
        XCTAssertEqual(built.scene.polylines.count, 1, "螺旋线")
        XCTAssertTrue(built.scene.meshes.allSatisfy { $0.triangleCount > 100 })
        let fit = try? XCTUnwrap(built.fitBounds)
        XCTAssertEqual(fit?.max.z ?? 0, 3.3, accuracy: 0.05, "环面顶在 z = 3.3")
    }

    // MARK: - 平面曲线放进立体图（同 Desmos 3D 的「延伸到 3D」）

    private func buildPlaneCurve(_ formula: String, kind: PlotKind = .explicit, extrudes: Bool) -> BuiltScene3D {
        var document = GrapherDocument(dimension: .space)
        var layer = Layer.makeDefault(kind: kind, index: 0)
        layer.formula = formula
        layer.extrudesInSpace = extrudes
        document.layers = [layer]
        return SceneBuilder3D.build(SceneBuild3DRequest(
            document: document, compiled: LayerCompiler().compile(document),
            view: .standard, quality: .full, backingScale: 2))
    }

    func testPlaneCurveLiesOnTheFloorPlaneByDefault() throws {
        let built = buildPlaneCurve("x", extrudes: false)
        XCTAssertTrue(built.scene.meshes.isEmpty)
        let line = try XCTUnwrap(built.scene.polylines.first)
        for p in line.points {
            XCTAssertEqual(p.z, 0, accuracy: 1e-7, "画在 z = 0 上")
            XCTAssertEqual(p.y, p.x, accuracy: 1e-5)
        }
    }

    func testExtrudedPlaneCurveIsAVerticalWallThroughTheBox() throws {
        let built = buildPlaneCurve("x", extrudes: true)
        XCTAssertTrue(built.scene.polylines.isEmpty)
        let mesh = try XCTUnwrap(built.scene.meshes.first)
        XCTAssertGreaterThan(mesh.triangleCount, 0)
        let expected = simd_normalize(SIMD3<Float>(-1, 1, 0))
        for vertex in mesh.vertices {
            XCTAssertEqual(vertex.position.y, vertex.position.x, accuracy: 1e-5, "落在 y = x 这面墙上")
            XCTAssertGreaterThanOrEqual(abs(vertex.position.z), 1, "上下都伸出盒子，由盒面裁齐")
            XCTAssertEqual(abs(simd_dot(vertex.normal, expected)), 1, accuracy: 1e-4, "法向水平")
        }
        XCTAssertEqual(built.fitBounds?.min.z ?? 0, -4, accuracy: 1e-9)
    }

    func testImplicitPlaneCurveExtrudesIntoACylinder() throws {
        let built = buildPlaneCurve("x^2 + y^2 - 4", kind: .implicit, extrudes: true)
        let mesh = try XCTUnwrap(built.scene.meshes.first)
        for vertex in mesh.vertices {
            XCTAssertEqual(simd_length(SIMD2(vertex.position.x, vertex.position.y)), 0.5, accuracy: 0.003)
        }
    }

    func testRegionsStayOutOfSpaceDocuments() {
        var document = GrapherDocument(dimension: .space)
        document.layers = [Layer.makeDefault(kind: .region, index: 0)]
        let built = SceneBuilder3D.build(SceneBuild3DRequest(
            document: document, compiled: LayerCompiler().compile(document),
            view: .standard, quality: .interactive, backingScale: 2))
        XCTAssertTrue(built.scene.isEmpty)
    }
}
