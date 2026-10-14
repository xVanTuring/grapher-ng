import XCTest
@testable import GrapherKit

/// 文字描述（```grapher 代码块）：解析、报错、回写。
final class GrapherTextTests: XCTestCase {

    private func parse(_ text: String) -> GrapherText.Result { GrapherText.parse(text) }

    private func assertValid(_ result: GrapherText.Result, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.isValid, result.errors.map { "L\($0.line): \($0.message)" }.joined(separator: "\n"), file: file, line: line)
    }

    func testPlaneCurvesAndParameters() {
        let result = parse("""
        # 一条曲线
        param a = 2 [0, 4]
        explicit f: a*sin(x); x=-6..6; color=#e11d48; width=2.5
        parametric: cos(t); sin(t); dash
        """)
        assertValid(result)
        XCTAssertEqual(result.document.dimension, .plane)
        XCTAssertEqual(result.document.parameters.map(\.name), ["a"])
        XCTAssertEqual(result.document.parameters[0].upperBound, 4)
        XCTAssertEqual(result.document.layers.count, 2)
        let f = result.document.layers[0]
        XCTAssertEqual(f.kind, .explicit)
        XCTAssertEqual(f.name, "f")
        XCTAssertEqual(f.formula, "a*sin(x)")
        XCTAssertTrue(f.usesExplicitDomain)
        XCTAssertEqual(f.domainLower, -6)
        XCTAssertEqual(f.domainUpper, 6)
        XCTAssertEqual(f.lineStyle.width, 2.5)
        XCTAssertEqual(f.lineStyle.color.r, Double(0xE1) / 255, accuracy: 1e-9)
        let p = result.document.layers[1]
        XCTAssertEqual(p.secondaryFormula, "sin(t)")
        XCTAssertTrue(p.lineStyle.isDashed)
    }

    func testEquationsAndInequalities() {
        let result = parse("""
        implicit: x^2 + y^2 = 4
        region: x + y <= 1
        explicit: y = x^2
        """)
        assertValid(result)
        XCTAssertEqual(result.document.layers[0].formula, "(x^2 + y^2) - (4)")
        XCTAssertEqual(result.document.layers[1].relation, .lessOrEqual)
        XCTAssertEqual(result.document.layers[1].formula, "(x + y) - (1)")
        XCTAssertEqual(result.document.layers[2].formula, "x^2")
    }

    func testSpaceDocumentAndReferences() {
        let result = parse("""
        view: azimuth=40 elevation=20 zoom=1.2 range=5
        surface S: sin(x)*cos(y); opacity=0.6
        surface T: 0.3*x
        intersection: of=S, T; color=red
        point A: 1; 1; sin(1)*cos(1)
        tangent-plane: of=S; at=0.5, 1
        projection: of=A; onto=xy
        gradient-field: of=S; density=8; floor
        """)
        assertValid(result)
        let document = result.document
        XCTAssertEqual(document.dimension, .space, "出现立体图层就是立体图")
        XCTAssertEqual(document.view3D.azimuth, 40 * .pi / 180, accuracy: 1e-9)
        XCTAssertEqual(document.view3D.cameraZoom, 1.2)
        XCTAssertEqual(document.view3D.halfExtent, 5)
        let byName = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.name, $0) })
        let intersection = document.layers.first { $0.kind == .surfaceIntersection }!
        XCTAssertEqual(intersection.sourceA, byName["S"]?.id)
        XCTAssertEqual(intersection.sourceB, byName["T"]?.id)
        XCTAssertEqual(byName["S"]?.fillStyle.opacity, 0.6)
        XCTAssertEqual(document.layers.first { $0.kind == .tangentPlane }?.anchorV, 1)
        XCTAssertEqual(document.layers.first { $0.kind == .gradientField }?.gridDensity, 8)
        XCTAssertTrue(document.layers.first { $0.kind == .gradientField }?.gradientOnFloor ?? false)
    }

    func testPositionsMayUseParameters() {
        let result = parse("""
        param p = 0.5 [0, 1]
        explicit C: x^2; x=-3..3*p+0.1
        tangent: of=C; at=2*p
        text: "切点"; at=p, 1
        """)
        assertValid(result)
        let c = result.document.layers[0]
        XCTAssertEqual(c.domainUpperFormula, "3*p+0.1")
        XCTAssertEqual(c.domainLower, -3)
        let tangent = result.document.layers[1]
        XCTAssertEqual(tangent.anchorUFormula, "2*p")
        let text = result.document.layers[2]
        XCTAssertEqual(text.formula, "切点")
        XCTAssertEqual(text.anchorUFormula, "p")
        XCTAssertEqual(text.anchorV, 1)
    }

    func testScatterAndFlowRows() {
        let result = parse("""
        scatter: 1, 2.1; 2, 3.9; 3, 6.2; fit
        space
        surface S: -(x^2+y^2)/4
        gradient-flow: of=S; 1.5, 0.5; -2, 2; ball=0.5
        """)
        // 同一份里不能又是平面又是立体：scatter 在立体图里不允许。
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors.first?.line, 1)

        let plane = parse("scatter: 1, 2.1; 2, 3.9; 3, 6.2; fit")
        assertValid(plane)
        XCTAssertEqual(plane.document.layers[0].formula, "1, 2.1\n2, 3.9\n3, 6.2")
        XCTAssertTrue(plane.document.layers[0].showsFit)

        let flow = parse("""
        surface S: -(x^2+y^2)/4
        gradient-flow: of=S; 1.5, 0.5; -2, 2; ball=0.5
        """)
        assertValid(flow)
        XCTAssertEqual(flow.document.layers[1].formula, "1.5, 0.5\n-2, 2")
        XCTAssertEqual(flow.document.layers[1].secondaryFormula, "0.5")
    }

    func testErrorsAreReportedPerLine() {
        let result = parse("""
        surface S: sin(x)*cos(y)
        surface: sin(x)*unknown(y)
        tangent: of=Nope; at=1
        banana: 1
        explicit: y=sin(x); colour=red
        view: azimuth=40
        """)
        let byLine = Dictionary(grouping: result.errors, by: \.line)
        XCTAssertNotNil(byLine[2], "公式里的未知函数按行报")
        XCTAssertNotNil(byLine[3], "引用不存在的图层")
        XCTAssertNotNil(byLine[4], "不认识的图层类型")
        XCTAssertNotNil(byLine[5], "不认识的选项")
        // 出错的行跳过，其余照常：第 1 行的曲面还在。
        XCTAssertTrue(result.document.layers.contains { $0.name == "S" })
    }

    func testSourceKindIsChecked() {
        let result = parse("""
        explicit F: x^2
        tangent-plane: of=F; at=1, 1
        """)
        XCTAssertFalse(result.isValid)
    }

    func testDuplicateAndReservedParameterNames() {
        XCTAssertFalse(parse("param x = 1").isValid, "x 是保留名")
        XCTAssertFalse(parse("param a = 1\nparam a = 2").isValid)
        XCTAssertFalse(parse("param a = abc").isValid)
    }

    func testThemeAspectAndSettings() {
        let result = parse("""
        theme: dark
        aspect: 16:9
        grid: off
        ticks: off
        explicit: x
        """)
        assertValid(result)
        XCTAssertEqual(result.themeName, "dark")
        XCTAssertEqual(result.aspect, 16.0 / 9.0, accuracy: 1e-9)
        XCTAssertFalse(result.document.showGrid)
        XCTAssertFalse(result.document.showTickLabels)
        XCTAssertEqual(result.document.theme, .dark)
    }

    func testPlaneViewFrame() {
        let result = parse("""
        view: center=1,2 width=10
        aspect: 2
        explicit: x
        """)
        assertValid(result)
        XCTAssertEqual(result.planeFrame, GrapherText.PlaneFrame(centerX: 1, centerY: 2, width: 10))
        XCTAssertEqual(result.document.viewport.scale * 10, result.document.viewport.widthPixels, accuracy: 1e-6)
        XCTAssertEqual(result.document.viewport.widthPixels / result.document.viewport.heightPixels, 2, accuracy: 0.01)
    }

    // MARK: - 回写

    func testPatchReplacesViewAndParameterValuesOnly() {
        let source = """
        # 标题
        view: azimuth=10 elevation=10
        param a = 1 [0, 3]
        surface S: a*sin(x)   # 不动
        param b = 2
        """
        var view = View3D.standard
        view.azimuth = 55 * .pi / 180
        view.elevation = 30 * .pi / 180
        let patched = GrapherText.patch(
            source: source, view: .space(GrapherText.SpaceViewValues(view)), parameters: ["a": 2.25, "zzz": 9])
        XCTAssertEqual(patched, """
        # 标题
        view: azimuth=55 elevation=30
        param a = 2.25 [0, 3]
        surface S: a*sin(x)   # 不动
        param b = 2
        """)
        // 回写的结果能原样读回来。
        let again = parse(patched)
        XCTAssertEqual(again.document.view3D.azimuth, 55 * .pi / 180, accuracy: 1e-9)
        XCTAssertEqual(again.document.parameters.first?.value, 2.25)
    }

    func testPatchInsertsViewBeforeFirstLayer() {
        let source = "space\ntheme: dark\nparam a = 1\nsurface: a*x"
        var view = View3D.standard
        view.azimuth = 20 * .pi / 180
        view.elevation = 15 * .pi / 180
        view.cameraZoom = 1.5
        let patched = GrapherText.patch(source: source, view: .space(GrapherText.SpaceViewValues(view)), parameters: [:])
        let lines = patched.components(separatedBy: "\n")
        XCTAssertEqual(lines[2], "view: azimuth=20 elevation=15 zoom=1.5")
        XCTAssertEqual(lines.count, 5)
    }

    func testPatchPlaneView() {
        let patched = GrapherText.patch(
            source: "explicit: x", view: .plane(GrapherText.PlaneFrame(centerX: 0.5, centerY: -1, width: 8.25)), parameters: [:])
        XCTAssertEqual(patched, "view: center=0.5,-1 width=8.25\nexplicit: x")
    }

    // MARK: - 全部图层的往返

    /// 每一种图层都至少有一个写法，写出来能读、公式没有错：防止以后加了图型忘了文字格式。
    func testEveryPlotKindHasAWritableForm() {
        let samples: [PlotKind: String] = [
            .explicit: "explicit: sin(x)",
            .parametric: "parametric: cos(t); sin(t)",
            .polar: "polar: 1+cos(theta)",
            .implicit: "implicit: x^2+y^2=1",
            .region: "region: x^2+y^2<=1",
            .tangent: "explicit C: x^2\ntangent: of=C; at=1",
            .text: "text: \"hi\"; at=0,0",
            .scatter: "scatter: 1,2; 2,3",
            .surface: "surface: sin(x)*cos(y)",
            .parametricSurface: "parametric-surface: (2+cos(v))*cos(u); (2+cos(v))*sin(u); sin(v)",
            .spaceCurve: "space-curve: cos(t); sin(t); t/4",
            .implicitSurface: "implicit-surface: x^2+y^2+z^2=4",
            .surfaceIntersection: "surface A: x+y\nsurface B: x-y+1\nintersection: of=A, B",
            .point: "point P: 1; 2; 3",
            .projection: "point P: 1; 2; 3\nprojection: of=P; onto=xy",
            .tangentPlane: "surface S: x*y\ntangent-plane: of=S; at=1, 1",
            .gradientField: "surface S: x*y\ngradient-field: of=S",
            .gradientFlow: "surface S: -(x^2+y^2)\ngradient-flow: of=S; 1, 1",
        ]
        for kind in PlotKind.allCases {
            guard let text = samples[kind] else {
                XCTFail("\(kind.rawValue) 还没有文字写法的用例")
                continue
            }
            let result = parse(text)
            assertValid(result)
            XCTAssertTrue(result.document.layers.contains { $0.kind == kind }, "\(kind.rawValue)")
        }
    }
}
