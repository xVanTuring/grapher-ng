import simd
import XCTest
@testable import GrapherKit

/// 切线、法线、切平面：数值导数的精度、画出来的几何、与位置关系面板的衔接。
final class TangentTests: XCTestCase {

    private func compiled(_ layers: [Layer]) -> [LayerCompiler.CompiledLayer] {
        var document = GrapherDocument(dimension: layers.contains { $0.kind.dimension == .space } ? .space : .plane)
        document.layers = layers
        return LayerCompiler().compile(document)
    }

    private func layer(_ kind: PlotKind, _ formula: String, secondary: String = "", tertiary: String = "") -> Layer {
        var layer = Layer.makeDefault(kind: kind, index: 0)
        layer.formula = formula
        if !secondary.isEmpty { layer.secondaryFormula = secondary }
        if !tertiary.isEmpty { layer.tertiaryFormula = tertiary }
        return layer
    }

    // MARK: - 平面切线

    func testExplicitTangentHasTheDerivativeAsSlope() throws {
        let parabola = layer(.explicit, "x^2")
        let tangent = try XCTUnwrap(Tangents.tangent(of: compiled([parabola])[0], at: 1.5))
        XCTAssertEqual(tangent.point.x, 1.5, accuracy: 1e-12)
        XCTAssertEqual(tangent.point.y, 2.25, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(tangent.slope), 3, accuracy: 1e-6)
        XCTAssertEqual(simd_length(tangent.direction), 1, accuracy: 1e-12)
        XCTAssertEqual(simd_dot(tangent.direction, tangent.normal), 0, accuracy: 1e-12)
    }

    func testParametricAndPolarTangents() throws {
        // 单位圆在 t = 0 的切线竖直（斜率 nil），方向 +y。
        let circle = layer(.parametric, "cos(t)", secondary: "sin(t)")
        let atZero = try XCTUnwrap(Tangents.tangent(of: compiled([circle])[0], at: 0))
        XCTAssertNil(atZero.slope)
        XCTAssertEqual(atZero.direction.y, 1, accuracy: 1e-6)
        XCTAssertEqual(atZero.point.x, 1, accuracy: 1e-12)

        // 极坐标 r = 1 就是单位圆，θ = π/2 处切线水平。
        let polar = layer(.polar, "1")
        let top = try XCTUnwrap(Tangents.tangent(of: compiled([polar])[0], at: Double.pi / 2))
        XCTAssertEqual(try XCTUnwrap(top.slope), 0, accuracy: 1e-6)
        XCTAssertEqual(top.point.y, 1, accuracy: 1e-9)
    }

    func testNoTangentWhereUndefinedOrWrongKind() {
        XCTAssertNil(Tangents.tangent(of: compiled([layer(.explicit, "1/x")])[0], at: 0))
        XCTAssertNil(Tangents.tangent(of: compiled([layer(.explicit, "sqrt(x)")])[0], at: -1))
        XCTAssertNil(Tangents.tangent(of: compiled([layer(.region, "x")])[0], at: 0))
        // 参数方程在尖点处导数为零（x = t^2, y = t^3 在 t = 0）。
        let cusp = layer(.parametric, "t^2", secondary: "t^3")
        XCTAssertNil(Tangents.tangent(of: compiled([cusp])[0], at: 0))
    }

    func testTangentLayerDrawsALineAndAMarker() throws {
        let parabola = layer(.explicit, "x^2")
        var tangent = Layer.makeDefault(kind: .tangent, index: 1)
        tangent.sourceA = parabola.id
        tangent.anchorU = 1
        var document = GrapherDocument()
        document.layers = [parabola, tangent]
        let viewport = Viewport2D(centerX: 0, centerY: 0, scale: 50, widthPixels: 800, heightPixels: 600)
        let built = SceneBuilder2D.build(SceneBuildRequest(
            document: document, compiled: LayerCompiler().compile(document), viewport: viewport,
            quality: .full, backingScale: 1))
        let probe = try XCTUnwrap(built.probeCurves.first { $0.layerID == tangent.id })
        // 切线 y = 2x - 1：线上的点都满足。
        for p in probe.segments.joined() { XCTAssertEqual(p.y, 2 * p.x - 1, accuracy: 1e-6) }
        // 法线 y = 1 - (x - 1)/2。
        tangent.drawsNormal = true
        document.layers = [parabola, tangent]
        let normalScene = SceneBuilder2D.build(SceneBuildRequest(
            document: document, compiled: LayerCompiler().compile(document), viewport: viewport,
            quality: .full, backingScale: 1))
        for p in try XCTUnwrap(normalScene.probeCurves.first { $0.layerID == tangent.id }).segments.joined() {
            XCTAssertEqual(p.y, 1 - (p.x - 1) / 2, accuracy: 1e-6)
        }
        let markers = built.scene.commands.compactMap { command -> MarkerPrimitiveBatch? in
            if case .markers(let batch) = command { return batch }
            return nil
        }
        XCTAssertFalse(markers.isEmpty, "切点处有标记")
    }

    // MARK: - 切平面

    func testTangentPlaneOfAnExplicitSurface() throws {
        // z = x*y 在 (1, 2)：点 (1,2,2)，法向 ∝ (-y, -x, 1) = (-2, -1, 1)。
        let saddle = layer(.surface, "x*y")
        let plane = try XCTUnwrap(Tangents.tangentPlane(of: compiled([saddle])[0], u: 1, v: 2))
        XCTAssertEqual(simd_length(plane.point - SIMD3(1, 2, 2)), 0, accuracy: 1e-9)
        XCTAssertEqual(simd_length(plane.normal - simd_normalize(SIMD3<Double>(-2, -1, 1))), 0, accuracy: 1e-6)
        XCTAssertEqual(plane.offset, simd_dot(plane.normal, SIMD3(1, 2, 2)), accuracy: 1e-12)
        XCTAssertEqual(simd_dot(plane.normal, plane.tangentU), 0, accuracy: 1e-6)
        XCTAssertEqual(simd_dot(plane.normal, plane.tangentV), 0, accuracy: 1e-6)
    }

    func testTangentPlaneOfAParametricSphere() throws {
        let sphere = layer(.parametricSurface, "2*cos(u)*sin(v)", secondary: "2*sin(u)*sin(v)", tertiary: "2*cos(v)")
        // u = 0, v = π/2：点 (2, 0, 0)，切平面 x = 2，法向 ±x（取 x ≥ 0 的一侧）。
        let plane = try XCTUnwrap(Tangents.tangentPlane(of: compiled([sphere])[0], u: 0, v: Double.pi / 2))
        XCTAssertEqual(simd_length(plane.point - SIMD3(2, 0, 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(abs(plane.normal.x), 1, accuracy: 1e-6)
        XCTAssertEqual(abs(plane.offset), 2, accuracy: 1e-6)
        // 球的北极 v = 0 奇异：没有切平面。
        XCTAssertNil(Tangents.tangentPlane(of: compiled([sphere])[0], u: 0, v: 0))
    }

    func testTangentPlaneLayerIsRecognisedAsAPlaneAndDrawn() throws {
        let saddle = layer(.surface, "x*y")
        var tangent = Layer.makeDefault(kind: .tangentPlane, index: 1)
        tangent.sourceA = saddle.id
        tangent.anchorU = 1
        tangent.anchorV = 2
        let all = compiled([saddle, tangent])

        // 位置关系面板能把它当平面：它与 z 轴方向的直线的交点在切平面上。
        guard case let .plane(n, c)? = SpaceGeometry.recognize(all[1], in: all) else { return XCTFail("应是平面") }
        XCTAssertEqual(simd_dot(n, SIMD3(1, 2, 2)), c, accuracy: 1e-6)
        XCTAssertNil(SpaceGeometry.recognize(all[1]), "单个图层看不到来源，认不出")

        let built = SceneBuilder3D.build(SceneBuild3DRequest(
            document: { var d = GrapherDocument(dimension: .space); d.layers = [saddle, tangent]; return d }(),
            compiled: all, view: .standard, quality: .interactive, backingScale: 2))
        let ownMeshes = built.scene.meshes.filter { $0.layerID == tangent.id }
        XCTAssertEqual(ownMeshes.count, 2, "方片和切点小球")
        let patch = try XCTUnwrap(ownMeshes.first)
        XCTAssertTrue(patch.isTranslucent)
        // 方片的四个角都在切平面上。
        for vertex in patch.vertices {
            let p = built.view.data(SIMD3<Double>(vertex.position))
            XCTAssertEqual(simd_dot(n, p), c, accuracy: 1e-4)
        }
        XCTAssertEqual(built.scene.polylines.filter { $0.layerID == tangent.id }.count, 2, "边框和法线")
    }

    func testTangentPlaneCanBeAProjectionTarget() throws {
        // 把点 (1,2,5) 投到 z = 1 处水平的切平面上（z = x² + y² 在原点处）：落在 (1,2,0)。
        let bowl = layer(.surface, "x^2 + y^2")
        var tangent = Layer.makeDefault(kind: .tangentPlane, index: 1)
        tangent.sourceA = bowl.id
        var point = Layer.makeDefault(kind: .point, index: 2)
        point.formula = "1"; point.secondaryFormula = "2"; point.tertiaryFormula = "5"
        point.isVisible = false
        var shadow = Layer.makeDefault(kind: .projection, index: 3)
        shadow.sourceA = point.id
        shadow.projectionTarget = .plane
        shadow.sourceB = tangent.id
        shadow.showsProjectors = false
        var document = GrapherDocument(dimension: .space)
        document.layers = [bowl, tangent, point, shadow]
        let built = SceneBuilder3D.build(SceneBuild3DRequest(
            document: document, compiled: LayerCompiler().compile(document),
            view: .standard, quality: .interactive, backingScale: 2))
        let sphere = try XCTUnwrap(built.scene.meshes.last { $0.layerID == shadow.id })
        let centre = sphere.vertices.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(sphere.vertices.count)
        let data = built.view.data(SIMD3<Double>(centre))
        XCTAssertEqual(data.x, 1, accuracy: 0.03)
        XCTAssertEqual(data.y, 2, accuracy: 0.03)
        XCTAssertEqual(data.z, 0, accuracy: 0.03)
    }

    func testTangentFieldsSurviveCodableAndOldFilesStillOpen() throws {
        var layer = Layer.makeDefault(kind: .tangentPlane, index: 0)
        layer.anchorU = 1.5
        layer.anchorV = -2
        layer.drawsNormal = true
        let data = try JSONEncoder().encode(layer)
        XCTAssertEqual(try JSONDecoder().decode(Layer.self, from: data), layer)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["anchorU", "anchorV", "drawsNormal"] { object.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(Layer.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.anchorU, 0)
        XCTAssertEqual(old.anchorV, 0)
        XCTAssertFalse(old.drawsNormal)
    }
}
