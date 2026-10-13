import CoreGraphics
import XCTest
@testable import GrapherKit

/// Integration tests over the whole pipeline: document -> compiled layers ->
/// sampled geometry -> scene -> exported file.
final class SceneBuilderTests: XCTestCase {

    private func document() -> GrapherDocument {
        var document = GrapherDocument.sample()
        document.viewport.widthPixels = 900
        document.viewport.heightPixels = 600
        document.viewport.scale = 28
        return document
    }

    private func build(_ document: GrapherDocument, quality: SampleQuality = .full) -> BuiltScene {
        let compiler = LayerCompiler()
        let request = SceneBuildRequest(
            document: document,
            compiled: compiler.compile(document),
            viewport: document.viewport,
            quality: quality,
            backingScale: 2
        )
        return SceneBuilder2D.build(request)
    }

    func testSampleDocumentRendersEveryLayer() {
        let built = build(document())
        XCTAssertEqual(built.probeCurves.count, 4, "one probe curve per visible layer")
        XCTAssertFalse(built.scene.commands.isEmpty)
        XCTAssertGreaterThan(built.scene.approximatePrimitiveCount, 500)

        // The chrome is drawn underneath the plots.
        if case .polyline = built.scene.commands[0] {} else {
            XCTFail("expected the first command to be a chrome polyline")
        }
    }

    func testHiddenLayerProducesNoGeometry() {
        var document = self.document()
        for index in document.layers.indices { document.layers[index].isVisible = false }
        let built = build(document)
        XCTAssertTrue(built.probeCurves.isEmpty)
        // Only axes and grid remain.
        XCTAssertLessThan(built.scene.approximatePrimitiveCount, 60)
    }

    func testBrokenFormulaIsReportedAndDoesNotBreakTheRest() {
        var document = self.document()
        document.layers[0].formula = "sin(x"

        let compiler = LayerCompiler()
        let compiled = compiler.compile(document)
        XCTAssertNotNil(compiled[0].primaryError)
        XCTAssertEqual(compiled[0].primaryError?.column, 3, "the caret points at the unclosed paren")
        XCTAssertNil(compiled[1].primaryError)

        let request = SceneBuildRequest(
            document: document, compiled: compiled, viewport: document.viewport,
            quality: .full, backingScale: 2
        )
        let built = SceneBuilder2D.build(request)
        XCTAssertEqual(built.probeCurves.count, 3, "the other three layers still draw")
        for curve in built.probeCurves {
            XCTAssertNotEqual(curve.layerID, document.layers[0].id)
        }
    }

    func testParameterValueReachesTheCompiledExpression() {
        var document = self.document()
        document.layers = [Layer.makeDefault(kind: .explicit, index: 0)]
        document.layers[0].formula = "a*x"
        document.layers[0].usesExplicitDomain = true
        document.layers[0].domainLower = 0
        document.layers[0].domainUpper = 1
        document.parameters = [ParameterDefinition(name: "a", value: 3)]

        let built = build(document)
        let points = built.probeCurves[0].segments.flatMap { $0 }
        XCTAssertFalse(points.isEmpty)
        for point in points {
            XCTAssertEqual(point.y, 3 * point.x, accuracy: 1e-9)
        }
    }

    /// 限定定义域的显函数两端各有一个实心点，落在 (a, f(a))、(b, f(b))；不限定义域就没有。
    func testRestrictedDomainMarksBothEnds() {
        var document = self.document()
        document.layers = [Layer.makeDefault(kind: .explicit, index: 0)]
        document.layers[0].formula = "2*x"
        document.layers[0].usesExplicitDomain = true
        document.layers[0].domainLower = -1
        document.layers[0].domainUpper = 3

        let built = build(document)
        let markers = built.scene.commands.compactMap { command -> MarkerPrimitiveBatch? in
            if case .markers(let batch) = command { return batch }
            return nil
        }
        XCTAssertEqual(markers.count, 1)
        let positions = markers.first?.positions ?? []
        XCTAssertEqual(positions.count, 2)
        let viewport = document.viewport
        let expected = [viewport.toScreen(x: -1, y: -2), viewport.toScreen(x: 3, y: 6)]
        for (position, target) in zip(positions, expected) {
            XCTAssertEqual(position.x, target.x, accuracy: 1e-9)
            XCTAssertEqual(position.y, target.y, accuracy: 1e-9)
        }

        document.layers[0].usesExplicitDomain = false
        let unrestricted = build(document)
        XCTAssertFalse(unrestricted.scene.commands.contains { command in
            if case .markers = command { return true }
            return false
        }, "不限定义域就没有端点")
    }

    func testAllGeometryStaysFiniteEvenWithPoles() {
        var document = self.document()
        document.layers = [Layer.makeDefault(kind: .explicit, index: 0)]
        document.layers[0].formula = "1/x"
        document.layers[0].usesExplicitDomain = true
        document.layers[0].domainLower = -1
        document.layers[0].domainUpper = 1

        let built = build(document)
        for command in built.scene.commands {
            guard case .polyline(let primitive) = command else { continue }
            for point in primitive.points {
                XCTAssertTrue(point.x.isFinite && point.y.isFinite, "a pole leaked an infinity into the scene")
                XCTAssertLessThan(abs(point.x), 1e9)
                XCTAssertLessThan(abs(point.y), 1e9)
            }
        }
    }

    func testEveryLayerKindSurvivesTheSceneBuilder() {
        var document = GrapherDocument()
        document.viewport.widthPixels = 400
        document.viewport.heightPixels = 300
        document.viewport.scale = 40
        let planeKinds = PlotKind.cases(for: .plane)
        document.layers = planeKinds.enumerated().map { index, kind in
            Layer.makeDefault(kind: kind, index: index)
        }
        for index in document.layers.indices {
            document.layers[index].usesExplicitDomain = true
            document.layers[index].domainLower = -3
            document.layers[index].domainUpper = 3
        }

        let built = build(document)
        XCTAssertEqual(built.probeCurves.count, planeKinds.count)
        for curve in built.probeCurves {
            XCTAssertFalse(curve.segments.isEmpty, "\(curve.layerName) produced no geometry")
        }
    }

    // MARK: - Files

    func testDocumentRoundTripsThroughJSON() throws {
        var document = self.document()
        document.layers[0].formula = "cos(x)/x"
        document.layers[0].lineStyle.width = 2.75
        document.parameters = [ParameterDefinition(name: "a", value: 2.5, lowerBound: -1, upperBound: 9)]
        document.theme = .dark

        let data = try DocumentStore.encode(document)
        let restored = try DocumentStore.decode(data)
        XCTAssertEqual(restored, document)
    }

    func testDocumentSurvivesARealFileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grapher-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let original = document()
        try DocumentStore.save(original, to: url)
        let loaded = try DocumentStore.load(from: url)
        XCTAssertEqual(loaded, original)
    }

    func testPDFExportWritesAVectorPageOfTheRequestedSize() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grapher-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let built = build(document())
        try PDFExport.write(
            scene: built.scene,
            to: url,
            widthPoints: 450,
            heightPoints: 300,
            pixelsPerPoint: 2
        )

        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 500)
        XCTAssertEqual(String(decoding: data.prefix(5), as: UTF8.self), "%PDF-")

        let pdf = CGPDFDocument(url as CFURL)
        XCTAssertNotNil(pdf)
        XCTAssertEqual(pdf?.numberOfPages, 1)
        let box = pdf?.page(at: 1)?.getBoxRect(.mediaBox)
        XCTAssertEqual(box?.width ?? 0, 450, accuracy: 0.5)
        XCTAssertEqual(box?.height ?? 0, 300, accuracy: 0.5)
    }

    func testCSVExportHasOneRowPerSample() {
        let built = build(document())
        let text = CSVExport.string(curves: built.probeCurves)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.first, "layer,x,y")

        let expected = built.probeCurves.reduce(0) { total, curve in
            total + curve.segments.reduce(0) { $0 + $1.count }
        }
        XCTAssertEqual(lines.count - 1, expected)
        for line in lines.dropFirst().prefix(50) {
            XCTAssertEqual(line.split(separator: ",").count, 3)
        }
    }
}
