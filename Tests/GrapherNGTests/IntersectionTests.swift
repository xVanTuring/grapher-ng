import simd
import XCTest
@testable import GrapherKit

/// 两曲面交线：不同图型组合的几何精度、拼接成折线、来源缺失 / 隐藏时的行为。
/// 默认坐标盒 ±4，归一化坐标 = 数据坐标 / 4。
final class IntersectionTests: XCTestCase {

    private func surface(_ kind: PlotKind, _ formula: String, secondary: String = "", tertiary: String = "",
                         visible: Bool = true) -> Layer {
        var layer = Layer.makeDefault(kind: kind, index: 0)
        layer.formula = formula
        if !secondary.isEmpty { layer.secondaryFormula = secondary }
        if !tertiary.isEmpty { layer.tertiaryFormula = tertiary }
        layer.isVisible = visible
        return layer
    }

    private func intersection(_ a: Layer, _ b: Layer) -> Layer {
        var layer = Layer.makeDefault(kind: .surfaceIntersection, index: 2)
        layer.sourceA = a.id
        layer.sourceB = b.id
        return layer
    }

    /// 只取交线图层画出的折线（数据坐标）。
    private func curves(_ layers: [Layer], quality: SampleQuality = .full) -> [[SIMD3<Double>]] {
        var document = GrapherDocument(dimension: .space)
        document.layers = layers
        let built = SceneBuilder3D.build(SceneBuild3DRequest(
            document: document, compiled: LayerCompiler().compile(document),
            view: .standard, quality: quality, backingScale: 2))
        return built.scene.polylines.map { line in
            line.points.map { built.view.data(SIMD3<Double>($0)) }
        }
    }

    private func length(_ line: [SIMD3<Double>]) -> Double {
        (1..<line.count).reduce(0) { $0 + simd_length(line[$1] - line[$1 - 1]) }
    }

    // MARK: - 几何

    /// 球面 x²+y²+z²=4 与平面 z=1：半径 √3、在 z=1 的一个圆。
    func testSphereCutByPlaneIsOneCircle() throws {
        let sphere = surface(.implicitSurface, "x^2 + y^2 + z^2 - 4")
        let plane = surface(.surface, "1")
        let lines = curves([sphere, plane, intersection(sphere, plane)])
        XCTAssertEqual(lines.count, 1, "一个圆拼成一条折线")
        let line = try XCTUnwrap(lines.first)
        XCTAssertEqual(line.first!.x, line.last!.x, accuracy: 1e-4, "闭合")
        XCTAssertEqual(line.first!.y, line.last!.y, accuracy: 1e-4)
        for p in line {
            XCTAssertEqual(p.z, 1, accuracy: 0.01)
            XCTAssertEqual(simd_length(SIMD2(p.x, p.y)), 3.0.squareRoot(), accuracy: 0.02)
        }
        XCTAssertEqual(length(line), 2 * Double.pi * 3.0.squareRoot(), accuracy: 0.1)
    }

    /// 参数球面与显式曲面：两种图型走同一条路。
    func testParametricSphereCutByExplicitPlane() throws {
        let sphere = surface(.parametricSurface, "2*cos(u)*sin(v)", secondary: "2*sin(u)*sin(v)", tertiary: "2*cos(v)")
        var domain = sphere
        domain.domainLower = 0
        domain.domainUpper = 2 * Double.pi
        domain.domain2Lower = 0
        domain.domain2Upper = Double.pi
        let plane = surface(.surface, "1")
        let lines = curves([domain, plane, intersection(domain, plane)])
        XCTAssertEqual(lines.count, 1)
        for p in try XCTUnwrap(lines.first) {
            XCTAssertEqual(p.z, 1, accuracy: 0.01)
            XCTAssertEqual(simd_length(SIMD2(p.x, p.y)), 3.0.squareRoot(), accuracy: 0.02)
        }
    }

    /// 柱面 x²+y²=4 穿过球面 x²+y²+z²=9：上下两个圆。
    func testCylinderThroughSphereGivesTwoCircles() throws {
        let cylinder = surface(.implicitSurface, "x^2 + y^2 - 4")
        let sphere = surface(.implicitSurface, "x^2 + y^2 + z^2 - 9")
        let lines = curves([cylinder, sphere, intersection(cylinder, sphere)])
        XCTAssertEqual(lines.count, 2)
        let heights = lines.map { $0[0].z }.sorted()
        XCTAssertEqual(heights[0], -5.0.squareRoot(), accuracy: 0.03)
        XCTAssertEqual(heights[1], 5.0.squareRoot(), accuracy: 0.03)
        for line in lines {
            for p in line { XCTAssertEqual(simd_length(SIMD2(p.x, p.y)), 2, accuracy: 0.03) }
        }
    }

    /// 两张相交的平面：z = x 与 z = -x 交在 x = 0, z = 0 这条线上，穿过整个盒子。
    func testTwoPlanesMeetInALineThroughTheBox() throws {
        let a = surface(.surface, "x")
        let b = surface(.surface, "-x")
        let lines = curves([a, b, intersection(a, b)])
        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        for p in line {
            XCTAssertEqual(p.x, 0, accuracy: 1e-3)
            XCTAssertEqual(p.z, 0, accuracy: 1e-3)
        }
        XCTAssertEqual(length(line), 8, accuracy: 0.05, "盒子 y 方向的全长")
    }

    /// 交线在盒外的部分不画：球面比盒子大，截面圆只有一部分在盒里。
    func testCurveIsClippedToTheBox() throws {
        let sphere = surface(.implicitSurface, "x^2 + y^2 + z^2 - 25")
        let plane = surface(.surface, "0")
        let lines = curves([sphere, plane, intersection(sphere, plane)])
        XCTAssertFalse(lines.isEmpty)
        for p in lines.joined() {
            XCTAssertLessThanOrEqual(abs(p.x), 4.01)
            XCTAssertLessThanOrEqual(abs(p.y), 4.01)
        }
    }

    func testRefinedQualityTracksTheTrueCurveMoreClosely() throws {
        let sphere = surface(.implicitSurface, "x^2 + y^2 + z^2 - 4")
        let plane = surface(.surface, "1")
        func worstError(_ quality: SampleQuality) throws -> Double {
            let lines = curves([sphere, plane, intersection(sphere, plane)], quality: quality)
            return try XCTUnwrap(lines.first).map { abs(simd_length(SIMD2($0.x, $0.y)) - 3.0.squareRoot()) }.max() ?? 0
        }
        XCTAssertLessThan(try worstError(.high), try worstError(.interactive))
    }

    // MARK: - 图层关系

    /// 来源图层藏起来，交线照样画（画出来的只有这条线）。
    func testHiddenSourcesStillGiveTheCurve() {
        let sphere = surface(.implicitSurface, "x^2 + y^2 + z^2 - 4", visible: false)
        let plane = surface(.surface, "1", visible: false)
        var document = GrapherDocument(dimension: .space)
        document.layers = [sphere, plane, intersection(sphere, plane)]
        let built = SceneBuilder3D.build(SceneBuild3DRequest(
            document: document, compiled: LayerCompiler().compile(document),
            view: .standard, quality: .full, backingScale: 2))
        XCTAssertTrue(built.scene.meshes.isEmpty)
        XCTAssertEqual(built.scene.polylines.count, 1)
        XCTAssertNotNil(built.fitBounds)
    }

    func testMissingOrIdenticalOrWrongKindSourcesDrawNothing() {
        let sphere = surface(.implicitSurface, "x^2 + y^2 + z^2 - 4")
        let plane = surface(.surface, "1")
        let curve = surface(.spaceCurve, "cos(t)", secondary: "sin(t)", tertiary: "t")

        var missing = intersection(sphere, plane)
        missing.sourceB = UUID()
        XCTAssertTrue(curves([sphere, plane, missing]).isEmpty, "来源已被删掉")

        XCTAssertTrue(curves([sphere, plane, intersection(sphere, sphere)]).isEmpty, "两个来源是同一个")
        XCTAssertEqual(curves([sphere, curve, intersection(sphere, curve)]).count, 1, "空间曲线不是曲面：只剩它自己那一条")

        var unset = intersection(sphere, plane)
        unset.sourceA = nil
        XCTAssertTrue(curves([sphere, plane, unset]).isEmpty, "没选满")
    }

    func testBrokenSourceFormulaDrawsNothing() {
        let sphere = surface(.implicitSurface, "x^2 + y^2 + z^2 - 4")
        let broken = surface(.surface, "1 +")
        XCTAssertTrue(curves([sphere, broken, intersection(sphere, broken)]).isEmpty)
    }

    func testIntersectionLayerNeedsNoFormula() {
        var document = GrapherDocument(dimension: .space)
        document.layers = [intersection(surface(.surface, "1"), surface(.surface, "2"))]
        let compiled = LayerCompiler().compile(document)
        XCTAssertFalse(compiled[0].hasError, "没有公式也不该报公式错")
        XCTAssertEqual(PlotKind.surfaceIntersection.dimension, .space)
        XCTAssertTrue(PlotKind.cases(for: .space).contains(.surfaceIntersection))
        XCTAssertFalse(PlotKind.cases(for: .plane).contains(.surfaceIntersection))
    }

    // MARK: - 存档

    func testSourcesSurviveACodableRoundTripAndOldFilesStillOpen() throws {
        let a = surface(.surface, "1")
        let b = surface(.surface, "2")
        let layer = intersection(a, b)
        let data = try JSONEncoder().encode(layer)
        let decoded = try JSONDecoder().decode(Layer.self, from: data)
        XCTAssertEqual(decoded.sourceA, a.id)
        XCTAssertEqual(decoded.sourceB, b.id)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "sourceA")
        object.removeValue(forKey: "sourceB")
        let old = try JSONDecoder().decode(Layer.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.sourceA)
        XCTAssertNil(old.sourceB)
    }

    // MARK: - 拼接

    func testStitchJoinsSegmentsIntoOneOpenPolylineAndClosesLoops() {
        func seg(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> MeshIntersection.Segment { .init(p: a, q: b) }
        // 打乱顺序、方向不一致的一条直线（三段）。
        let open = MeshIntersection.stitch([
            seg(SIMD3(0.5, 0, 0), SIMD3(0.25, 0, 0)),
            seg(SIMD3(0, 0, 0), SIMD3(0.25, 0, 0)),
            seg(SIMD3(0.5, 0, 0), SIMD3(0.75, 0, 0)),
        ])
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open[0].count, 4)

        let loop = MeshIntersection.stitch([
            seg(SIMD3(0, 0, 0), SIMD3(0.5, 0, 0)),
            seg(SIMD3(0.5, 0, 0), SIMD3(0.5, 0.5, 0)),
            seg(SIMD3(0.5, 0.5, 0), SIMD3(0, 0, 0)),
        ])
        XCTAssertEqual(loop.count, 1)
        XCTAssertEqual(loop[0].first, loop[0].last, "环首尾相接")
    }
}
