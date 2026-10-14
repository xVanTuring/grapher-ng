import simd
import XCTest
@testable import GrapherKit

/// 梯度流线：积分走到该停的地方、两座山各自的盆地、小球沿弧长、图层的存取与 MCP 之外的场景构建。
final class GradientFlowTests: XCTestCase {

    private func compile(_ formula: String) throws -> CompiledExpression {
        try CompiledExpression(source: formula, context: ExpressionContext(variables: ["x", "y"]))
    }

    func testClimbsToTheSummitOfASingleHill() throws {
        let f = try compile("3*exp(-((x - 1)^2 + (y + 0.5)^2)/4)")
        let path = GradientFlow.path(of: f, from: SIMD2(-2, 2), center: .zero, halfExtent: 4, descent: false)
        XCTAssertGreaterThan(path.count, 20)
        let end = try XCTUnwrap(path.last)
        XCTAssertEqual(end.x, 1, accuracy: 0.05)
        XCTAssertEqual(end.y, -0.5, accuracy: 0.05)
        // 一路上 f 单调上升。
        let heights = path.map { f.evaluate([$0.x, $0.y]) }
        for (a, b) in zip(heights, heights.dropFirst()) { XCTAssertGreaterThanOrEqual(b, a - 1e-9) }
    }

    func testDescentRollsIntoTheBowlAndStops() throws {
        let f = try compile("x^2 + 2*y^2")
        let path = GradientFlow.path(of: f, from: SIMD2(3, 2), center: .zero, halfExtent: 4, descent: true)
        let end = try XCTUnwrap(path.last)
        XCTAssertLessThan(simd_length(end), 0.05, "停在碗底")
        let heights = path.map { f.evaluate([$0.x, $0.y]) }
        for (a, b) in zip(heights, heights.dropFirst()) { XCTAssertLessThanOrEqual(b, a + 1e-9) }
    }

    func testTwoSummitsHaveTheirOwnBasins() throws {
        let f = try compile("2.5*exp(-((x - 2)^2 + y^2)/2) + 2*exp(-((x + 2)^2 + y^2)/2)")
        let right = try XCTUnwrap(GradientFlow.path(of: f, from: SIMD2(0.8, 1), center: .zero, halfExtent: 4, descent: false).last)
        let left = try XCTUnwrap(GradientFlow.path(of: f, from: SIMD2(-0.8, 1), center: .zero, halfExtent: 4, descent: false).last)
        XCTAssertEqual(right.x, 2, accuracy: 0.1)
        XCTAssertEqual(left.x, -2, accuracy: 0.1)
    }

    func testStopsAtTheBoxEdgeAndAtFlatGroundAndBadStarts() throws {
        // 斜面一直往上：走到盒子边停，最后一点落在盒面上。
        let ramp = try compile("x")
        let climbed = GradientFlow.path(of: ramp, from: SIMD2(-3, 0), center: .zero, halfExtent: 4, descent: false)
        XCTAssertEqual(try XCTUnwrap(climbed.last).x, 4, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(climbed.last).y, 0, accuracy: 1e-6)
        // 平地：原地不动，只有起点。
        XCTAssertEqual(GradientFlow.path(of: try compile("2"), from: SIMD2(1, 1), center: .zero, halfExtent: 4, descent: false).count, 1)
        // 起点在盒外或没定义：只有起点。
        XCTAssertEqual(GradientFlow.path(of: ramp, from: SIMD2(9, 0), center: .zero, halfExtent: 4, descent: false).count, 1)
        XCTAssertEqual(GradientFlow.path(of: try compile("sqrt(x)"), from: SIMD2(-1, 0), center: .zero, halfExtent: 4, descent: false).count, 1)
    }

    func testPointAlongAPolylineFollowsArcLength() {
        let line = [SIMD3(0.0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 3, 0)]   // 总长 4
        XCTAssertEqual(GradientFlow.point(along: line, fraction: 0), line[0])
        XCTAssertEqual(GradientFlow.point(along: line, fraction: 0.25), SIMD3(1, 0, 0))
        XCTAssertEqual(GradientFlow.point(along: line, fraction: 0.625), SIMD3(1, 1.5, 0))
        XCTAssertEqual(GradientFlow.point(along: line, fraction: 1), SIMD3(1, 3, 0))
        XCTAssertEqual(GradientFlow.point(along: line, fraction: 7), SIMD3(1, 3, 0), "超出夹到端点")
        XCTAssertNil(GradientFlow.point(along: [], fraction: 0.5))
        XCTAssertEqual(GradientFlow.point(along: [SIMD3(2, 2, 2)], fraction: 0.5), SIMD3(2, 2, 2))
    }

    func testFlowLayerDrawsPathsAndABallThatFollowsTheParameter() throws {
        var hill = Layer.makeDefault(kind: .surface, index: 0)
        hill.formula = "3*exp(-(x^2 + y^2)/4)"
        var flow = Layer.makeDefault(kind: .gradientFlow, index: 1)
        flow.sourceA = hill.id
        flow.formula = "3, 3\n-3, 2"
        flow.secondaryFormula = "p"
        var document = GrapherDocument(dimension: .space)
        document.parameters = [ParameterDefinition(name: "p", value: 0, lowerBound: 0, upperBound: 1)]
        document.layers = [hill, flow]

        func ball(_ p: Double) throws -> SIMD3<Float> {
            document.parameters[0].value = p
            XCTAssertFalse(LayerCompiler().compile(document)[1].hasError)
            let built = SceneBuilder3D.build(SceneBuild3DRequest(
                document: document, compiled: LayerCompiler().compile(document), view: .standard,
                quality: .interactive, backingScale: 1))
            XCTAssertEqual(built.scene.polylines.filter { $0.layerID == flow.id }.count, 2, "两个起点两条路径")
            let balls = built.scene.meshes.filter { $0.layerID == flow.id }
            XCTAssertEqual(balls.count, 2)
            let first = try XCTUnwrap(balls.first)
            return first.vertices.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(first.vertices.count)
        }
        let start = try ball(0), middle = try ball(0.5), end = try ball(1)
        // 起点在 (3,3) 附近，终点在山顶 (0,0,3) 附近（盒 ±4 → 归一化 0.75, 0.75 与 0, 0, 0.75）。
        XCTAssertEqual(start.x, 0.75, accuracy: 0.03)
        XCTAssertEqual(end.x, 0, accuracy: 0.05)
        XCTAssertEqual(end.z, 0.75, accuracy: 0.05)
        XCTAssertGreaterThan(simd_distance(start, middle), 0.1)
        XCTAssertGreaterThan(simd_distance(middle, end), 0.1)
    }

    func testFlowLayerNeedsAValidSourceAndCompilesOnlyTheBallFormula() {
        var flow = Layer.makeDefault(kind: .gradientFlow, index: 0)
        flow.formula = "1, 1"
        flow.secondaryFormula = "1 +"
        var document = GrapherDocument(dimension: .space)
        document.layers = [flow]
        XCTAssertTrue(LayerCompiler().compile(document)[0].hasError, "小球位置公式有错要报")
        document.layers[0].secondaryFormula = "0.5"
        XCTAssertFalse(LayerCompiler().compile(document)[0].hasError, "起点文字不当公式编译")
        let built = SceneBuilder3D.build(SceneBuild3DRequest(
            document: document, compiled: LayerCompiler().compile(document), view: .standard,
            quality: .interactive, backingScale: 1))
        XCTAssertTrue(built.scene.isEmpty, "没有来源曲面什么都不画")
    }
}

/// 起点的每一栏可以是公式：参数一变起点就动，路径跟着换。
final class GradientSeedTests: XCTestCase {

    func testFieldsSplitOnCommasSemicolonsTabsAndPlainSpaces() {
        let text = "1, 2\n3*cos(q), 3 * sin(q)\n4;5\n6\t7\n8 9\nheader only\n  \n10, 11, 12\n13"
        let fields = GradientSeeds.fields(text).map { "\($0.x)|\($0.y)" }
        // "header only" 是用空格隔开的两段，按两栏算（之后编译不过会被跳过）；单栏的行没有。
        XCTAssertEqual(fields, ["1|2", "3*cos(q)|3 * sin(q)", "4|5", "6|7", "8|9", "header|only", "10|11"])
    }

    func testSeedsAreResolvedFromParametersAndBadOnesAreDropped() throws {
        var hill = Layer.makeDefault(kind: .surface, index: 0)
        hill.formula = "x"
        var flow = Layer.makeDefault(kind: .gradientFlow, index: 1)
        flow.sourceA = hill.id
        flow.formula = "q, 1\n2*q, -1\nnope, 3\n1/0, 2\n0.5, 0.5"
        var document = GrapherDocument(dimension: .space)
        document.parameters = [ParameterDefinition(name: "q", value: 1.5)]
        document.layers = [hill, flow]
        let compiled = LayerCompiler().compile(document)[1]
        XCTAssertEqual(compiled.seeds, [SIMD2(1.5, 1), SIMD2(3, -1), SIMD2(0.5, 0.5)], "写错的两个起点跳过")
        XCTAssertNotNil(compiled.domainError, "第一个错误要报出来")
        XCTAssertTrue(compiled.hasError)

        document.parameters[0].value = -2
        XCTAssertEqual(LayerCompiler().compile(document)[1].seeds.first, SIMD2(-2, 1))
    }

    func testPathChangesBasinAsTheStartMoves() throws {
        var hills = Layer.makeDefault(kind: .surface, index: 0)
        hills.formula = "2.5*exp(-((x - 2)^2 + y^2)/2) + 2*exp(-((x + 2)^2 + y^2)/2)"
        var flow = Layer.makeDefault(kind: .gradientFlow, index: 1)
        flow.sourceA = hills.id
        flow.formula = "q, 1"
        var document = GrapherDocument(dimension: .space)
        document.parameters = [ParameterDefinition(name: "q", value: 0.8)]
        document.layers = [hills, flow]
        func summitX(_ q: Double) throws -> Double {
            document.parameters[0].value = q
            let built = SceneBuilder3D.build(SceneBuild3DRequest(
                document: document, compiled: LayerCompiler().compile(document), view: .standard,
                quality: .full, backingScale: 1))
            let line = try XCTUnwrap(built.scene.polylines.first { $0.layerID == flow.id })
            return built.view.data(SIMD3<Double>(try XCTUnwrap(line.points.last))).x
        }
        XCTAssertEqual(try summitX(0.8), 2, accuracy: 0.15, "起点偏右：爬到右边那座")
        XCTAssertEqual(try summitX(-0.8), -2, accuracy: 0.15, "起点偏左：爬到左边那座")
    }
}
