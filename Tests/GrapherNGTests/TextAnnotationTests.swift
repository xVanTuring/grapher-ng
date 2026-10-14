import XCTest
@testable import GrapherKit

/// 自由文字标注：哪些图层写、写在哪、字号夹范围；不当公式编译；存档兼容。
final class TextAnnotationTests: XCTestCase {

    private func text(_ content: String, at x: Double, _ y: Double, _ z: Double = 0) -> Layer {
        var layer = Layer.makeDefault(kind: .text, index: 0)
        layer.formula = content
        layer.anchorU = x
        layer.anchorV = y
        layer.anchorW = z
        return layer
    }

    func testOnlyVisibleNonEmptyTextLayersAreWritten() {
        var hidden = text("hidden", at: 0, 0); hidden.isVisible = false
        let empty = text("", at: 0, 0)
        var document = GrapherDocument()
        document.layers = [text("A = (1, 2)", at: 1, 2), hidden, empty, Layer.makeDefault(kind: .explicit, index: 1)]
        let found = TextAnnotations.all(in: document)
        XCTAssertEqual(found.map(\.text), ["A = (1, 2)"])
        XCTAssertEqual(found[0].position, SIMD3(1, 2, 0))
    }

    func testSpaceDocumentsUseTheThirdCoordinateAndPlaneOnesIgnoreIt() {
        var space = GrapherDocument(dimension: .space)
        space.layers = [text("P", at: 1, 2, 3)]
        XCTAssertEqual(TextAnnotations.all(in: space).first?.position, SIMD3(1, 2, 3))
        var plane = GrapherDocument()
        plane.layers = [text("P", at: 1, 2, 3)]
        XCTAssertEqual(TextAnnotations.all(in: plane).first?.position, SIMD3(1, 2, 0))
    }

    func testFontSizeIsClampedAndBadPositionsAreSkipped() {
        var tiny = text("t", at: 0, 0); tiny.fontSize = 1
        var huge = text("h", at: 0, 0); huge.fontSize = 500
        var broken = text("b", at: .nan, 0)
        broken.fontSize = 14
        var document = GrapherDocument()
        document.layers = [tiny, huge, broken]
        XCTAssertEqual(TextAnnotations.all(in: document).map(\.fontSize), [6, 96])
    }

    /// 文字内容原样保存，不被当公式编译（写 "x +" 不该报公式错）。
    func testTextIsNotCompiledAsAFormula() {
        var document = GrapherDocument()
        document.layers = [text("x + (", at: 0, 0)]
        XCTAssertFalse(LayerCompiler().compile(document)[0].hasError)
        XCTAssertTrue(PlotKind.cases(for: .plane).contains(.text))
        XCTAssertTrue(PlotKind.cases(for: .space).contains(.text))
    }

    func testTextFieldsSurviveCodableAndOldFilesStillOpen() throws {
        var layer = text("hi", at: 1, 2, 3)
        layer.fontSize = 20
        let data = try JSONEncoder().encode(layer)
        XCTAssertEqual(try JSONDecoder().decode(Layer.self, from: data), layer)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "anchorW")
        object.removeValue(forKey: "fontSize")
        let old = try JSONDecoder().decode(Layer.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.anchorW, 0)
        XCTAssertEqual(old.fontSize, 14)
    }

    func testTextLayerDrawsNothingInTheMetalScenes() {
        var plane = GrapherDocument()
        plane.layers = [text("hello", at: 0, 0)]
        let built = SceneBuilder2D.build(SceneBuildRequest(
            document: plane, compiled: LayerCompiler().compile(plane),
            viewport: Viewport2D(centerX: 0, centerY: 0, scale: 40, widthPixels: 400, heightPixels: 300),
            quality: .full, backingScale: 1))
        XCTAssertTrue(built.probeCurves.isEmpty)

        var space = GrapherDocument(dimension: .space)
        space.layers = [text("hello", at: 0, 0, 0)]
        let built3D = SceneBuilder3D.build(SceneBuild3DRequest(
            document: space, compiled: LayerCompiler().compile(space), view: .standard,
            quality: .interactive, backingScale: 1))
        XCTAssertTrue(built3D.scene.isEmpty)
    }
}
