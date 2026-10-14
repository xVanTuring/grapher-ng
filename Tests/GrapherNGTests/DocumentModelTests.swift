import XCTest
@testable import GrapherKit
@testable import GrapherNG

/// 文档模型：新窗口是空白文档、「加载示例」、经 NSDocument 读写与「已修改」标记。
@MainActor
final class DocumentModelTests: XCTestCase {

    func testNewDocumentsStartBlank() {
        let plane = GraphDocument()
        XCTAssertEqual(plane.state.document.dimension, .plane)
        XCTAssertTrue(plane.state.document.layers.isEmpty)
        XCTAssertTrue(plane.state.document.parameters.isEmpty)
        XCTAssertTrue(plane.isTransient)

        let space = GraphDocument(dimension: .space)
        XCTAssertEqual(space.state.document.dimension, .space)
        XCTAssertTrue(space.state.document.layers.isEmpty)
    }

    func testLoadExampleFillsTheDocumentAndMarksItEdited() {
        let document = GraphDocument()
        let theme = document.state.document.theme
        document.state.loadExample()

        let sample = GrapherDocument.sample()
        XCTAssertEqual(document.state.document.layers.map(\.formula), sample.layers.map(\.formula))
        XCTAssertEqual(document.state.document.parameters.map(\.name), sample.parameters.map(\.name))
        XCTAssertEqual(document.state.document.viewport.scale, sample.viewport.scale)
        XCTAssertEqual(document.state.document.theme, theme, "显示设置不跟着示例换")
        XCTAssertEqual(document.state.selection, document.state.document.layers.first?.id)
        XCTAssertTrue(document.isDocumentEdited)
        XCTAssertFalse(document.isTransient)
    }

    func testSpaceDocumentsLoadTheThreeDExample() {
        let document = GraphDocument(dimension: .space)
        document.state.loadExample()
        XCTAssertEqual(document.state.document.dimension, .space)
        XCTAssertEqual(document.state.document.layers.map(\.kind), GrapherDocument.sample3D().layers.map(\.kind))
    }

    func testDocumentRoundTripsThroughNSDocument() throws {
        let original = GraphDocument()
        original.state.loadExample()
        let data = try original.data(ofType: GraphDocument.typeName)

        let reopened = GraphDocument()
        try reopened.read(from: data, ofType: GraphDocument.typeName)
        XCTAssertEqual(reopened.state.document.layers, original.state.document.layers)
        XCTAssertEqual(reopened.state.document.parameters, original.state.document.parameters)
        XCTAssertEqual(reopened.state.selection, reopened.state.document.layers.first?.id)
        XCTAssertFalse(reopened.isDocumentEdited, "刚读进来的文档不算改过")
    }

    func testEditsMarkTheDocumentEdited() throws {
        let document = GraphDocument()
        XCTAssertFalse(document.isDocumentEdited)
        document.state.addLayer(.explicit)
        XCTAssertTrue(document.isDocumentEdited)
    }
}
