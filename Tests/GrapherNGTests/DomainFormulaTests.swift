import XCTest
@testable import GrapherKit

/// 范围端点写成含参数的表达式：参数一变范围跟着变（播放参数曲线就一点点画出来）。
final class DomainFormulaTests: XCTestCase {

    private func parametric(upper: String, lower: String = "") -> Layer {
        var layer = Layer.makeDefault(kind: .parametric, index: 0)
        layer.formula = "t"
        layer.secondaryFormula = "sin(t)"
        layer.domainLower = 0
        layer.domainUpper = 10
        layer.usesExplicitDomain = true
        layer.domainLowerFormula = lower
        layer.domainUpperFormula = upper
        return layer
    }

    private func document(_ layer: Layer, p: Double? = nil, space: Bool = false) -> GrapherDocument {
        var document = GrapherDocument(dimension: space ? .space : .plane)
        if let p { document.parameters = [ParameterDefinition(name: "p", value: p, lowerBound: 0, upperBound: 1)] }
        document.layers = [layer]
        return document
    }

    private func extent(_ document: GrapherDocument) -> ClosedRange<Double>? {
        let viewport = Viewport2D(centerX: 5, centerY: 0, scale: 40, widthPixels: 900, heightPixels: 300)
        let built = SceneBuilder2D.build(SceneBuildRequest(
            document: document, compiled: LayerCompiler().compile(document), viewport: viewport,
            quality: .full, backingScale: 1))
        let xs = built.probeCurves.flatMap { $0.segments.joined() }.map(\.x)
        guard let low = xs.min(), let high = xs.max() else { return nil }
        return low...high
    }

    func testRangeEndFollowsTheParameter() throws {
        let layer = parametric(upper: "p*8")
        // x = t，所以曲线画到哪里 x 的最大值就是上界。
        XCTAssertEqual(try XCTUnwrap(extent(document(layer, p: 0.25))).upperBound, 2, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(extent(document(layer, p: 1))).upperBound, 8, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(extent(document(layer, p: 0.5))).lowerBound, 0, accuracy: 1e-6, "下界没写表达式，用数")
    }

    func testBothEndsAndConstantsLikePi() throws {
        let layer = parametric(upper: "p*pi", lower: "-p*pi")
        let range = try XCTUnwrap(extent(document(layer, p: 0.5)))
        XCTAssertEqual(range.lowerBound, -Double.pi / 2, accuracy: 1e-6)
        XCTAssertEqual(range.upperBound, Double.pi / 2, accuracy: 1e-6)
    }

    func testCompilerHandsBuildersTheResolvedNumbersAndKeepsTheFormulas() {
        let layer = parametric(upper: "p*8")
        let compiled = LayerCompiler().compile(document(layer, p: 0.5))[0]
        XCTAssertEqual(compiled.layer.domainUpper, 4)
        XCTAssertEqual(compiled.layer.domainUpperFormula, "p*8", "公式本身不丢")
        XCTAssertEqual(layer.domainUpper, 10, "文档里的原图层不动")
        XCTAssertFalse(compiled.hasError)
    }

    func testErrorsAreReportedAndTheOldNumberIsKept() {
        let unknown = LayerCompiler().compile(document(parametric(upper: "q*2"), p: 0.5))[0]
        XCTAssertNotNil(unknown.domainError)
        XCTAssertTrue(unknown.hasError)
        XCTAssertEqual(unknown.layer.domainUpper, 10, "出错的端点保留原来的数")
        let infinite = LayerCompiler().compile(document(parametric(upper: "1/0"), p: 0.5))[0]
        XCTAssertNotNil(infinite.domainError, "无穷不是合法的端点")
        let broken = LayerCompiler().compile(document(parametric(upper: "p*"), p: 0.5))[0]
        XCTAssertNotNil(broken.domainError)
    }

    /// 参数为 0 时范围缩成一点：什么都不画，但不能崩，各种曲线图型都一样。
    func testEmptyRangeDrawsNothingAndDoesNotCrash() {
        XCTAssertNil(extent(document(parametric(upper: "p*8"), p: 0)).flatMap { $0.upperBound > 1e-9 ? $0 : nil })

        var polar = Layer.makeDefault(kind: .polar, index: 0)
        polar.formula = "1"
        polar.domainLowerFormula = "0"
        polar.domainUpperFormula = "p*2*pi"
        _ = extent(document(polar, p: 0))
        var explicit = Layer.makeDefault(kind: .explicit, index: 0)
        explicit.formula = "x"
        explicit.usesExplicitDomain = true
        explicit.domainLowerFormula = "-p"
        explicit.domainUpperFormula = "p"
        _ = extent(document(explicit, p: 0))

        var helix = Layer.makeDefault(kind: .spaceCurve, index: 0)
        helix.formula = "cos(t)"
        helix.secondaryFormula = "sin(t)"
        helix.tertiaryFormula = "t/4"
        helix.domainLowerFormula = "0"
        helix.domainUpperFormula = "p*12"
        let flat = document(helix, p: 0, space: true)
        let built = SceneBuilder3D.build(SceneBuild3DRequest(
            document: flat, compiled: LayerCompiler().compile(flat), view: .standard, quality: .interactive, backingScale: 1))
        XCTAssertTrue(built.scene.polylines.isEmpty)

        var sphere = Layer.makeDefault(kind: .parametricSurface, index: 0)
        sphere.formula = "cos(u)*sin(v)"
        sphere.secondaryFormula = "sin(u)*sin(v)"
        sphere.tertiaryFormula = "cos(v)"
        sphere.domainLowerFormula = "0"
        sphere.domainUpperFormula = "p*6.28"
        let sliver = document(sphere, p: 0, space: true)
        _ = SceneBuilder3D.build(SceneBuild3DRequest(
            document: sliver, compiled: LayerCompiler().compile(sliver), view: .standard, quality: .interactive, backingScale: 1))
    }

    func testSpaceCurveGrowsWithTheParameter() throws {
        var helix = Layer.makeDefault(kind: .spaceCurve, index: 0)
        helix.formula = "2*cos(t)"
        helix.secondaryFormula = "2*sin(t)"
        helix.tertiaryFormula = "t/4"
        helix.domainLowerFormula = "0"
        helix.domainUpperFormula = "p*20"
        func topHeight(_ p: Double) throws -> Double {
            let doc = document(helix, p: p, space: true)
            let built = SceneBuilder3D.build(SceneBuild3DRequest(
                document: doc, compiled: LayerCompiler().compile(doc), view: .standard, quality: .full, backingScale: 1))
            let line = try XCTUnwrap(built.scene.polylines.first)
            return line.points.map { built.view.data(SIMD3<Double>($0)).z }.max() ?? 0
        }
        XCTAssertEqual(try topHeight(0.25), 20 * 0.25 / 4, accuracy: 0.02)
        XCTAssertEqual(try topHeight(0.5), 20 * 0.5 / 4, accuracy: 0.02)
        XCTAssertGreaterThan(try topHeight(0.5), try topHeight(0.25))
    }

    func testFormulasSurviveCodableAndOldFilesStillOpen() throws {
        var layer = parametric(upper: "p*8", lower: "-p")
        layer.domain2LowerFormula = "0"
        layer.domain2UpperFormula = "p*pi"
        let data = try JSONEncoder().encode(layer)
        XCTAssertEqual(try JSONDecoder().decode(Layer.self, from: data), layer)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["domainLowerFormula", "domainUpperFormula", "domain2LowerFormula", "domain2UpperFormula"] {
            object.removeValue(forKey: key)
        }
        let old = try JSONDecoder().decode(Layer.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(old.hasDomainFormulas)
        XCTAssertEqual(old.domainUpper, 10)
    }
}
