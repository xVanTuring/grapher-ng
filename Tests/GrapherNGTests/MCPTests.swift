import XCTest
@testable import GrapherKit
@testable import GrapherNG

/// MCP：协议路由、HTTP 解析、写权限闸门，以及工具背后的文档操作（公式校验、撤销、参数）。
@MainActor
final class MCPTests: XCTestCase {

    // MARK: - 协议

    private func makeCatalog(writeAllowed: Bool) -> MCPCatalog {
        let catalog = MCPCatalog()
        catalog.isWriteAllowed = { writeAllowed }
        catalog.register(MCPTool(
            name: "read_it", title: "r", description: "d", inputSchema: MCPSchema.object([:]), tier: .read
        ) { _ in MCPToolResult(text: "read") })
        catalog.register(MCPTool(
            name: "write_it", title: "w", description: "d", inputSchema: MCPSchema.object([:]), tier: .write
        ) { _ in MCPToolResult(text: "wrote") })
        catalog.register(MCPTool(
            name: "needs_number", title: "n", description: "d", inputSchema: MCPSchema.object([:]), tier: .read
        ) { args in MCPToolResult(text: "\(try args.double("n"))") })
        return catalog
    }

    private func dispatch(_ json: String, catalog: MCPCatalog) async -> MCPObject? {
        await MCPDispatcher.dispatch(body: Data(json.utf8), catalog: catalog).responseObject
    }

    func testInitializeAndToolsList() async throws {
        let catalog = makeCatalog(writeAllowed: false)
        let initialize = await dispatch(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#, catalog: catalog)
        let result = try XCTUnwrap(initialize?["result"] as? MCPObject)
        XCTAssertEqual(result["protocolVersion"] as? String, MCPProtocolVersion.supported)

        let list = await dispatch(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, catalog: catalog)
        let tools = try XCTUnwrap((list?["result"] as? MCPObject)?["tools"] as? [MCPObject])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["needs_number", "read_it", "write_it"])
    }

    func testNotificationsGetNoResponseAndUnknownMethodsAnError() async throws {
        let catalog = makeCatalog(writeAllowed: false)
        let note = await dispatch(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, catalog: catalog)
        XCTAssertNil(note)

        let unknown = await dispatch(#"{"jsonrpc":"2.0","id":3,"method":"nope"}"#, catalog: catalog)
        XCTAssertEqual(((unknown?["error"]) as? MCPObject)?["code"] as? Int, -32601)

        let garbage = await dispatch("not json", catalog: catalog)
        XCTAssertEqual(((garbage?["error"]) as? MCPObject)?["code"] as? Int, -32700)
    }

    func testWriteToolsAreRefusedUntilAllowed() async throws {
        for allowed in [false, true] {
            let catalog = makeCatalog(writeAllowed: allowed)
            let call = await dispatch(
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"write_it","arguments":{}}}"#,
                catalog: catalog
            )
            let result = try XCTUnwrap(call?["result"] as? MCPObject)
            XCTAssertEqual(result["isError"] as? Bool ?? false, !allowed, "写权限 \(allowed) 时的结果")
        }
        let readOnly = makeCatalog(writeAllowed: false)
        let read = await dispatch(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_it","arguments":{}}}"#,
            catalog: readOnly
        )
        XCTAssertNil((read?["result"] as? MCPObject)?["isError"], "读工具不受写权限影响")
    }

    func testBadArgumentsComeBackAsToolErrorsTheModelCanSee() async throws {
        let catalog = makeCatalog(writeAllowed: true)
        let call = await dispatch(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"needs_number","arguments":{"n":"x"}}}"#,
            catalog: catalog
        )
        let result = try XCTUnwrap(call?["result"] as? MCPObject)
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = ((result["content"] as? [MCPObject])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("'n'"), text)
    }

    func testArgsDistinguishBooleansFromNumbers() {
        let args = MCPArgs(raw: ["flag": true, "num": 3, "nothing": NSNull()])
        XCTAssertThrowsError(try args.optionalDouble("flag"))
        XCTAssertThrowsError(try args.optionalBool("num"))
        XCTAssertEqual(try args.optionalDouble("num"), 3)
        XCTAssertNil(try args.optionalDouble("nothing"))
        XCTAssertEqual(try args.optionalBool("flag"), true)
        XCTAssertThrowsError(try args.optionalDoubles("num", count: 2))
    }

    // MARK: - HTTP 与鉴权

    func testHTTPParserWaitsForTheWholeBodyAcrossChunks() throws {
        let parser = MCPHTTPRequestParser()
        let body = #"{"a":1}"#
        let head = "POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer t\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        XCTAssertNil(try parser.feed(Data(head.utf8)))
        XCTAssertNil(try parser.feed(Data(body.prefix(3).utf8)))
        let request = try XCTUnwrap(try parser.feed(Data(body.dropFirst(3).utf8)))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.headers["authorization"], "Bearer t")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), body)
    }

    func testHTTPParserRejectsHugeBodiesAndBrokenRequestLines() {
        XCTAssertThrowsError(try MCPHTTPRequestParser().feed(Data("POST /mcp HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)))
        XCTAssertThrowsError(try MCPHTTPRequestParser().feed(Data("GARBAGE\r\n\r\n".utf8)))
    }

    func testOriginCheckOnlyAcceptsLocalPages() {
        XCTAssertTrue(MCPServer.isOriginAllowed("http://localhost:3000"))
        XCTAssertTrue(MCPServer.isOriginAllowed("http://127.0.0.1"))
        XCTAssertFalse(MCPServer.isOriginAllowed("http://localhost.evil.com"))
        XCTAssertFalse(MCPServer.isOriginAllowed("https://example.com"))
    }

    func testTokenComparison() {
        XCTAssertTrue(MCPServer.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(MCPServer.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(MCPServer.constantTimeEquals("abc", "abcd"))
    }

    // MARK: - 图层

    private func edit(
        kind: PlotKind, formula: String, secondary: String? = nil, tertiary: String? = nil
    ) -> MCPFacade.LayerEdit {
        var edit = MCPFacade.LayerEdit()
        edit.kind = kind
        edit.formula = formula
        edit.secondaryFormula = secondary
        edit.tertiaryFormula = tertiary
        return edit
    }

    func testAddLayerInsertsValidatedLayersAndCanBeUndone() async throws {
        let document = GraphDocument()
        let facade = MCPFacade()
        let (layer, _) = try facade.addLayer(to: document, edit(kind: .explicit, formula: "sin(x)"))

        XCTAssertEqual(document.state.document.layers.map(\.id), [layer.id])
        XCTAssertEqual(document.state.selection, layer.id)
        XCTAssertTrue(document.isDocumentEdited)
        document.undoManager?.undo()
        // `AppState` 在撤销回调里经 Task 回到主线程恢复文档，等它跑完。
        for _ in 0..<20 where !document.state.document.layers.isEmpty { await Task.yield() }
        XCTAssertTrue(document.state.document.layers.isEmpty, "AI 加的图层能用 ⌘Z 撤销")
    }

    func testBrokenFormulaChangesNothingAndNamesTheColumn() throws {
        let document = GraphDocument()
        let facade = MCPFacade()
        XCTAssertThrowsError(try facade.addLayer(to: document, edit(kind: .explicit, formula: "sin(x"))) { error in
            let message = (error as? MCPToolError)?.message ?? ""
            XCTAssertTrue(message.contains("nothing was changed"), message)
            XCTAssertTrue(message.contains("4"), "要带列号：\(message)")
        }
        XCTAssertTrue(document.state.document.layers.isEmpty)
        // 文档里没定义的参数也算公式错误。
        XCTAssertThrowsError(try facade.addLayer(to: document, edit(kind: .explicit, formula: "q*x")))
    }

    func testParametersMakeFormulasValid() throws {
        let document = GraphDocument()
        let facade = MCPFacade()
        let parameter = try facade.setParameter(in: document, name: "a", value: 7, min: nil, max: nil)
        XCTAssertEqual(parameter.value, 7)
        XCTAssertGreaterThanOrEqual(parameter.upperBound, 7, "滑块范围要装得下当前值")
        XCTAssertNoThrow(try facade.addLayer(to: document, edit(kind: .explicit, formula: "a*x")))

        XCTAssertThrowsError(try facade.setParameter(in: document, name: "x", value: 1, min: nil, max: nil))
        XCTAssertThrowsError(try facade.setParameter(in: document, name: "b", value: 1, min: 3, max: 2))
    }

    func testKindsMustMatchTheDocumentDimension() throws {
        let plane = GraphDocument()
        let space = GraphDocument(dimension: .space)
        let facade = MCPFacade()
        XCTAssertThrowsError(try facade.addLayer(to: plane, edit(kind: .surface, formula: "x*y")))
        XCTAssertThrowsError(try facade.addLayer(to: space, edit(kind: .region, formula: "x^2+y^2-1")))
        XCTAssertNoThrow(try facade.addLayer(to: space, edit(kind: .surface, formula: "x*y")))
        var extruded = edit(kind: .implicit, formula: "x^2+y^2-4")
        extruded.extrude = true
        let (layer, _) = try facade.addLayer(to: space, extruded)
        XCTAssertTrue(layer.extrudesInSpace)
    }

    func testParametricKindsNeedTheirOtherFormulas() throws {
        let space = GraphDocument(dimension: .space)
        let facade = MCPFacade()
        // 空间曲线缺 y、z：编译不过，不能留下半成品图层。
        XCTAssertThrowsError(try facade.addLayer(to: space, edit(kind: .spaceCurve, formula: "cos(t)", secondary: "", tertiary: "")))
        XCTAssertNoThrow(try facade.addLayer(
            to: space, edit(kind: .spaceCurve, formula: "cos(t)", secondary: "sin(t)", tertiary: "t/4")
        ))
        XCTAssertThrowsError(try facade.addLayer(to: GraphDocument(), edit(kind: .explicit, formula: "x", secondary: "x")))
    }

    func testSurfaceIntersectionNeedsTwoDifferentSurfaceSources() throws {
        let space = GraphDocument(dimension: .space)
        let facade = MCPFacade()
        let (sphere, _) = try facade.addLayer(to: space, edit(kind: .implicitSurface, formula: "x^2+y^2+z^2-4"))
        let (plane, _) = try facade.addLayer(to: space, edit(kind: .surface, formula: "1"))
        let (curve, _) = try facade.addLayer(
            to: space, edit(kind: .spaceCurve, formula: "cos(t)", secondary: "sin(t)", tertiary: "t/4"))

        var intersection = MCPFacade.LayerEdit()
        intersection.kind = .surfaceIntersection
        XCTAssertThrowsError(try facade.addLayer(to: space, intersection), "缺来源")
        intersection.sourceA = sphere.id
        intersection.sourceB = sphere.id
        XCTAssertThrowsError(try facade.addLayer(to: space, intersection), "两个来源相同")
        intersection.sourceB = curve.id
        XCTAssertThrowsError(try facade.addLayer(to: space, intersection), "空间曲线不是曲面")
        intersection.sourceB = UUID()
        XCTAssertThrowsError(try facade.addLayer(to: space, intersection), "来源不存在")

        intersection.sourceB = plane.id
        let (layer, _) = try facade.addLayer(to: space, intersection)
        XCTAssertEqual(layer.kind, .surfaceIntersection)
        XCTAssertEqual(layer.sourceA, sphere.id)
        XCTAssertEqual(layer.sourceB, plane.id)
        XCTAssertThrowsError(try facade.addLayer(to: GraphDocument(), intersection), "平面图里没有交线")

        var stray = MCPFacade.LayerEdit()
        stray.sourceA = sphere.id
        XCTAssertThrowsError(try facade.updateLayer(in: space, id: plane.id, stray), "只有交线图层有来源")
    }

    func testPointLabelOption() throws {
        let space = GraphDocument(dimension: .space)
        let facade = MCPFacade()
        var point = edit(kind: .point, formula: "1", secondary: "2", tertiary: "3")
        let (created, _) = try facade.addLayer(to: space, point)
        XCTAssertTrue(created.showsLabel, "点默认写出名称")
        point.showsLabel = false
        let (hidden, _) = try facade.addLayer(to: space, point)
        XCTAssertFalse(hidden.showsLabel)

        let (surface, _) = try facade.addLayer(to: space, edit(kind: .surface, formula: "x"))
        var stray = MCPFacade.LayerEdit()
        stray.showsLabel = true
        XCTAssertThrowsError(try facade.updateLayer(in: space, id: surface.id, stray), "只有点有名称")
    }

    func testProjectionLayerValidatesItsSourceAndTarget() throws {
        let space = GraphDocument(dimension: .space)
        let facade = MCPFacade()
        let (curve, _) = try facade.addLayer(
            to: space, edit(kind: .spaceCurve, formula: "cos(t)", secondary: "sin(t)", tertiary: "t/4"))
        let (surface, _) = try facade.addLayer(to: space, edit(kind: .surface, formula: "x*y"))
        let (wall, _) = try facade.addLayer(to: space, edit(kind: .implicitSurface, formula: "x + y + z - 1"))

        var projection = MCPFacade.LayerEdit()
        projection.kind = .projection
        XCTAssertThrowsError(try facade.addLayer(to: space, projection), "缺来源")
        projection.sourceA = surface.id
        XCTAssertThrowsError(try facade.addLayer(to: space, projection), "曲面不能当投影来源")
        projection.sourceA = curve.id
        let (onFloor, _) = try facade.addLayer(to: space, projection)
        XCTAssertEqual(onFloor.projectionTarget, .xy)

        projection.projectionTarget = .plane
        XCTAssertThrowsError(try facade.addLayer(to: space, projection), "target plane 缺 source_b")
        projection.sourceB = surface.id
        XCTAssertThrowsError(try facade.addLayer(to: space, projection), "x*y 曲面不是平面")
        projection.sourceB = wall.id
        let (onWall, _) = try facade.addLayer(to: space, projection)
        XCTAssertEqual(onWall.sourceB, wall.id)

        var stray = MCPFacade.LayerEdit()
        stray.projectionOffset = 1
        XCTAssertThrowsError(try facade.updateLayer(in: space, id: curve.id, stray), "只有投影图层有 offset")
        let (moved, _) = try facade.updateLayer(in: space, id: onFloor.id, stray)
        XCTAssertEqual(moved.projectionOffset, 1)
    }

    func testUpdateAndRemoveLayer() throws {
        let document = GraphDocument()
        let facade = MCPFacade()
        let (layer, _) = try facade.addLayer(to: document, edit(kind: .explicit, formula: "x"))

        var change = MCPFacade.LayerEdit()
        change.formula = "x^2"
        change.color = try MCPFacade.parseColor("#102030")
        change.visible = false
        let (updated, _) = try facade.updateLayer(in: document, id: layer.id, change)
        XCTAssertEqual(updated.formula, "x^2")
        XCTAssertEqual(MCPFacade.hex(updated.lineStyle.color), "#102030")
        XCTAssertFalse(document.state.document.layers[0].isVisible)

        var bad = MCPFacade.LayerEdit()
        bad.formula = "x^^"
        XCTAssertThrowsError(try facade.updateLayer(in: document, id: layer.id, bad))
        XCTAssertEqual(document.state.document.layers[0].formula, "x^2", "写错的公式不落地")

        var kindChange = MCPFacade.LayerEdit()
        kindChange.kind = .polar
        XCTAssertThrowsError(try facade.updateLayer(in: document, id: layer.id, kindChange))

        try facade.removeLayer(in: document, id: layer.id)
        XCTAssertTrue(document.state.document.layers.isEmpty)
        XCTAssertThrowsError(try facade.removeLayer(in: document, id: layer.id))
    }

    func testDomainAndRelationRules() throws {
        let document = GraphDocument()
        let facade = MCPFacade()
        var polar = edit(kind: .polar, formula: "1+cos(theta)")
        polar.domain = (0, 3)
        let (layer, _) = try facade.addLayer(to: document, polar)
        XCTAssertEqual(layer.domainUpper, 3)
        XCTAssertTrue(layer.usesExplicitDomain)

        var backwards = edit(kind: .polar, formula: "theta")
        backwards.domain = (3, 0)
        XCTAssertThrowsError(try facade.addLayer(to: document, backwards))

        var region = edit(kind: .region, formula: "x^2+y^2-1")
        region.relation = .greater
        XCTAssertEqual(try facade.addLayer(to: document, region).0.relation, .greater)
        var wrong = edit(kind: .explicit, formula: "x")
        wrong.relation = .less
        XCTAssertThrowsError(try facade.addLayer(to: document, wrong))
    }

    // MARK: - 视图、外观与图片

    func testSetViewRespectsDimension() throws {
        let facade = MCPFacade()
        let plane = GraphDocument()
        var edit2D = MCPFacade.ViewEdit()
        edit2D.center = (3, -2)
        edit2D.scale = 40
        try facade.setView(of: plane, edit2D)
        XCTAssertEqual(plane.state.document.viewport.centerX, 3)
        XCTAssertEqual(plane.state.document.viewport.scale, 40)
        var wrong = MCPFacade.ViewEdit()
        wrong.azimuthDegrees = 10
        XCTAssertThrowsError(try facade.setView(of: plane, wrong))

        let space = GraphDocument(dimension: .space)
        var edit3D = MCPFacade.ViewEdit()
        edit3D.azimuthDegrees = 90
        edit3D.elevationDegrees = 120
        try facade.setView(of: space, edit3D)
        XCTAssertEqual(space.state.document.view3D.azimuth, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(space.state.document.view3D.elevation, View3D.elevationLimit, accuracy: 1e-9, "仰角夹在上限内")
        XCTAssertThrowsError(try facade.setView(of: space, edit2D))
    }

    func testRenderPNGProducesAPictureOfTheRequestedSize() throws {
        let document = GraphDocument()
        let facade = MCPFacade()
        _ = try facade.addLayer(to: document, edit(kind: .explicit, formula: "sin(x)"))
        let png = try facade.renderPNG(of: document, width: 320, height: 200)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "PNG 文件头")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 200)
    }

    func testColorParsing() throws {
        XCTAssertEqual(MCPFacade.hex(try MCPFacade.parseColor("#FF8000")), "#FF8000")
        XCTAssertEqual(MCPFacade.hex(try MCPFacade.parseColor("00ff00")), "#00FF00")
        XCTAssertThrowsError(try MCPFacade.parseColor("red"))
        XCTAssertThrowsError(try MCPFacade.parseColor("#12345"))
        XCTAssertEqual(try MCPFacade.parseRelation("<="), .lessOrEqual)
        XCTAssertThrowsError(try MCPFacade.parseRelation("="))
    }

    func testReferenceMentionsEveryPlotKind() {
        for kind in PlotKind.allCases {
            XCTAssertTrue(MCPTools.reference.contains(kind.rawValue), "get_reference 漏了 \(kind.rawValue)")
        }
    }
}
