import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import GrapherKit
@testable import GrapherNG

/// 把 AI 当成用户：走真实的 MCP 工具目录与 JSON-RPC，一条条调用工具画图，再检查文档和渲染出来的图。
/// 覆盖「会不会画」（交线、投影、切平面、位置关系、数据图、文字）、「画错了怎么办」（报错带原因、不留半成品）
/// 和「没有写权限时」。
@MainActor
final class AgentScenarioTests: XCTestCase {

    // MARK: - 会话

    struct Reply {
        var isError: Bool
        var text: String
        var structured: MCPObject
        var image: CGImage?
    }

    @MainActor final class Session {
        let catalog = MCPCatalog()
        var documentID: String?
        private var nextID = 1

        init(writeAllowed: Bool = true) {
            catalog.isWriteAllowed = { writeAllowed }
            MCPTools.registerAll(into: catalog, facade: MCPFacade())
        }

        @discardableResult
        func call(_ name: String, _ arguments: [String: Any] = [:], document: Bool = true) async -> Reply {
            var arguments = arguments
            if document, arguments["document_id"] == nil, let documentID { arguments["document_id"] = documentID }
            let request: [String: Any] = [
                "jsonrpc": "2.0", "id": nextID, "method": "tools/call",
                "params": ["name": name, "arguments": arguments],
            ]
            nextID += 1
            let body = try! JSONSerialization.data(withJSONObject: request)
            let response = await MCPDispatcher.dispatch(body: body, catalog: catalog).responseObject
            let result = (response?["result"] as? MCPObject) ?? [:]
            let content = result["content"] as? [MCPObject] ?? []
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            var image: CGImage?
            if let encoded = content.first(where: { $0["type"] as? String == "image" })?["data"] as? String,
               let data = Data(base64Encoded: encoded),
               let source = CGImageSourceCreateWithData(data as CFData, nil) {
                image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            }
            return Reply(
                isError: result["isError"] as? Bool ?? false, text: text,
                structured: result["structuredContent"] as? MCPObject ?? [:], image: image)
        }

        /// 新建文档并记住它的 id。
        func open(_ dimension: String) async -> String {
            let reply = await call("create_document", ["dimension": dimension], document: false)
            let id = reply.structured["id"] as? String ?? ""
            documentID = id
            return id
        }

        /// 加一个图层，返回它的 id（失败时返回空串）。
        func add(_ kind: String, _ fields: [String: Any] = [:]) async -> String {
            var arguments = fields
            arguments["kind"] = kind
            let reply = await call("add_layer", arguments)
            return reply.structured["layerId"] as? String ?? ""
        }

        func layers() async -> [MCPObject] {
            await call("get_document").structured["layers"] as? [MCPObject] ?? []
        }

        func close() {
            for document in (GraphDocumentController.graphShared?.graphDocuments ?? []) where document.mcpID.uuidString == documentID {
                document.close()
            }
        }
    }

    /// 最后一扇窗口关掉时 App 会退出（既有约定），测试宿主跟着退出、测试被重启。
    /// 所以整个测试期间留一扇不关的窗口，每个用例只关自己开的。
    static var sentinel: GraphDocument?

    func agentSession() async throws -> Session {
        let controller = try XCTUnwrap(GraphDocumentController.graphShared, "测试宿主里没有文档控制器")
        if Self.sentinel == nil { Self.sentinel = controller.newDocument(dimension: .plane) }
        return Session()
    }

    // MARK: - 工具目录

    func testToolCatalogAdvertisesEverythingAnAgentNeeds() async throws {
        let session = Session()
        let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let response = await MCPDispatcher.dispatch(body: request, catalog: session.catalog).responseObject
        let tools = (response?["result"] as? MCPObject)?["tools"] as? [MCPObject] ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        for name in ["get_state", "get_document", "get_reference", "render_image", "create_document", "add_layer",
                     "update_layer", "remove_layer", "set_parameter", "set_view", "export_png", "relate", "draw_relation"] {
            XCTAssertTrue(names.contains(name), "缺工具 \(name)")
        }
        // 每个图型的字段说明都在 get_reference 里。
        let reference = await session.call("get_reference", document: false)
        for kind in PlotKind.allCases { XCTAssertTrue(reference.text.contains(kind.rawValue), "get_reference 漏了 \(kind.rawValue)") }
    }

    // MARK: - 立体图：交线 + 投影

    func testAgentDrawsASphereCutByAPlaneAndItsShadow() async throws {
        let session = try await agentSession()
        defer { session.close() }
        _ = await session.open("space")

        let sphere = await session.add("implicitSurface", ["formula": "x^2 + y^2 + z^2 - 7.84", "name": "Sphere", "opacity": 0.35])
        let plane = await session.add("surface", ["formula": "1", "name": "z = 1", "opacity": 0.35])
        XCTAssertFalse(sphere.isEmpty || plane.isEmpty)
        let cut = await session.add("surfaceIntersection", ["source_a": sphere, "source_b": plane, "name": "Circle", "color": "#d62728", "line_width": 3])
        XCTAssertFalse(cut.isEmpty)
        let shadow = await session.add("projection", ["source_a": cut, "target": "xy", "offset": -3.5, "projectors": true, "name": "Shadow"])
        XCTAssertFalse(shadow.isEmpty)

        let layers = await session.layers()
        XCTAssertEqual(layers.compactMap { $0["kind"] as? String },
                       ["implicitSurface", "surface", "surfaceIntersection", "projection"])
        XCTAssertNil(layers.first?["errors"])

        let picture = await session.call("render_image", ["width": 800, "height": 600])
        XCTAssertFalse(picture.isError, picture.text)
        let image = try XCTUnwrap(picture.image)
        XCTAssertEqual(image.width, 800)
        XCTAssertGreaterThan(inkFraction(of: image), 0.02, "球、平面、交圆和投影应该占画面不少地方")

        // 只留交线与投影：藏起两个曲面后画面更空，但还有东西。
        _ = await session.call("update_layer", ["layer_id": sphere, "visible": false])
        _ = await session.call("update_layer", ["layer_id": plane, "visible": false])
        let bareReply = await session.call("render_image", ["width": 800, "height": 600])
        let bare = try XCTUnwrap(bareReply.image)
        XCTAssertGreaterThan(inkFraction(of: bare), 0.001)
        XCTAssertLessThan(inkFraction(of: bare), inkFraction(of: image))
    }

    func testAgentBuildsViviani() async throws {
        let session = try await agentSession()
        defer { session.close() }
        _ = await session.open("space")
        let sphere = await session.add("implicitSurface", ["formula": "x^2 + y^2 + z^2 - 9", "opacity": 0.3])
        let cylinder = await session.add("implicitSurface", ["formula": "(x - 1.5)^2 + y^2 - 2.25", "opacity": 0.3])
        let curve = await session.add("surfaceIntersection", ["source_a": sphere, "source_b": cylinder, "line_width": 3])
        XCTAssertFalse(curve.isEmpty)
        let pictureReply = await session.call("render_image")
        let picture = try XCTUnwrap(pictureReply.image)
        XCTAssertGreaterThan(inkFraction(of: picture), 0.02)
    }

    // MARK: - 立体图：点线面的关系

    func testAgentAsksForRelationsAndDrawsTheHelpers() async throws {
        let session = try await agentSession()
        defer { session.close() }
        _ = await session.open("space")

        let plane = await session.add("implicitSurface", ["formula": "x + 2*y + 2*z - 6", "name": "Plane"])
        let point = await session.add("point", ["formula": "2", "secondary_formula": "2", "tertiary_formula": "2.5", "name": "P"])
        let line = await session.add("spaceCurve", ["formula": "-2 + t", "secondary_formula": "1 + t/2", "tertiary_formula": "2 - t/2",
                                                    "domain": [-1, 6], "name": "Line"])
        let sphere = await session.add("implicitSurface", ["formula": "x^2 + y^2 + z^2 - 4"])

        // 点到平面：距离 (2 + 4 + 5 − 6)/3 = 5/3，有垂足。
        let distance = await session.call("relate", ["layer_a": point, "layer_b": plane])
        XCTAssertFalse(distance.isError, distance.text)
        XCTAssertEqual(distance.structured["relation"] as? String, "point_off_plane")
        let measure = try XCTUnwrap((distance.structured["measures"] as? [MCPObject])?.first)
        XCTAssertEqual(measure["name"] as? String, "distance")
        XCTAssertEqual(try XCTUnwrap(measure["value"] as? Double), 5.0 / 3, accuracy: 1e-9)
        let foot = try XCTUnwrap((distance.structured["constructions"] as? [MCPObject])?.first)
        XCTAssertEqual(foot["type"] as? String, "point")

        // 直线与平面：交一点，夹角在 0…90 度之间。
        let pierce = await session.call("relate", ["layer_a": line, "layer_b": plane])
        XCTAssertEqual(pierce.structured["relation"] as? String, "line_meets_plane")
        let angle = try XCTUnwrap(((pierce.structured["measures"] as? [MCPObject])?.first?["value"]) as? Double)
        XCTAssertTrue((0.0...90.0).contains(angle), "夹角 \(angle)")

        // 球面不是点 / 线 / 平面：报错带原因。
        let bad = await session.call("relate", ["layer_a": sphere, "layer_b": plane])
        XCTAssertTrue(bad.isError)
        XCTAssertTrue(bad.text.contains("not a point, a straight line or a plane"), bad.text)

        // draw_relation 把垂足和垂线段加成图层，原来的图层不动。
        let before = await session.layers().count
        let drawn = await session.call("draw_relation", ["layer_a": point, "layer_b": plane])
        XCTAssertFalse(drawn.isError, drawn.text)
        XCTAssertEqual((drawn.structured["layerIds"] as? [String])?.count, 2)
        let after = await session.layers()
        XCTAssertEqual(after.count, before + 2)
        let kinds = after.suffix(2).compactMap { $0["kind"] as? String }
        XCTAssertEqual(Set(kinds), ["point", "spaceCurve"])
    }

    func testAgentGetsTheRelationOfSkewLinesAndTangentPlane() async throws {
        let session = try await agentSession()
        defer { session.close() }
        _ = await session.open("space")
        let first = await session.add("spaceCurve", ["formula": "t", "secondary_formula": "t/2", "tertiary_formula": "-1", "domain": [-3, 3]])
        let second = await session.add("spaceCurve", ["formula": "1.5", "secondary_formula": "-t", "tertiary_formula": "1 + t/2", "domain": [-3, 3]])
        let skew = await session.call("relate", ["layer_a": first, "layer_b": second])
        XCTAssertEqual(skew.structured["relation"] as? String, "lines_skew")
        XCTAssertEqual((skew.structured["constructions"] as? [MCPObject])?.first?["type"] as? String, "segment")

        // 切平面当平面用：碗 z = x² + y² 在原点的切平面是 z = 0，点 (0,0,3) 到它的距离是 3。
        let bowl = await session.add("surface", ["formula": "x^2 + y^2"])
        let tangent = await session.add("tangentPlane", ["source_a": bowl, "at": 0, "at2": 0])
        XCTAssertFalse(tangent.isEmpty)
        let top = await session.add("point", ["formula": "0", "secondary_formula": "0", "tertiary_formula": "3"])
        let reply = await session.call("relate", ["layer_a": top, "layer_b": tangent])
        let distance = try XCTUnwrap(((reply.structured["measures"] as? [MCPObject])?.first?["value"]) as? Double)
        XCTAssertEqual(distance, 3, accuracy: 1e-6)
    }

    // MARK: - 立体图：梯度场

    func testAgentVisualisesAGradient() async throws {
        let session = try await agentSession()
        defer { session.close() }
        _ = await session.open("space")
        let hill = await session.add("surface", ["formula": "3*exp(-(x^2 + y^2)/6)", "opacity": 0.55, "name": "Hill"])
        let torus = await session.add("implicitSurface", ["formula": "x^2 + y^2 + z^2 - 4"])
        XCTAssertFalse(hill.isEmpty)

        let field = await session.add("gradientField", ["source_a": hill, "density": 14, "line_width": 2.2])
        XCTAssertFalse(field.isEmpty)
        let flat = await session.add("gradientField", ["source_a": hill, "on_floor": true, "arrow_scale": -1.2, "density": 10])
        XCTAssertFalse(flat.isEmpty)

        let layers = await session.layers()
        let described = try XCTUnwrap(layers.first { $0["id"] as? String == flat })
        XCTAssertEqual(described["onFloor"] as? Bool, true)
        XCTAssertEqual(described["arrowScale"] as? Double, -1.2)
        XCTAssertEqual(described["density"] as? Int, 10)

        // 来源不是显式曲面、缺来源、参数超范围：都报错，什么都不加。
        let count = layers.count
        let wrongSource = await session.call("add_layer", ["kind": "gradientField", "source_a": torus])
        XCTAssertTrue(wrongSource.isError)
        XCTAssertTrue(wrongSource.text.contains("'surface'"), wrongSource.text)
        let missing = await session.call("add_layer", ["kind": "gradientField"])
        XCTAssertTrue(missing.isError)
        let tooDense = await session.call("update_layer", ["layer_id": field, "density": 400])
        XCTAssertTrue(tooDense.isError)
        let stray = await session.call("update_layer", ["layer_id": hill, "density": 5])
        XCTAssertTrue(stray.isError, "密度只给梯度场")
        let after = await session.layers().count
        XCTAssertEqual(after, count)

        let pictureReply = await session.call("render_image", ["width": 800, "height": 600])
        let picture = try XCTUnwrap(pictureReply.image)
        XCTAssertGreaterThan(inkFraction(of: picture), 0.02)
    }

    // MARK: - 平面图：切线、数据、文字

    func testAgentDrawsTangentsAndAScatterPlot() async throws {
        let session = try await agentSession()
        defer { session.close() }
        _ = await session.open("plane")

        let cubic = await session.add("explicit", ["formula": "x^3 - 3*x", "name": "y = x³ − 3x"])
        let tangent = await session.add("tangent", ["source_a": cubic, "at": 1.5])
        let normal = await session.add("tangent", ["source_a": cubic, "at": -0.5, "normal": true])
        XCTAssertFalse(tangent.isEmpty || normal.isEmpty)
        let scatter = await session.add("scatter", ["formula": "1, 2\n2, 4.1\n3, 5.9\n4, 8.2", "fit": true])
        XCTAssertFalse(scatter.isEmpty)
        _ = await session.add("text", ["formula": "tangent at x = 1.5", "at": 1.7, "at2": -1.5, "font_size": 16])

        let layers = await session.layers()
        let stats = try XCTUnwrap(layers.first { $0["kind"] as? String == "scatter" })
        XCTAssertEqual(stats["pointCount"] as? Int, 4)
        XCTAssertEqual(try XCTUnwrap(stats["slope"] as? Double), 2.02, accuracy: 0.05)
        XCTAssertGreaterThan(try XCTUnwrap(stats["r"] as? Double), 0.99)

        let pictureReply = await session.call("render_image", ["width": 800, "height": 600])
        let picture = try XCTUnwrap(pictureReply.image)
        XCTAssertGreaterThan(inkFraction(of: picture), 0.003)
    }

    func testAgentUsesParametersAndTheyDriveTheGraph() async throws {
        let session = try await agentSession()
        defer { session.close() }
        _ = await session.open("plane")
        let missing = await session.add("explicit", ["formula": "a*sin(x)"])
        XCTAssertTrue(missing.isEmpty, "参数没定义，公式被拒绝")
        _ = await session.call("set_parameter", ["name": "a", "value": 2, "min": 0, "max": 4])
        let layer = await session.add("explicit", ["formula": "a*sin(x)"])
        XCTAssertFalse(layer.isEmpty)
        let reply = await session.call("get_document")
        let parameters = reply.structured["parameters"] as? [MCPObject] ?? []
        XCTAssertEqual(parameters.first?["name"] as? String, "a")
    }

    // MARK: - 出错与权限

    func testMistakesComeBackAsReadableErrorsAndLeaveNothingHalfAdded() async throws {
        let session = try await agentSession()
        defer { session.close() }
        _ = await session.open("space")
        let sphere = await session.add("implicitSurface", ["formula": "x^2 + y^2 + z^2 - 4"])
        let count = await session.layers().count

        let brokenFormula = await session.call("add_layer", ["kind": "surface", "formula": "sin(x"])
        XCTAssertTrue(brokenFormula.isError)
        XCTAssertTrue(brokenFormula.text.contains("nothing was changed"), brokenFormula.text)

        let wrongDimension = await session.call("add_layer", ["kind": "region", "formula": "x^2 + y^2 - 1"])
        XCTAssertTrue(wrongDimension.isError)
        XCTAssertTrue(wrongDimension.text.contains("3D document cannot hold"), wrongDimension.text)

        let sameSource = await session.call("add_layer", ["kind": "surfaceIntersection", "source_a": sphere, "source_b": sphere])
        XCTAssertTrue(sameSource.isError)
        let missingSource = await session.call("add_layer", ["kind": "projection", "source_a": UUID().uuidString])
        XCTAssertTrue(missingSource.isError)
        let badKind = await session.call("add_layer", ["kind": "torus", "formula": "x"])
        XCTAssertTrue(badKind.isError)
        let badColor = await session.call("add_layer", ["kind": "point", "formula": "1", "secondary_formula": "1", "tertiary_formula": "1", "color": "red"])
        XCTAssertTrue(badColor.isError)

        let after = await session.layers().count
        XCTAssertEqual(after, count, "出错的调用一个图层都不能留下")
        let unknownDocument = await session.call("get_document", ["document_id": UUID().uuidString])
        XCTAssertTrue(unknownDocument.isError)
    }

    func testReadOnlyAgentCanLookButNotChange() async throws {
        // 先用有写权限的会话建好一份图，再换成只读会话。
        let writer = try await agentSession()
        defer { writer.close() }
        _ = await writer.open("space")
        let point = await writer.add("point", ["formula": "1", "secondary_formula": "2", "tertiary_formula": "3"])
        let plane = await writer.add("implicitSurface", ["formula": "z - 1"])

        let reader = Session(writeAllowed: false)
        reader.documentID = writer.documentID
        let write = await reader.call("add_layer", ["kind": "surface", "formula": "x"])
        XCTAssertTrue(write.isError, "没有写权限不能加图层")
        let create = await reader.call("create_document", ["dimension": "plane"], document: false)
        XCTAssertTrue(create.isError)
        let look = await reader.call("get_document")
        XCTAssertFalse(look.isError)
        let image = await reader.call("render_image")
        XCTAssertFalse(image.isError)
        XCTAssertNotNil(image.image)
        let relation = await reader.call("relate", ["layer_a": point, "layer_b": plane])
        XCTAssertFalse(relation.isError, "relate 是只读工具")
        XCTAssertEqual(relation.structured["relation"] as? String, "point_off_plane")
        let draw = await reader.call("draw_relation", ["layer_a": point, "layer_b": plane])
        XCTAssertTrue(draw.isError, "draw_relation 要写权限")
    }
}

extension AgentScenarioTests {
    /// 范围写成含参数的公式：调参数曲线跟着变长，写错报清楚，旧的数字范围改回来公式就清掉。
    func testAgentDrawsACurveGraduallyWithDomainFormulas() async throws {
        let session = try await agentSession()
        defer { session.close() }
        _ = await session.open("plane")
        _ = await session.call("set_parameter", ["name": "p", "value": 0.25, "min": 0, "max": 1])
        let curve = await session.add("parametric", [
            "formula": "3*sin(3*t)", "secondary_formula": "3*sin(2*t)",
            "domain_formulas": ["0", "p*2*pi"],
        ])
        XCTAssertFalse(curve.isEmpty)

        func described() async throws -> MCPObject {
            let all = await session.layers()
            return try XCTUnwrap(all.first { $0["id"] as? String == curve })
        }
        let first = try await described()
        XCTAssertEqual(first["domainFormulas"] as? [String], ["0", "p*2*pi"])
        XCTAssertNil(first["errors"])
        let small = await session.call("render_image", ["width": 600, "height": 400])
        _ = await session.call("set_parameter", ["name": "p", "value": 1])
        let full = await session.call("render_image", ["width": 600, "height": 400])
        XCTAssertFalse(small.isError || full.isError)
        let shortInk = inkFraction(of: try XCTUnwrap(small.image))
        let longInk = inkFraction(of: try XCTUnwrap(full.image))
        XCTAssertGreaterThan(longInk, shortInk, "p 越大曲线画得越长")

        // 公式里有没定义的名字：报错，原来的图层保持不变。
        let bad = await session.call("update_layer", ["layer_id": curve, "domain_formulas": ["0", "q*2"]])
        XCTAssertTrue(bad.isError)
        XCTAssertTrue(bad.text.contains("domain_formulas"), bad.text)
        let wrongShape = await session.call("update_layer", ["layer_id": curve, "domain_formulas": ["0"]])
        XCTAssertTrue(wrongShape.isError)
        let unchanged = try await described()
        XCTAssertEqual(unchanged["domainFormulas"] as? [String], ["0", "p*2*pi"])

        // 改回数字范围：公式清掉。
        _ = await session.call("update_layer", ["layer_id": curve, "domain": [0, 6.28]])
        let reset = try await described()
        XCTAssertNil(reset["domainFormulas"])
        // 不是参数范围的图型：报错。
        let surface = await session.call("add_layer", ["kind": "surface", "formula": "x", "domain_formulas": ["0", "1"]])
        XCTAssertTrue(surface.isError)
    }
}

extension AgentScenarioTests {
    /// 切点 / 文字 / 投影平面位置写成公式：助手建好后只改参数，图跟着动；写错报清楚。
    func testAgentSlidesATangentWithAParameter() async throws {
        let session = try await agentSession()
        defer { session.close() }
        _ = await session.open("plane")
        _ = await session.call("set_parameter", ["name": "p", "value": 1, "min": -2, "max": 2])
        let curve = await session.add("explicit", ["formula": "x^2"])
        let tangent = await session.add("tangent", ["source_a": curve, "at": "p"])
        XCTAssertFalse(tangent.isEmpty, "at 可以是公式")
        let label = await session.add("text", ["formula": "here", "at": "p", "at2": "p^2 + 0.5"])
        XCTAssertFalse(label.isEmpty)

        let layers = await session.layers()
        let described = try XCTUnwrap(layers.first { $0["id"] as? String == tangent })
        XCTAssertEqual((described["positionFormulas"] as? [String: String])?["at"], "p")
        XCTAssertNil(described["errors"])
        let first = await session.call("render_image", ["width": 500, "height": 400])
        _ = await session.call("set_parameter", ["name": "p", "value": -1.5])
        let second = await session.call("render_image", ["width": 500, "height": 400])
        XCTAssertFalse(first.isError || second.isError)
        XCTAssertNotNil(first.image)
        XCTAssertNotNil(second.image)

        // 公式里没定义的名字、空字符串：报错，不留半成品。
        let before = await session.layers().count
        let bad = await session.call("add_layer", ["kind": "tangent", "source_a": curve, "at": "q + 1"])
        XCTAssertTrue(bad.isError)
        XCTAssertTrue(bad.text.contains("position formula"), bad.text)
        let empty = await session.call("add_layer", ["kind": "tangent", "source_a": curve, "at": "  "])
        XCTAssertTrue(empty.isError)
        let after = await session.layers().count
        XCTAssertEqual(after, before)
        // 改回数字：公式清掉。
        _ = await session.call("update_layer", ["layer_id": tangent, "at": 0.5])
        let reset = await session.layers().first { $0["id"] as? String == tangent }
        XCTAssertNil(reset?["positionFormulas"])
    }
}
