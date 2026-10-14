import simd
import XCTest
@testable import GrapherKit

/// 点线面：从图层认出几何对象，以及各种两两关系的距离、夹角、垂足、交点 / 交线。
final class SpaceGeometryTests: XCTestCase {

    private func recognize(_ layer: Layer) -> SpaceObject? {
        var document = GrapherDocument(dimension: .space)
        document.layers = [layer]
        return SpaceGeometry.recognize(LayerCompiler().compile(document)[0])
    }

    private func point(_ x: String, _ y: String, _ z: String) -> Layer {
        var layer = Layer.makeDefault(kind: .point, index: 0)
        layer.formula = x
        layer.secondaryFormula = y
        layer.tertiaryFormula = z
        return layer
    }

    private func curve(_ x: String, _ y: String, _ z: String) -> Layer {
        var layer = Layer.makeDefault(kind: .spaceCurve, index: 0)
        layer.formula = x
        layer.secondaryFormula = y
        layer.tertiaryFormula = z
        layer.domainLower = -5
        layer.domainUpper = 5
        return layer
    }

    private func plane(_ f: String) -> Layer {
        var layer = Layer.makeDefault(kind: .implicitSurface, index: 0)
        layer.formula = f
        return layer
    }

    private func assertEqual(_ a: SIMD3<Double>, _ b: SIMD3<Double>, accuracy: Double = 1e-9,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(simd_length(a - b), 0, accuracy: accuracy, "\(a) ≠ \(b)", file: file, line: line)
    }

    private func measure(_ relation: GeometryRelation, _ name: String) -> Double? {
        relation.measures.first { $0.name == name }?.value
    }

    // MARK: - 识别

    func testRecognizesPointsLinesAndPlanes() throws {
        XCTAssertEqual(recognize(point("1", "2", "3")), .point(SIMD3(1, 2, 3)))

        // 直线 (1,2,3) + t(1,2,2)。
        guard case let .line(origin, direction)? = recognize(curve("1 + t", "2 + 2*t", "3 + 2*t")) else {
            return XCTFail("应识别为直线")
        }
        XCTAssertEqual(simd_length(direction), 1, accuracy: 1e-12)
        assertEqual(direction, SIMD3(1, 2, 2) / 3)
        // 原点取 t = 定义域下端 -5，在直线上。
        XCTAssertEqual(simd_length(simd_cross(origin - SIMD3(1, 2, 3), direction)), 0, accuracy: 1e-9)

        // 平面 x + 2y + 2z = 6：单位法向 (1,2,2)/3，偏移 2。
        guard case let .plane(normal, offset)? = recognize(plane("x + 2*y + 2*z - 6")) else {
            return XCTFail("应识别为平面")
        }
        assertEqual(normal, SIMD3(1, 2, 2) / 3)
        XCTAssertEqual(offset, 2, accuracy: 1e-12)

        // 显式曲面 z = 0.5x - y + 3：F = 0.5x - y - z + 3。
        var explicit = Layer.makeDefault(kind: .surface, index: 0)
        explicit.formula = "0.5*x - y + 3"
        guard case let .plane(n2, c2)? = recognize(explicit) else { return XCTFail("显式平面") }
        XCTAssertEqual(simd_dot(n2, SIMD3(0, 0, 3)), c2, accuracy: 1e-12, "(0,0,3) 在平面上")
        XCTAssertEqual(simd_dot(n2, SIMD3(2, 0, 4)), c2, accuracy: 1e-12, "(2,0,4) 在平面上")
    }

    func testRejectsNonLinearObjects() {
        XCTAssertNil(recognize(curve("cos(t)", "sin(t)", "t")), "螺旋线不是直线")
        XCTAssertNil(recognize(plane("x^2 + y^2 + z^2 - 4")), "球面不是平面")
        XCTAssertNil(recognize(plane("x*y - z")), "双曲抛物面不是平面")
        XCTAssertNil(recognize(plane("4")), "常数没有法向")
        XCTAssertNil(recognize(point("x", "1", "1")), "点的公式不能有变量")
    }

    func testPointsFollowParameters() {
        var document = GrapherDocument(dimension: .space)
        document.parameters = [ParameterDefinition(name: "a", value: 3)]
        document.layers = [point("a", "2*a", "-a")]
        XCTAssertEqual(SpaceGeometry.recognize(LayerCompiler().compile(document)[0]), .point(SIMD3(3, 6, -3)))
    }

    func testPointLayerDrawsASphereAtItsPosition() throws {
        var document = GrapherDocument(dimension: .space)
        document.layers = [point("2", "-1", "4")]
        let built = SceneBuilder3D.build(SceneBuild3DRequest(
            document: document, compiled: LayerCompiler().compile(document),
            view: .standard, quality: .interactive, backingScale: 2))
        let mesh = try XCTUnwrap(built.scene.meshes.first)
        XCTAssertGreaterThan(mesh.triangleCount, 100)
        let sum = mesh.vertices.reduce(SIMD3<Float>.zero) { $0 + $1.position }
        let center = sum / Float(mesh.vertices.count)
        XCTAssertEqual(center.x, 0.5, accuracy: 0.01, "x = 2 在默认盒 ±4 里归一化为 0.5")
        XCTAssertEqual(center.y, -0.25, accuracy: 0.01)
        XCTAssertEqual(center.z, 1, accuracy: 0.01)
        XCTAssertNotNil(built.fitBounds)
    }

    func testPointLabelsAreFilteredByVisibilityToggleAndBox() {
        var shown = point("1", "2", "3"); shown.name = "A"
        var hiddenName = point("0", "0", "0"); hiddenName.name = "B"; hiddenName.showsLabel = false
        var hiddenLayer = point("0", "1", "0"); hiddenLayer.name = "C"; hiddenLayer.isVisible = false
        var outside = point("100", "0", "0"); outside.name = "D"
        var surface = Layer.makeDefault(kind: .surface, index: 0); surface.formula = "0"
        var document = GrapherDocument(dimension: .space)
        document.layers = [shown, hiddenName, hiddenLayer, outside, surface]
        let labels = SpaceGeometry.pointLabels(in: LayerCompiler().compile(document), view: .standard)
        XCTAssertEqual(labels.map(\.name), ["A"])
        XCTAssertEqual(labels.first?.position, SIMD3(1, 2, 3))
    }

    // MARK: - 点

    func testPointToPlaneDistanceAndFoot() throws {
        let relation = SpaceGeometry.relation(.point(SIMD3(1, 1, 5)), .plane(normal: SIMD3(0, 0, 1), offset: 2))
        XCTAssertEqual(measure(relation, "距离"), 3)
        guard case let .point(foot, _)? = relation.constructions.first else { return XCTFail() }
        assertEqual(foot, SIMD3(1, 1, 2))
        // 点在平面内。
        let on = SpaceGeometry.relation(.point(SIMD3(1, 1, 2)), .plane(normal: SIMD3(0, 0, 1), offset: 2))
        XCTAssertEqual(on.summary, "点在平面内。")
        XCTAssertTrue(on.constructions.isEmpty)
    }

    func testPointToLine() throws {
        let line = SpaceObject.line(origin: .zero, direction: SIMD3(1, 0, 0))
        let relation = SpaceGeometry.relation(.point(SIMD3(4, 3, 0)), line)
        XCTAssertEqual(measure(relation, "距离"), 3)
        guard case let .point(foot, _)? = relation.constructions.first else { return XCTFail() }
        assertEqual(foot, SIMD3(4, 0, 0))
        // 顺序无关。
        XCTAssertEqual(SpaceGeometry.relation(line, .point(SIMD3(4, 3, 0))), relation)
    }

    func testPointToPoint() {
        let relation = SpaceGeometry.relation(.point(SIMD3(0, 0, 0)), .point(SIMD3(1, 2, 2)))
        XCTAssertEqual(measure(relation, "距离"), 3)
        XCTAssertEqual(relation.constructions.count, 2, "线段与中点")
    }

    // MARK: - 直线与直线

    func testSkewLines() throws {
        // x 轴与过 (0,0,1) 沿 y 的直线：异面，距离 1，公垂线段连 (0,0,0)–(0,0,1)。
        let a = SpaceObject.line(origin: .zero, direction: SIMD3(1, 0, 0))
        let b = SpaceObject.line(origin: SIMD3(0, 5, 1), direction: SIMD3(0, 1, 0))
        let relation = SpaceGeometry.relation(a, b)
        XCTAssertEqual(relation.summary, "两直线异面。")
        XCTAssertEqual(measure(relation, "距离") ?? 0, 1, accuracy: 1e-12)
        XCTAssertEqual(measure(relation, "夹角") ?? 0, 90, accuracy: 1e-9)
        guard case let .segment(p, q, _)? = relation.constructions.first else { return XCTFail() }
        assertEqual(p, SIMD3(0, 0, 0))
        assertEqual(q, SIMD3(0, 0, 1))
    }

    func testIntersectingParallelAndCoincidentLines() throws {
        let x = SpaceObject.line(origin: .zero, direction: SIMD3(1, 0, 0))
        let diagonal = SpaceObject.line(origin: SIMD3(2, 0, 0), direction: simd_normalize(SIMD3(1, 1, 0)))
        let crossing = SpaceGeometry.relation(x, diagonal)
        XCTAssertEqual(crossing.summary, "两直线相交。")
        XCTAssertEqual(measure(crossing, "夹角") ?? 0, 45, accuracy: 1e-9)
        guard case let .point(p, _)? = crossing.constructions.first else { return XCTFail() }
        assertEqual(p, SIMD3(2, 0, 0))

        let parallel = SpaceGeometry.relation(x, .line(origin: SIMD3(0, 3, 4), direction: SIMD3(-1, 0, 0)))
        XCTAssertEqual(parallel.summary, "两直线平行。")
        XCTAssertEqual(measure(parallel, "距离") ?? 0, 5, accuracy: 1e-12)

        let same = SpaceGeometry.relation(x, .line(origin: SIMD3(7, 0, 0), direction: SIMD3(1, 0, 0)))
        XCTAssertEqual(same.summary, "两直线重合。")
    }

    // MARK: - 直线与平面

    func testLineAndPlane() throws {
        let floor = SpaceObject.plane(normal: SIMD3(0, 0, 1), offset: 0)

        let slanted = SpaceGeometry.relation(
            .line(origin: SIMD3(0, 0, 2), direction: simd_normalize(SIMD3(1, 0, -1))), floor)
        XCTAssertEqual(slanted.summary, "直线与平面相交于一点。")
        XCTAssertEqual(measure(slanted, "夹角") ?? 0, 45, accuracy: 1e-9)
        guard case let .point(hit, _)? = slanted.constructions.first else { return XCTFail() }
        assertEqual(hit, SIMD3(2, 0, 0))

        let upright = SpaceGeometry.relation(.line(origin: SIMD3(1, 1, 1), direction: SIMD3(0, 0, 1)), floor)
        XCTAssertEqual(upright.summary, "直线与平面垂直。")
        XCTAssertEqual(measure(upright, "夹角") ?? 0, 90, accuracy: 1e-9)

        let parallel = SpaceGeometry.relation(.line(origin: SIMD3(0, 0, 4), direction: SIMD3(1, 1, 0) / 2.0.squareRoot()), floor)
        XCTAssertEqual(parallel.summary, "直线与平面平行。")
        XCTAssertEqual(measure(parallel, "距离"), 4)

        let inside = SpaceGeometry.relation(.line(origin: SIMD3(3, 0, 0), direction: SIMD3(0, 1, 0)), floor)
        XCTAssertEqual(inside.summary, "直线在平面内。")
    }

    // MARK: - 平面与平面

    func testPlanesMeetInALine() throws {
        // z = 0 与 x = 0：交线是 y 轴。
        let relation = SpaceGeometry.relation(
            .plane(normal: SIMD3(0, 0, 1), offset: 0), .plane(normal: SIMD3(1, 0, 0), offset: 0))
        XCTAssertEqual(relation.summary, "两平面垂直。")
        XCTAssertEqual(measure(relation, "二面角") ?? 0, 90, accuracy: 1e-9)
        guard case let .line(origin, direction, _)? = relation.constructions.first else { return XCTFail() }
        XCTAssertEqual(abs(direction.y), 1, accuracy: 1e-12)
        XCTAssertEqual(simd_length(simd_cross(origin, direction)), 0, accuracy: 1e-12, "交线过原点")
    }

    func testIntersectionLineLiesInBothPlanes() throws {
        let n1 = simd_normalize(SIMD3<Double>(1, 2, 3))
        let n2 = simd_normalize(SIMD3<Double>(-2, 1, 1))
        let relation = SpaceGeometry.relation(.plane(normal: n1, offset: 1.5), .plane(normal: n2, offset: -0.5))
        XCTAssertEqual(relation.summary, "两平面相交于一条直线。")
        guard case let .line(origin, direction, _)? = relation.constructions.first else { return XCTFail() }
        for t in [-3.0, 0, 2.5] {
            let p = origin + direction * t
            XCTAssertEqual(simd_dot(n1, p), 1.5, accuracy: 1e-9)
            XCTAssertEqual(simd_dot(n2, p), -0.5, accuracy: 1e-9)
        }
        XCTAssertEqual(measure(relation, "二面角") ?? 0, acos(abs(simd_dot(n1, n2))) * 180 / .pi, accuracy: 1e-9)
    }

    func testParallelAndCoincidentPlanes() {
        let a = SpaceObject.plane(normal: SIMD3(0, 0, 1), offset: 1)
        // 法向反着写的 z = 4 也是平行平面。
        let parallel = SpaceGeometry.relation(a, .plane(normal: SIMD3(0, 0, -1), offset: -4))
        XCTAssertEqual(parallel.summary, "两平面平行。")
        XCTAssertEqual(measure(parallel, "距离") ?? 0, 3, accuracy: 1e-12)
        XCTAssertEqual(SpaceGeometry.relation(a, .plane(normal: SIMD3(0, 0, -1), offset: -1)).summary, "两平面重合。")
    }

    /// 「画出结果」生成的图层，再被 `recognize` 认回原来的对象。
    func testConstructionLayersRecognizeBackAsTheSameObjects() throws {
        let point = GeometryConstruction.point(SIMD3(1.5, -2, 0.25), name: "P")
        XCTAssertEqual(recognize(point.makeLayer(index: 0, lineExtent: 10)), .point(SIMD3(1.5, -2, 0.25)))
        XCTAssertEqual(point.makeLayer(index: 0, lineExtent: 10).name, "P")

        let line = GeometryConstruction.line(origin: SIMD3(1, 2, 3), direction: SIMD3(0, 0.6, 0.8), name: "L")
        guard case let .line(origin, direction)? = recognize(line.makeLayer(index: 1, lineExtent: 10)) else {
            return XCTFail("应认回直线")
        }
        assertEqual(direction, SIMD3(0, 0.6, 0.8))
        XCTAssertEqual(simd_length(simd_cross(origin - SIMD3(1, 2, 3), direction)), 0, accuracy: 1e-9)

        let segment = GeometryConstruction.segment(SIMD3(0, 0, 0), SIMD3(0, 0, 2), name: "S")
        let layer = segment.makeLayer(index: 2, lineExtent: 10)
        XCTAssertEqual([layer.domainLower, layer.domainUpper], [0, 1])
        XCTAssertTrue(layer.lineStyle.isDashed)
        guard case let .line(_, d)? = recognize(layer) else { return XCTFail("线段也是线性曲线") }
        assertEqual(d, SIMD3(0, 0, 1))
    }

    // MARK: - 投影图层

    private func projection(of source: Layer, target: ProjectionTarget = .xy, offset: Double = 0,
                            plane: Layer? = nil, projectors: Bool = false, sourceVisible: Bool = false) -> (BuiltScene3D, [Layer]) {
        var layer = Layer.makeDefault(kind: .projection, index: 5)
        layer.sourceA = source.id
        layer.projectionTarget = target
        layer.projectionOffset = offset
        layer.sourceB = plane?.id
        layer.showsProjectors = projectors
        var origin = source
        origin.isVisible = sourceVisible
        var document = GrapherDocument(dimension: .space)
        document.layers = [origin] + (plane.map { [$0] } ?? []) + [layer]
        let built = SceneBuilder3D.build(SceneBuild3DRequest(
            document: document, compiled: LayerCompiler().compile(document),
            view: .standard, quality: .full, backingScale: 2))
        return (built, document.layers)
    }

    func testHelixProjectsToACircleOnTheFloor() throws {
        let helix = curve("2*cos(t)", "2*sin(t)", "t/2")
        let (built, _) = projection(of: helix)
        XCTAssertEqual(built.scene.polylines.count, 1, "来源藏起来、不画投影线时只剩投影")
        let line = try XCTUnwrap(built.scene.polylines.first)
        for p in line.points {
            let data = built.view.data(SIMD3<Double>(p))
            XCTAssertEqual(data.z, 0, accuracy: 1e-5, "落在 z = 0 上")
            XCTAssertEqual(simd_length(SIMD2(data.x, data.y)), 2, accuracy: 1e-4, "半径 2 的圆")
        }
    }

    func testProjectionOntoOffsetCoordinatePlanes() throws {
        let line = curve("t", "1", "2")
        for (target, check) in [
            (ProjectionTarget.yz, { (p: SIMD3<Double>) in p.x }),
            (.xz, { $0.y }),
            (.xy, { $0.z }),
        ] {
            let (built, _) = projection(of: line, target: target, offset: -1.5)
            let points = try XCTUnwrap(built.scene.polylines.first).points
            for p in points { XCTAssertEqual(check(built.view.data(SIMD3<Double>(p))), -1.5, accuracy: 1e-5) }
        }
    }

    func testPointProjectsToASphereAndProjectorsAreDrawn() throws {
        let p = point("1", "2", "3")
        let (built, _) = projection(of: p, projectors: true)
        let sphere = try XCTUnwrap(built.scene.meshes.first)
        let center = sphere.vertices.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(sphere.vertices.count)
        let data = built.view.data(SIMD3<Double>(center))
        XCTAssertEqual(data.x, 1, accuracy: 0.02)
        XCTAssertEqual(data.y, 2, accuracy: 0.02)
        XCTAssertEqual(data.z, 0, accuracy: 0.02)
        XCTAssertEqual(built.scene.polylines.count, 1, "一根投影线")
        let projector = built.scene.polylines[0].points.map { built.view.data(SIMD3<Double>($0)) }
        XCTAssertEqual(projector[0].z, 3, accuracy: 1e-5)
        XCTAssertEqual(projector[1].z, 0, accuracy: 1e-5)
    }

    func testProjectionOntoAPlaneLayer() throws {
        // 平面 x + y + z = 3，把点 (1,1,4) 投上去：沿法向 (1,1,1)/√3 移 -1 个 √3 单位到 (0,0,3)。
        let wall = plane("x + y + z - 3")
        let (built, _) = projection(of: point("1", "1", "4"), target: .plane, plane: wall)
        XCTAssertEqual(built.scene.meshes.count, 2, "平面本身和投影点")
        let sphere = try XCTUnwrap(built.scene.meshes.last, "投影最后画")
        let center = sphere.vertices.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(sphere.vertices.count)
        let data = built.view.data(SIMD3<Double>(center))
        XCTAssertEqual(data.x + data.y + data.z, 3, accuracy: 0.03)
        XCTAssertEqual(data.x, 0, accuracy: 0.03)
        XCTAssertEqual(data.z, 3, accuracy: 0.03)
    }

    func testProjectionOfAnIntersectionCurve() throws {
        // 球面与平面 z = 1 的交圆（半径 √3）投到 xz 面（y = 0）：压成 x ∈ [-√3, √3] 的一段线。
        let sphere = Layer.makeDefault(kind: .implicitSurface, index: 0)
        var s = sphere
        s.formula = "x^2 + y^2 + z^2 - 4"
        var floor = Layer.makeDefault(kind: .surface, index: 1)
        floor.formula = "1"
        var cut = Layer.makeDefault(kind: .surfaceIntersection, index: 2)
        cut.sourceA = s.id
        cut.sourceB = floor.id
        cut.isVisible = false
        var shadow = Layer.makeDefault(kind: .projection, index: 3)
        shadow.sourceA = cut.id
        shadow.projectionTarget = .xz
        shadow.showsProjectors = false
        var document = GrapherDocument(dimension: .space)
        s.isVisible = false
        floor.isVisible = false
        document.layers = [s, floor, cut, shadow]
        let built = SceneBuilder3D.build(SceneBuild3DRequest(
            document: document, compiled: LayerCompiler().compile(document),
            view: .standard, quality: .full, backingScale: 2))
        XCTAssertEqual(built.scene.polylines.count, 1)
        for p in built.scene.polylines[0].points {
            let data = built.view.data(SIMD3<Double>(p))
            XCTAssertEqual(data.y, 0, accuracy: 1e-5)
            XCTAssertEqual(data.z, 1, accuracy: 0.01)
            XCTAssertLessThanOrEqual(abs(data.x), 3.0.squareRoot() + 0.02)
        }
    }

    func testProjectionNeedsAValidSource() {
        let p = point("1", "2", "3")
        var orphan = Layer.makeDefault(kind: .projection, index: 0)
        orphan.sourceA = UUID()
        var document = GrapherDocument(dimension: .space)
        document.layers = [p, orphan]
        var built = SceneBuilder3D.build(SceneBuild3DRequest(
            document: document, compiled: LayerCompiler().compile(document),
            view: .standard, quality: .interactive, backingScale: 2))
        XCTAssertEqual(built.scene.meshes.count, 1, "只剩点本身")

        // 目标是平面却没指定平面图层：什么都不画。
        orphan.sourceA = p.id
        orphan.projectionTarget = .plane
        document.layers = [p, orphan]
        built = SceneBuilder3D.build(SceneBuild3DRequest(
            document: document, compiled: LayerCompiler().compile(document),
            view: .standard, quality: .interactive, backingScale: 2))
        XCTAssertEqual(built.scene.meshes.count, 1)
        XCTAssertTrue(built.scene.polylines.isEmpty)
    }

    func testProjectionFieldsSurviveCodableAndOldFilesStillOpen() throws {
        var layer = Layer.makeDefault(kind: .projection, index: 0)
        layer.projectionTarget = .yz
        layer.projectionOffset = 2.5
        layer.showsProjectors = false
        let data = try JSONEncoder().encode(layer)
        XCTAssertEqual(try JSONDecoder().decode(Layer.self, from: data), layer)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["projectionTarget", "projectionOffset", "showsProjectors"] { object.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(Layer.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.projectionTarget, .xy)
        XCTAssertEqual(old.projectionOffset, 0)
        XCTAssertTrue(old.showsProjectors)
    }

    // MARK: - 投影（几何）

    func testProjections() throws {
        let p = SIMD3<Double>(1, 2, 3)
        assertEqual(SpaceGeometry.foot(of: p, onPlane: SIMD3(0, 0, 1), offset: 0), SIMD3(1, 2, 0))
        // 沿 (1,0,1) 斜投到 z = 0：落在 (-2, 2, 0)。
        assertEqual(try XCTUnwrap(SpaceGeometry.project(p, onPlane: SIMD3(0, 0, 1), offset: 0, along: SIMD3(1, 0, 1))),
                    SIMD3(-2, 2, 0))
        XCTAssertNil(SpaceGeometry.project(p, onPlane: SIMD3(0, 0, 1), offset: 0, along: SIMD3(1, 0, 0)), "方向与平面平行")
    }
}
