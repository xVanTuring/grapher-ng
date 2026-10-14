import simd
import XCTest
@testable import GrapherKit

/// 梯度场：数值梯度、箭头方向 / 长度 / 颜色、极值点没有箭头、图层的存取与来源检查。
final class GradientTests: XCTestCase {

    private func compile(_ formula: String) throws -> CompiledExpression {
        try CompiledExpression(source: formula, context: ExpressionContext(variables: ["x", "y"]))
    }

    func testGradientMatchesTheAnalyticDerivative() throws {
        let f = try compile("x^2*y + sin(y)")
        let g = try XCTUnwrap(GradientField.gradient(of: f, x: 1.5, y: 0.7))
        XCTAssertEqual(g.x, 2 * 1.5 * 0.7, accuracy: 1e-6)
        XCTAssertEqual(g.y, 1.5 * 1.5 + cos(0.7), accuracy: 1e-6)
        XCTAssertNil(GradientField.gradient(of: try compile("sqrt(x)"), x: -1, y: 0), "没定义的地方没有梯度")
    }

    /// z = x²：在 x > 0 的地方指向 +x 方向且往上（最陡上升），x = 0 的一排没有箭头；越靠外越陡，颜色越暖。
    func testArrowsPointUphillAndSkipTheFlatLine() throws {
        let f = try compile("x^2")
        let arrows = GradientField.arrows(of: f, center: .zero, halfExtent: 4, density: 8, scale: 1, onFloor: false)
        XCTAssertEqual(arrows.count, 8 * 8, "x = ±0.5 … ±3.5 共 8 列，没有恰好在 x = 0 的一列")
        for arrow in arrows {
            let d = arrow.tip - arrow.origin
            XCTAssertEqual(d.x.sign, arrow.origin.x.sign, "箭头水平分量指向离开 x = 0 的方向")
            XCTAssertEqual(d.y, 0, accuracy: 1e-12)
            XCTAssertGreaterThan(d.z, 0, "沿曲面往上")
            // 切向：与曲面法向 (−2x, 0, 1) 垂直。
            XCTAssertEqual(simd_dot(d, SIMD3(-2 * arrow.origin.x, 0, 1)), 0, accuracy: 1e-9)
            XCTAssertEqual(arrow.magnitude, 2 * abs(arrow.origin.x), accuracy: 1e-6)
        }
        let strongest = try XCTUnwrap(arrows.max { $0.magnitude < $1.magnitude })
        XCTAssertEqual(strongest.level, 1, accuracy: 1e-12)
        let weakest = try XCTUnwrap(arrows.min { $0.magnitude < $1.magnitude })
        XCTAssertLessThan(weakest.level, 0.2)
        // 越陡箭头越长。
        XCTAssertGreaterThan(simd_length(strongest.tip - strongest.origin), simd_length(weakest.tip - weakest.origin))
    }

    func testNoArrowsAtPeaksOrOnFlatGround() throws {
        XCTAssertTrue(GradientField.arrows(of: try compile("3"), center: .zero, halfExtent: 4, density: 6, scale: 1, onFloor: false).isEmpty)
        // 山顶 z = −x² − y² 在原点：格子中心都不在原点，只有中心的四个格子梯度小但不为 0，都有箭头；原点本身没有。
        let hill = GradientField.arrows(of: try compile("-(x^2 + y^2)"), center: .zero, halfExtent: 4, density: 7, scale: 1, onFloor: false)
        XCTAssertEqual(hill.count, 48, "7×7 里正中那一格正好在原点，梯度为 0，没有箭头")
        XCTAssertFalse(hill.contains { simd_length($0.origin - SIMD3(0, 0, 0)) < 1e-9 })
    }

    func testFloorModeLiesFlatAndUsesTheGradientItself() throws {
        let f = try compile("x*y")
        let arrows = GradientField.arrows(of: f, center: SIMD3(0, 0, 1), halfExtent: 4, density: 6, scale: 1, onFloor: true)
        XCTAssertFalse(arrows.isEmpty)
        let floor = 1.0 - 4.0 + 0.08
        for arrow in arrows {
            XCTAssertEqual(arrow.origin.z, floor, accuracy: 1e-12)
            XCTAssertEqual(arrow.tip.z, floor, accuracy: 1e-12, "平放")
            // ∇(xy) = (y, x)：箭头方向与它同向。
            let d = simd_normalize(SIMD2(arrow.tip.x - arrow.origin.x, arrow.tip.y - arrow.origin.y))
            let g = simd_normalize(SIMD2(arrow.origin.y, arrow.origin.x))
            XCTAssertEqual(simd_length(d - g), 0, accuracy: 1e-6)
        }
    }

    func testNegativeScaleDrawsDownhill() throws {
        let f = try compile("x^2 + y^2")
        let up = GradientField.arrows(of: f, center: .zero, halfExtent: 4, density: 4, scale: 1, onFloor: true)
        let down = GradientField.arrows(of: f, center: .zero, halfExtent: 4, density: 4, scale: -1, onFloor: true)
        XCTAssertEqual(up.count, down.count)
        for (a, b) in zip(up, down) {
            XCTAssertEqual(simd_length((a.tip - a.origin) + (b.tip - b.origin)), 0, accuracy: 1e-9, "方向相反、长度相同")
        }
    }

    func testColormapRunsFromCoolToWarm() {
        let low = GradientField.color(level: 0)
        let high = GradientField.color(level: 1)
        XCTAssertGreaterThan(low.b, low.r)
        XCTAssertGreaterThan(high.r, high.b)
        XCTAssertEqual(GradientField.color(level: -3), low)
        XCTAssertEqual(GradientField.color(level: 9), high)
    }

    func testGradientLayerDrawsArrowsInTheScene() throws {
        var surface = Layer.makeDefault(kind: .surface, index: 0)
        surface.formula = "x*y/4"
        var field = Layer.makeDefault(kind: .gradientField, index: 1)
        field.sourceA = surface.id
        field.gridDensity = 6
        var document = GrapherDocument(dimension: .space)
        document.layers = [surface, field]
        func build() -> BuiltScene3D {
            SceneBuilder3D.build(SceneBuild3DRequest(
                document: document, compiled: LayerCompiler().compile(document), view: .standard,
                quality: .interactive, backingScale: 1))
        }
        var built = build()
        let own = built.scene.polylines.filter { $0.layerID == field.id }
        XCTAssertEqual(own.count, 36 - 0, "6×6 个格子，没有恰好落在 xy = 0 的格点：每格一支箭头")
        XCTAssertEqual(own.first?.points.count, 5)

        // 来源不是显式曲面、或者被删掉：什么都不画。
        document.layers[1].sourceA = UUID()
        built = build()
        XCTAssertTrue(built.scene.polylines.filter { $0.layerID == field.id }.isEmpty)
    }

    func testGradientFieldFollowsParameters() throws {
        var surface = Layer.makeDefault(kind: .surface, index: 0)
        surface.formula = "s*x"
        var field = Layer.makeDefault(kind: .gradientField, index: 1)
        field.sourceA = surface.id
        field.gridDensity = 4
        field.gradientOnFloor = true
        var document = GrapherDocument(dimension: .space)
        document.parameters = [ParameterDefinition(name: "s", value: 1)]
        document.layers = [surface, field]
        func magnitudes() -> [Double] {
            let compiled = LayerCompiler().compile(document)
            return GradientField.arrows(
                of: compiled[0].primary!, center: .zero, halfExtent: 4, density: 4, scale: 1, onFloor: true).map(\.magnitude)
        }
        XCTAssertEqual(magnitudes().first ?? 0, 1, accuracy: 1e-6)
        document.parameters[0].value = 3
        XCTAssertEqual(magnitudes().first ?? 0, 3, accuracy: 1e-6)
    }

    func testGradientFieldsSurviveCodableAndOldFilesStillOpen() throws {
        var layer = Layer.makeDefault(kind: .gradientField, index: 0)
        layer.gridDensity = 20
        layer.arrowScale = -1.5
        layer.gradientOnFloor = true
        let data = try JSONEncoder().encode(layer)
        XCTAssertEqual(try JSONDecoder().decode(Layer.self, from: data), layer)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["gridDensity", "arrowScale", "gradientOnFloor"] { object.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(Layer.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.gridDensity, 12)
        XCTAssertEqual(old.arrowScale, 1)
        XCTAssertFalse(old.gradientOnFloor)
    }
}

/// 曲面按坡度上色：标量的数值、网格带标量、真的渲染成「平缓蓝、陡处红」。
final class SlopeColoringTests: XCTestCase {

    func testSlopeLevelsOfRampsAndBowls() {
        let n = 21, step = 0.5
        // 斜面 z = 2x：坡度处处相同，归一化后都是 1。
        let ramp = (0..<n * n).map { 2 * Double($0 % n) * step }
        XCTAssertTrue(SceneBuilder3D.slopeLevels(ramp, n: n, step: step).allSatisfy { abs($0 - 1) < 1e-6 })
        // 碗 z = x²：中心 0，越往外越大。
        let bowl = (0..<n * n).map { index -> Double in
            let x = (Double(index % n) - 10) * step
            return x * x
        }
        let levels = SceneBuilder3D.slopeLevels(bowl, n: n, step: step)
        XCTAssertEqual(levels[10 * n + 10], 0, accuracy: 1e-6, "碗底平")
        XCTAssertGreaterThan(levels[10 * n + 20], levels[10 * n + 15])
        XCTAssertTrue(levels.allSatisfy { (0...1).contains($0) })
        XCTAssertTrue(SceneBuilder3D.slopeLevels([], n: 0, step: 1).isEmpty)
        // 有无穷大的点（极点）不把别处压成全蓝：夹在 0…1 里且没有 NaN。
        var poles = ramp
        poles[5 * n + 5] = .infinity
        XCTAssertTrue(SceneBuilder3D.slopeLevels(poles, n: n, step: step).allSatisfy { $0.isFinite && $0 <= 1 })
    }

    func testSlopeColoringMarksTheMeshAndRoundTrips() throws {
        var layer = Layer.makeDefault(kind: .surface, index: 0)
        layer.formula = "x^2/8"
        layer.colorsBySlope = true
        var document = GrapherDocument(dimension: .space)
        document.layers = [layer]
        func mesh() throws -> Mesh3D {
            try XCTUnwrap(SceneBuilder3D.build(SceneBuild3DRequest(
                document: document, compiled: LayerCompiler().compile(document), view: .standard,
                quality: .interactive, backingScale: 1)).scene.meshes.first)
        }
        let colored = try mesh()
        XCTAssertTrue(colored.colorsByScalar)
        XCTAssertGreaterThan(colored.vertices.map(\.scalar).max() ?? 0, 0.9)
        XCTAssertEqual(colored.vertices.map(\.scalar).min() ?? 1, 0, accuracy: 0.05)
        document.layers[0].colorsBySlope = false
        XCTAssertFalse(try mesh().colorsByScalar)

        let data = try JSONEncoder().encode(layer)
        XCTAssertEqual(try JSONDecoder().decode(Layer.self, from: data), layer)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "colorsBySlope")
        XCTAssertFalse(try JSONDecoder().decode(Layer.self, from: JSONSerialization.data(withJSONObject: object)).colorsBySlope)
    }
}
