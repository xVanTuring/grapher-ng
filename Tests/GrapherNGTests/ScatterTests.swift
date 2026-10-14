import XCTest
@testable import GrapherKit

/// 散点数据：解析、最小二乘拟合、画出来的点与拟合线。
final class ScatterTests: XCTestCase {

    func testParseAcceptsCommonSeparatorsAndSkipsJunk() {
        let text = """
        x, y
        1, 2
        2;4.5
        3\t6
        4 8.5

        not numbers
        5, inf
        6, 1, 99
        """
        // 表头、空行、非数、无穷都跳过；多于两列取前两列。
        XCTAssertEqual(ScatterData.parse(text), [SIMD2(1, 2), SIMD2(2, 4.5), SIMD2(3, 6), SIMD2(4, 8.5), SIMD2(6, 1)])
    }

    func testFitRecoversAnExactLine() throws {
        let points = (0..<10).map { SIMD2(Double($0), 3 * Double($0) - 2) }
        let fit = try XCTUnwrap(ScatterData.fit(points))
        XCTAssertEqual(fit.slope, 3, accuracy: 1e-12)
        XCTAssertEqual(fit.intercept, -2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(fit.correlation), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(fit.rSquared), 1, accuracy: 1e-12)
        XCTAssertEqual(fit.count, 10)
    }

    func testFitOfNoisyDataMatchesTheTextbookNumbers() throws {
        // (1,2) (2,3) (3,5) (4,4) (5,6)：均值 (3, 4)，Sxx = 10，Sxy = 9，Syy = 10 → a = 0.9, b = 1.3, r = 0.9。
        let points = [SIMD2(1.0, 2), SIMD2(2, 3), SIMD2(3, 5), SIMD2(4, 4), SIMD2(5, 6)]
        let fit = try XCTUnwrap(ScatterData.fit(points))
        XCTAssertEqual(fit.slope, 0.9, accuracy: 1e-12)
        XCTAssertEqual(fit.intercept, 1.3, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(fit.correlation), 0.9, accuracy: 1e-12)
        XCTAssertEqual(fit.mean, SIMD2(3, 4))
        XCTAssertEqual(fit.standardDeviation.x, (10.0 / 4).squareRoot(), accuracy: 1e-12)
    }

    func testFitNeedsTwoPointsWithDifferentX() {
        XCTAssertNil(ScatterData.fit([]))
        XCTAssertNil(ScatterData.fit([SIMD2(1, 1)]))
        XCTAssertNil(ScatterData.fit([SIMD2(2, 1), SIMD2(2, 5)]), "x 全相同是竖直线")
        // y 全相同：水平线，斜率 0，相关系数没有定义。
        let flat = ScatterData.fit([SIMD2(1, 3), SIMD2(2, 3), SIMD2(3, 3)])
        XCTAssertEqual(flat?.slope, 0)
        XCTAssertNil(flat?.correlation)
    }

    func testScatterLayerDrawsMarkersAndOptionalFitLine() throws {
        var layer = Layer.makeDefault(kind: .scatter, index: 0)
        layer.formula = "1, 1\n2, 2\n3, 3"
        var document = GrapherDocument()
        document.layers = [layer]
        let viewport = Viewport2D(centerX: 2, centerY: 2, scale: 80, widthPixels: 600, heightPixels: 400)
        func build() -> BuiltScene {
            SceneBuilder2D.build(SceneBuildRequest(
                document: document, compiled: LayerCompiler().compile(document), viewport: viewport,
                quality: .full, backingScale: 1))
        }
        func markers(_ scene: BuiltScene) -> [MarkerPrimitiveBatch] {
            scene.scene.commands.compactMap { if case .markers(let m) = $0 { return m } else { return nil } }
        }
        func polylines(_ scene: BuiltScene) -> Int {
            scene.scene.commands.filter { if case .polyline = $0 { return true } else { return false } }.count
        }

        var built = build()
        XCTAssertEqual(markers(built).first?.positions.count, 3)
        let withoutFit = polylines(built)
        XCTAssertEqual(built.probeCurves.first?.segments.count, 3, "三个点都能被读数 / 适应内容找到")
        XCTAssertNotNil(built.fitBounds)

        layer.showsFit = true
        document.layers = [layer]
        built = build()
        XCTAssertEqual(polylines(built), withoutFit + 1, "多一条拟合线")
    }

    func testEmptyOrJunkDataDrawsNothing() {
        var layer = Layer.makeDefault(kind: .scatter, index: 0)
        layer.formula = "nothing here"
        var document = GrapherDocument()
        document.layers = [layer]
        let built = SceneBuilder2D.build(SceneBuildRequest(
            document: document, compiled: LayerCompiler().compile(document),
            viewport: Viewport2D(centerX: 0, centerY: 0, scale: 40, widthPixels: 400, heightPixels: 300),
            quality: .full, backingScale: 1))
        XCTAssertTrue(built.probeCurves.isEmpty)
        XCTAssertFalse(LayerCompiler().compile(document)[0].hasError, "数据不当公式编译")
    }

    func testScatterFieldSurvivesCodableAndOldFilesStillOpen() throws {
        var layer = Layer.makeDefault(kind: .scatter, index: 0)
        layer.showsFit = true
        let data = try JSONEncoder().encode(layer)
        XCTAssertEqual(try JSONDecoder().decode(Layer.self, from: data), layer)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "showsFit")
        XCTAssertFalse(try JSONDecoder().decode(Layer.self, from: JSONSerialization.data(withJSONObject: object)).showsFit)
    }
}
