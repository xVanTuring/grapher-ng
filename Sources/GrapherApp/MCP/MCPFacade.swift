import AppKit
import GrapherKit
import GrapherRender
import ImageIO
import UniformTypeIdentifiers

/// MCP 工具与文档之间的唯一接口。所有改动都走界面用的同一批方法（`AppState.mutate` 等）：
/// AI 加的图层可以 ⌘Z 撤销，文档会标成「已编辑」，关窗时照样弹保存提示。
@MainActor
final class MCPFacade {

    // MARK: - 找文档

    var documents: [GraphDocument] { GraphDocumentController.graphShared?.graphDocuments ?? [] }

    /// 没指明 `document_id` 时的默认目标：最前面的图形窗口，再退而求其次取唯一开着的那份。
    func resolve(_ id: UUID?) throws -> GraphDocument {
        let open = documents
        if let id {
            guard let found = open.first(where: { $0.mcpID == id }) else {
                throw MCPToolError("No open document with id \(id.uuidString). Call get_state to list open documents.")
            }
            return found
        }
        if let current = NSDocumentController.shared.currentDocument as? GraphDocument { return current }
        if open.count == 1 { return open[0] }
        if open.isEmpty {
            throw MCPToolError("No document is open. Call create_document or open_document first.")
        }
        throw MCPToolError("Several documents are open; pass document_id. Call get_state to list them.")
    }

    // MARK: - 状态

    func state() -> MCPObject {
        let current = NSDocumentController.shared.currentDocument as? GraphDocument
        return [
            "writeAllowed": MCPSettings.allowsWrite,
            "documents": documents.map { summary(of: $0, isFront: $0 === current) },
        ]
    }

    private func summary(of document: GraphDocument, isFront: Bool) -> MCPObject {
        var object: MCPObject = [
            "id": document.mcpID.uuidString,
            "title": document.displayName ?? "Untitled",
            "dimension": document.state.document.dimension.rawValue,
            "layerCount": document.state.document.layers.count,
            "edited": document.isDocumentEdited,
            "isFront": isFront,
        ]
        if let path = document.fileURL?.path { object["path"] = path }
        return object
    }

    func describe(_ document: GraphDocument) -> MCPObject {
        let state = document.state
        let content = state.document
        var object = summary(of: document, isFront: document === NSDocumentController.shared.currentDocument)
        object["layers"] = content.layers.map { describe($0, in: state) }
        object["parameters"] = content.parameters.map { parameter -> MCPObject in
            [
                "name": parameter.name, "value": parameter.value,
                "min": parameter.lowerBound, "max": parameter.upperBound,
                "valid": parameter.isNameValid,
            ]
        }
        object["appearance"] = [
            "theme": content.theme == .dark ? "dark" : "light",
            "showGrid": content.showGrid, "showMinorGrid": content.showMinorGrid,
            "showAxes": content.showAxes, "showTickLabels": content.showTickLabels,
        ]
        if content.dimension == .space {
            let view = content.view3D
            object["view"] = [
                "center": [view.center.x, view.center.y, view.center.z],
                "halfExtent": view.halfExtent,
                "azimuthDegrees": view.azimuth * 180 / .pi,
                "elevationDegrees": view.elevation * 180 / .pi,
                "cameraZoom": view.cameraZoom,
            ]
        } else {
            let viewport = content.viewport
            object["view"] = [
                "centerX": viewport.centerX, "centerY": viewport.centerY, "scale": viewport.scale,
                "xRange": [viewport.xRange.lowerBound, viewport.xRange.upperBound],
                "yRange": [viewport.yRange.lowerBound, viewport.yRange.upperBound],
            ]
        }
        return object
    }

    private func describe(_ layer: Layer, in state: AppState) -> MCPObject {
        var object: MCPObject = [
            "id": layer.id.uuidString,
            "name": layer.name,
            "kind": layer.kind.rawValue,
            "visible": layer.isVisible,
            "formula": layer.formula,
            "color": Self.hex(layer.lineStyle.color),
            "lineWidth": layer.lineStyle.width,
            "dashed": layer.lineStyle.isDashed,
        ]
        if layer.kind.needsSecondaryFormula { object["secondaryFormula"] = layer.secondaryFormula }
        if layer.kind.needsTertiaryFormula { object["tertiaryFormula"] = layer.tertiaryFormula }
        if layer.kind.usesRelation { object["relation"] = layer.relation.symbol }
        if layer.kind.usesDomain {
            object["domain"] = [layer.domainLower, layer.domainUpper]
            object["usesExplicitDomain"] = layer.usesExplicitDomain
        }
        if layer.kind.usesSecondDomain { object["domain2"] = [layer.domain2Lower, layer.domain2Upper] }
        if layer.kind.canExtrude, state.document.dimension == .space { object["extrude"] = layer.extrudesInSpace }
        if layer.kind == .surfaceIntersection {
            object["sourceA"] = layer.sourceA?.uuidString ?? NSNull()
            object["sourceB"] = layer.sourceB?.uuidString ?? NSNull()
        }
        if let errors = state.formulaErrors[layer.id] {
            var messages: [String] = []
            if let error = errors.primary { messages.append("formula: \(error.description)") }
            if let error = errors.secondary { messages.append("secondary_formula: \(error.description)") }
            if let error = errors.tertiary { messages.append("tertiary_formula: \(error.description)") }
            object["errors"] = messages
        }
        return object
    }

    // MARK: - 新建 / 打开 / 保存

    func createDocument(dimension: DocumentDimension, example: Bool) throws -> GraphDocument {
        guard let controller = GraphDocumentController.graphShared else {
            throw MCPToolError("The document controller is not available.")
        }
        NSApp.activate()
        return controller.newDocument(dimension: dimension, example: example)
    }

    func openDocument(path: String) async throws -> GraphDocument {
        let url = try Self.fileURL(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MCPToolError("No such file: \(url.path)")
        }
        do {
            let document = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
            NSApp.activate()
            guard let graph = document as? GraphDocument else {
                throw MCPToolError("Not a Grapher NG document: \(url.path)")
            }
            return graph
        } catch let error as MCPToolError {
            throw error
        } catch {
            throw MCPToolError("Could not open \(url.path): \(error.localizedDescription)")
        }
    }

    func saveDocument(_ document: GraphDocument, path: String?) async throws -> String {
        let url: URL
        if let path {
            var target = try Self.fileURL(path)
            if target.pathExtension.isEmpty { target.appendPathExtension("grapher") }
            guard FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) else {
                throw MCPToolError("The folder does not exist: \(target.deletingLastPathComponent().path)")
            }
            url = target
        } else if let existing = document.fileURL {
            url = existing
        } else {
            throw MCPToolError("This document has never been saved; pass a path.")
        }
        let operation: NSDocument.SaveOperationType = document.fileURL == url ? .saveOperation : .saveAsOperation
        do {
            try await document.save(to: url, ofType: GraphDocument.typeName, for: operation)
        } catch {
            throw MCPToolError("Could not save \(url.path): \(error.localizedDescription)")
        }
        return url.path
    }

    private static func fileURL(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw MCPToolError("Pass an absolute path (or one starting with ~): \(path)") }
        return URL(fileURLWithPath: expanded)
    }

    // MARK: - 图层

    /// 一个图层各字段的改动。`nil` 表示不动；新建时缺省的字段取 `Layer.makeDefault` 的值。
    struct LayerEdit {
        var kind: PlotKind?
        var name: String?
        var formula: String?
        var secondaryFormula: String?
        var tertiaryFormula: String?
        var relation: RegionRelation?
        var domain: (Double, Double)?
        var domain2: (Double, Double)?
        var extrude: Bool?
        var sourceA: UUID?
        var sourceB: UUID?
        var color: RGBAColor?
        var lineWidth: Double?
        var dashed: Bool?
        var visible: Bool?
    }

    func addLayer(to document: GraphDocument, _ edit: LayerEdit) throws -> (Layer, [String]) {
        let state = document.state
        guard let kind = edit.kind else { throw MCPInvalidParams("missing required 'kind'") }
        let allowed = PlotKind.cases(for: state.document.dimension)
        guard allowed.contains(kind) else {
            let names = allowed.map(\.rawValue).joined(separator: ", ")
            throw MCPToolError(
                "A \(state.document.dimension == .space ? "3D" : "2D") document cannot hold '\(kind.rawValue)' layers. Allowed kinds: \(names)."
            )
        }
        if kind.needsFormula {
            guard let formula = edit.formula, !formula.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MCPInvalidParams("missing required 'formula'")
            }
        } else if edit.sourceA == nil || edit.sourceB == nil {
            throw MCPInvalidParams("'\(kind.rawValue)' layers need both 'source_a' and 'source_b' (layer ids)")
        }

        var layer = Layer.makeDefault(kind: kind, index: state.document.layers.count)
        // 参数方程、极坐标、空间曲线、参数曲面的参数范围总是生效（同 `AppState.addLayer`）。
        layer.usesExplicitDomain = kind.usesDomain && kind != .explicit
        try apply(edit, to: &layer)
        let warnings = try validate(layer, in: state)

        let id = layer.id
        let created = layer
        state.mutate(String(format: L("New %@"), kind.shortName)) { $0.layers.append(created) }
        state.selection = id
        return (created, warnings)
    }

    func updateLayer(in document: GraphDocument, id: UUID, _ edit: LayerEdit) throws -> (Layer, [String]) {
        let state = document.state
        guard var layer = state.layer(with: id) else {
            throw MCPToolError("No layer with id \(id.uuidString). Call get_document to list layers.")
        }
        if let kind = edit.kind, kind != layer.kind {
            throw MCPToolError("A layer's kind cannot change; remove it and add a new one.")
        }
        try apply(edit, to: &layer)
        let warnings = try validate(layer, in: state)

        let updated = layer
        state.mutate(L("Edit Layer")) { document in
            if let index = document.layers.firstIndex(where: { $0.id == id }) { document.layers[index] = updated }
        }
        return (updated, warnings)
    }

    func removeLayer(in document: GraphDocument, id: UUID) throws {
        guard document.state.layer(with: id) != nil else {
            throw MCPToolError("No layer with id \(id.uuidString). Call get_document to list layers.")
        }
        document.state.removeLayer(id: id)
    }

    private func apply(_ edit: LayerEdit, to layer: inout Layer) throws {
        if let name = edit.name { layer.name = name }
        if let formula = edit.formula { layer.formula = formula }
        if let secondary = edit.secondaryFormula {
            guard layer.kind.needsSecondaryFormula else {
                throw MCPToolError("'\(layer.kind.rawValue)' layers have no secondary_formula.")
            }
            layer.secondaryFormula = secondary
        }
        if let tertiary = edit.tertiaryFormula {
            guard layer.kind.needsTertiaryFormula else {
                throw MCPToolError("'\(layer.kind.rawValue)' layers have no tertiary_formula.")
            }
            layer.tertiaryFormula = tertiary
        }
        if let relation = edit.relation {
            guard layer.kind.usesRelation else { throw MCPToolError("Only 'region' layers have a relation.") }
            layer.relation = relation
        }
        if let domain = edit.domain {
            guard layer.kind.usesDomain else {
                throw MCPToolError("'\(layer.kind.rawValue)' layers have no parameter range; the range is the axis box / view.")
            }
            guard domain.0 < domain.1 else { throw MCPToolError("domain must be [min, max] with min < max.") }
            layer.domainLower = domain.0
            layer.domainUpper = domain.1
            layer.usesExplicitDomain = true
        }
        if let domain2 = edit.domain2 {
            guard layer.kind.usesSecondDomain else { throw MCPToolError("Only 'parametricSurface' layers have domain2.") }
            guard domain2.0 < domain2.1 else { throw MCPToolError("domain2 must be [min, max] with min < max.") }
            layer.domain2Lower = domain2.0
            layer.domain2Upper = domain2.1
        }
        if let extrude = edit.extrude {
            guard layer.kind.canExtrude else { throw MCPToolError("'\(layer.kind.rawValue)' layers cannot be extruded.") }
            layer.extrudesInSpace = extrude
        }
        if edit.sourceA != nil || edit.sourceB != nil {
            guard layer.kind == .surfaceIntersection else {
                throw MCPToolError("Only 'surfaceIntersection' layers have source_a / source_b.")
            }
            if let id = edit.sourceA { layer.sourceA = id }
            if let id = edit.sourceB { layer.sourceB = id }
        }
        if let color = edit.color {
            layer.lineStyle.color = color
            layer.fillStyle.color = color.withAlpha(layer.fillStyle.color.a)
        }
        if let width = edit.lineWidth {
            guard (0.2...20).contains(width) else { throw MCPToolError("line_width must be between 0.2 and 20.") }
            layer.lineStyle.width = width
        }
        if let dashed = edit.dashed { layer.lineStyle.isDashed = dashed }
        if let visible = edit.visible { layer.isVisible = visible }
    }

    /// 用文档当前的参数编译一遍：公式有错就拒绝（带列号），免得图层列表里躺一条红色报错的图层。
    /// 返回的警告：公式里用到了文档里没定义的名字之类，编译器本身不报错的情况留给 `get_document` 的 `errors`。
    private func validate(_ layer: Layer, in state: AppState) throws -> [String] {
        if layer.kind == .surfaceIntersection {
            try validateSources(layer, in: state)
            return []
        }
        let probe = GrapherDocument(
            dimension: state.document.dimension,
            layers: [layer],
            parameters: state.document.parameters
        )
        guard let compiled = LayerCompiler().compile(probe).first, compiled.hasError else { return [] }
        var messages: [String] = []
        if let error = compiled.primaryError { messages.append("formula: \(error.description)") }
        if let error = compiled.secondaryError { messages.append("secondary_formula: \(error.description)") }
        if let error = compiled.tertiaryError { messages.append("tertiary_formula: \(error.description)") }
        throw MCPToolError(
            "The formula was rejected, nothing was changed. " + messages.joined(separator: "; ")
                + ". Variables for '\(layer.kind.rawValue)': \(Self.variables(of: layer.kind)). "
                + "Define parameters with set_parameter first; see get_reference for the syntax."
        )
    }

    /// 交线的两个来源必须是本文档里两个不同的曲面图层。
    private func validateSources(_ layer: Layer, in state: AppState) throws {
        guard let a = layer.sourceA, let b = layer.sourceB else {
            throw MCPInvalidParams("'surfaceIntersection' layers need both 'source_a' and 'source_b' (layer ids)")
        }
        guard a != b else { throw MCPToolError("source_a and source_b must be two different layers.") }
        for (field, id) in [("source_a", a), ("source_b", b)] {
            guard let source = state.layer(with: id) else {
                throw MCPToolError("\(field): no layer with id \(id.uuidString). Call get_document to list layers.")
            }
            guard source.kind.isSurfaceSource else {
                throw MCPToolError("\(field) is a '\(source.kind.rawValue)' layer; it must be a surface, parametricSurface or implicitSurface layer.")
            }
        }
    }

    nonisolated static func variables(of kind: PlotKind) -> String {
        switch kind {
        case .explicit: return "x"
        case .parametric, .spaceCurve: return "t (all formulas)"
        case .polar: return "theta (or t)"
        case .implicit, .region, .surface: return "x, y"
        case .parametricSurface: return "u, v (all three formulas)"
        case .implicitSurface: return "x, y, z"
        case .surfaceIntersection: return "(none; it has no formula)"
        case .point: return "(none; only parameters and numbers)"
        }
    }

    // MARK: - 参数

    func setParameter(
        in document: GraphDocument, name: String, value: Double?, min: Double?, max: Double?
    ) throws -> ParameterDefinition {
        let state = document.state
        var parameter = state.document.parameters.first { $0.name == name }
            ?? ParameterDefinition(name: name, value: 1, lowerBound: -5, upperBound: 5)
        let isNew = !state.document.parameters.contains { $0.name == name }
        guard parameter.isNameValid else {
            throw MCPToolError(
                "'\(name)' is not a valid parameter name (letters, digits and _, not starting with a digit, and not a variable or function name such as x, t, u, e, pi, sin)."
            )
        }
        if let min { parameter.lowerBound = min }
        if let max { parameter.upperBound = max }
        guard parameter.lowerBound < parameter.upperBound else { throw MCPToolError("min must be less than max.") }
        if let value { parameter.value = value }
        // 滑块的范围要装得下当前值：值超出时把范围撑大，而不是悄悄把值夹回去。
        parameter.lowerBound = Swift.min(parameter.lowerBound, parameter.value)
        parameter.upperBound = Swift.max(parameter.upperBound, parameter.value)

        let updated = parameter
        state.mutate(isNew ? L("New Parameter") : L("Change Parameter")) { document in
            if let index = document.parameters.firstIndex(where: { $0.name == name }) {
                document.parameters[index] = updated
            } else {
                document.parameters.append(updated)
            }
        }
        return updated
    }

    func removeParameter(in document: GraphDocument, name: String) throws {
        guard let parameter = document.state.document.parameters.first(where: { $0.name == name }) else {
            throw MCPToolError("No parameter named '\(name)'.")
        }
        document.state.removeParameter(id: parameter.id)
    }

    // MARK: - 视图与外观

    struct ViewEdit {
        var fit = false
        var reset = false
        // 平面图
        var center: (Double, Double)?
        var scale: Double?
        // 立体图
        var center3D: [Double]?
        var halfExtent: Double?
        var azimuthDegrees: Double?
        var elevationDegrees: Double?
        var cameraZoom: Double?
    }

    func setView(of document: GraphDocument, _ edit: ViewEdit) throws {
        let state = document.state
        if edit.reset { state.resetView() }
        if state.document.dimension == .space {
            if edit.center != nil || edit.scale != nil {
                throw MCPToolError("This is a 3D document: use center (3 numbers), half_extent, azimuth, elevation, camera_zoom.")
            }
            if let halfExtent = edit.halfExtent, !View3D.halfExtentRange.contains(halfExtent) {
                throw MCPToolError("half_extent must be between \(View3D.halfExtentRange.lowerBound) and \(View3D.halfExtentRange.upperBound).")
            }
            if let zoom = edit.cameraZoom, !View3D.cameraZoomRange.contains(zoom) {
                throw MCPToolError("camera_zoom must be between \(View3D.cameraZoomRange.lowerBound) and \(View3D.cameraZoomRange.upperBound).")
            }
            state.mutateView3D { view in
                if let center = edit.center3D { view.center = SIMD3(center[0], center[1], center[2]) }
                if let halfExtent = edit.halfExtent { view.halfExtent = halfExtent }
                if let azimuth = edit.azimuthDegrees { view.azimuth = azimuth * .pi / 180 }
                if let elevation = edit.elevationDegrees {
                    let limit = View3D.elevationLimit
                    view.elevation = Swift.max(-limit, Swift.min(limit, elevation * .pi / 180))
                }
                if let zoom = edit.cameraZoom { view.cameraZoom = zoom }
            }
            if edit.center3D != nil || edit.halfExtent != nil { state.requestRebuild(interactive: false) }
        } else {
            if edit.center3D != nil || edit.halfExtent != nil || edit.azimuthDegrees != nil
                || edit.elevationDegrees != nil || edit.cameraZoom != nil {
                throw MCPToolError("This is a 2D document: use center (x, y) and scale (pixels per unit).")
            }
            if let scale = edit.scale, !(scale > 0) { throw MCPToolError("scale must be positive.") }
            state.mutateViewport { viewport in
                if let center = edit.center {
                    viewport.centerX = center.0
                    viewport.centerY = center.1
                }
                if let scale = edit.scale { viewport.scale = scale }
            }
            if edit.center != nil || edit.scale != nil { state.requestRebuild(interactive: false) }
        }
        document.updateChangeCount(.changeDone)
        if edit.fit { state.fitToContent() }
    }

    func setAppearance(
        of document: GraphDocument, dark: Bool?, grid: Bool?, minorGrid: Bool?, axes: Bool?, tickLabels: Bool?
    ) {
        document.state.mutate(L("Change Appearance")) { content in
            if let dark { content.theme = dark ? .dark : .light }
            if let grid { content.showGrid = grid }
            if let minorGrid { content.showMinorGrid = minorGrid }
            if let axes { content.showAxes = axes }
            if let tickLabels { content.showTickLabels = tickLabels }
        }
    }

    // MARK: - 图片

    /// 把文档按存下时的取景画成 PNG：给 `render_image`（让模型看结果）与 `export_png`（写文件）共用。
    func renderPNG(of document: GraphDocument, width: Int, height: Int) throws -> Data {
        let pointScale = Swift.max(1, Double(width) / 700)
        guard let image = GraphSnapshot.image(
            of: document.state.document,
            pixelWidth: width,
            pixelHeight: height,
            pointScale: pointScale,
            quality: .high,
            labels: true
        ) else {
            throw MCPToolError("Could not initialize the renderer.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw MCPToolError("Could not encode the PNG.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MCPToolError("Could not encode the PNG.") }
        return data as Data
    }

    func exportPNG(of document: GraphDocument, path: String, width: Int, height: Int) throws -> String {
        var url = try Self.fileURL(path)
        if url.pathExtension.lowercased() != "png" { url.appendPathExtension("png") }
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
            throw MCPToolError("The folder does not exist: \(url.deletingLastPathComponent().path)")
        }
        let data = try renderPNG(of: document, width: width, height: height)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw MCPToolError("Could not write \(url.path): \(error.localizedDescription)")
        }
        return url.path
    }

    // MARK: - 颜色

    nonisolated static func hex(_ color: RGBAColor) -> String {
        func byte(_ value: Double) -> Int { Int((Swift.max(0, Swift.min(1, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.r), byte(color.g), byte(color.b))
    }

    /// `#RRGGBB` 或 `RRGGBB`。
    nonisolated static func parseColor(_ text: String) throws -> RGBAColor {
        var digits = text.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            throw MCPInvalidParams("color must look like #RRGGBB, got '\(text)'")
        }
        return RGBAColor(
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    nonisolated static func parseRelation(_ text: String) throws -> RegionRelation {
        switch text {
        case "<": return .less
        case "<=", "≤": return .lessOrEqual
        case ">": return .greater
        case ">=", "≥": return .greaterOrEqual
        default: throw MCPInvalidParams("relation must be one of <, <=, >, >=, got '\(text)'")
        }
    }
}
