import AppKit
import GrapherKit
import GrapherRender
import simd
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
            if !(layer.domainLowerFormula + layer.domainUpperFormula).isEmpty {
                object["domainFormulas"] = [layer.domainLowerFormula, layer.domainUpperFormula]
            }
        }
        if layer.kind.usesSecondDomain { object["domain2"] = [layer.domain2Lower, layer.domain2Upper] }
        if layer.kind.canExtrude, state.document.dimension == .space { object["extrude"] = layer.extrudesInSpace }
        if layer.kind == .point { object["label"] = layer.showsLabel }
        if layer.kind == .scatter {
            let points = ScatterData.parse(layer.formula)
            object["pointCount"] = points.count
            object["fit"] = layer.showsFit
            if let fit = ScatterData.fit(points) {
                object["slope"] = fit.slope
                object["intercept"] = fit.intercept
                if let r = fit.correlation { object["r"] = r }
            }
        }
        if layer.kind == .text {
            object["at"] = layer.anchorU
            object["at2"] = layer.anchorV
            if state.document.dimension == .space { object["at3"] = layer.anchorW }
            object["fontSize"] = layer.fontSize
        }
        // 位置写成公式的，一并给出（数只是没写公式时用的值）。
        let positionFormulas = ["at": layer.anchorUFormula, "at2": layer.anchorVFormula, "at3": layer.anchorWFormula,
                                "offset": layer.projectionOffsetFormula].filter { !$0.value.isEmpty }
        if !positionFormulas.isEmpty { object["positionFormulas"] = positionFormulas }
        if layer.kind == .surface { object["colorBySlope"] = layer.colorsBySlope }
        if layer.kind == .gradientField {
            object["sourceA"] = layer.sourceA?.uuidString ?? NSNull()
            object["density"] = layer.gridDensity
            object["arrowScale"] = layer.arrowScale
            object["onFloor"] = layer.gradientOnFloor
        }
        if layer.kind == .gradientFlow {
            object["sourceA"] = layer.sourceA?.uuidString ?? NSNull()
            object["seeds"] = ScatterData.parse(layer.formula).map { [$0.x, $0.y] }
            object["progress"] = layer.secondaryFormula
            object["descent"] = layer.arrowScale < 0
            object["onFloor"] = layer.gradientOnFloor
        }
        if layer.kind == .tangent || layer.kind == .tangentPlane {
            object["sourceA"] = layer.sourceA?.uuidString ?? NSNull()
            object["at"] = layer.anchorU
            if layer.kind == .tangentPlane { object["at2"] = layer.anchorV } else { object["normal"] = layer.drawsNormal }
        }
        if layer.kind == .projection {
            object["sourceA"] = layer.sourceA?.uuidString ?? NSNull()
            object["target"] = layer.projectionTarget.rawValue
            if layer.projectionTarget == .plane {
                object["sourceB"] = layer.sourceB?.uuidString ?? NSNull()
            } else {
                object["offset"] = layer.projectionOffset
            }
            object["projectors"] = layer.showsProjectors
            if let direction = layer.projectionDirection { object["direction"] = [direction.x, direction.y, direction.z] }
        }
        if layer.kind == .surfaceIntersection {
            object["sourceA"] = layer.sourceA?.uuidString ?? NSNull()
            object["sourceB"] = layer.sourceB?.uuidString ?? NSNull()
        }
        if let errors = state.formulaErrors[layer.id] {
            var messages: [String] = []
            if let error = errors.domain { messages.append("domain_formulas: \(error.description)") }
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
        /// 范围两端的表达式（可含参数，空串 = 这一端用数）。
        var domainFormulas: (String, String)?
        var domain2Formulas: (String, String)?
        var extrude: Bool?
        var sourceA: UUID?
        var sourceB: UUID?
        var colorsBySlope: Bool?
        var gridDensity: Int?
        var arrowScale: Double?
        var gradientOnFloor: Bool?
        var opacity: Double?
        var showsFit: Bool?
        var showsLabel: Bool?
        /// 位置类的数也可以给公式：公式在 `…Formula` 里，数填 0 占位（让「该类型有没有这个字段」的检查照常走）。
        var anchorU: Double?
        var anchorV: Double?
        var anchorW: Double?
        var anchorUFormula: String?
        var anchorVFormula: String?
        var anchorWFormula: String?
        var projectionOffsetFormula: String?
        var fontSize: Double?
        var drawsNormal: Bool?
        var projectionTarget: ProjectionTarget?
        var projectionOffset: Double?
        /// 斜投影方向；全零表示改回正投影。
        var projectionDirection: SIMD3<Double>?
        var showsProjectors: Bool?
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
        if kind == .text || kind == .scatter {
            guard let text = edit.formula, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPInvalidParams(kind == .text
                    ? "'text' layers need 'formula': the text to write"
                    : "'scatter' layers need 'formula': one \"x, y\" point per line")
            }
        } else if kind.needsFormula {
            guard let formula = edit.formula, !formula.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MCPInvalidParams("missing required 'formula'")
            }
        } else if kind == .gradientFlow {
            if edit.sourceA == nil {
                throw MCPInvalidParams("'gradientFlow' layers need 'source_a' (the id of a surface layer z = f(x, y))")
            }
            guard let seeds = edit.formula, !ScatterData.parse(seeds).isEmpty else {
                throw MCPInvalidParams("'gradientFlow' layers need 'formula': the starting points, one \"x, y\" per line")
            }
        } else if kind == .gradientField {
            if edit.sourceA == nil {
                throw MCPInvalidParams("'gradientField' layers need 'source_a' (the id of a surface layer z = f(x, y))")
            }
        } else if kind == .projection {
            if edit.sourceA == nil { throw MCPInvalidParams("'projection' layers need 'source_a' (the layer to project)") }
        } else if kind == .tangent || kind == .tangentPlane {
            if edit.sourceA == nil {
                throw MCPInvalidParams("'\(kind.rawValue)' layers need 'source_a' (the curve / surface layer) and 'at'")
            }
            if edit.anchorU == nil { throw MCPInvalidParams("'\(kind.rawValue)' layers need 'at' (the tangent point)") }
            if kind == .tangentPlane, edit.anchorV == nil {
                throw MCPInvalidParams("'tangentPlane' layers need both 'at' and 'at2' (x, y or u, v)")
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
            guard layer.kind.needsSecondaryFormula || layer.kind == .gradientFlow else {
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
            layer.domainLowerFormula = ""
            layer.domainUpperFormula = ""
            layer.usesExplicitDomain = true
        }
        if let formulas = edit.domainFormulas {
            guard layer.kind.usesDomain else {
                throw MCPToolError("'\(layer.kind.rawValue)' layers have no parameter range; the range is the axis box / view.")
            }
            // 空串 = 这一端回到上面的数。
            layer.domainLowerFormula = formulas.0.trimmingCharacters(in: .whitespaces)
            layer.domainUpperFormula = formulas.1.trimmingCharacters(in: .whitespaces)
            layer.usesExplicitDomain = true
        }
        if let formulas = edit.domain2Formulas {
            guard layer.kind.usesSecondDomain else { throw MCPToolError("Only 'parametricSurface' layers have domain2_formulas.") }
            layer.domain2LowerFormula = formulas.0.trimmingCharacters(in: .whitespaces)
            layer.domain2UpperFormula = formulas.1.trimmingCharacters(in: .whitespaces)
        }
        if let domain2 = edit.domain2 {
            guard layer.kind.usesSecondDomain else { throw MCPToolError("Only 'parametricSurface' layers have domain2.") }
            guard domain2.0 < domain2.1 else { throw MCPToolError("domain2 must be [min, max] with min < max.") }
            layer.domain2Lower = domain2.0
            layer.domain2Upper = domain2.1
            layer.domain2LowerFormula = ""
            layer.domain2UpperFormula = ""
        }
        if let extrude = edit.extrude {
            guard layer.kind.canExtrude else { throw MCPToolError("'\(layer.kind.rawValue)' layers cannot be extruded.") }
            layer.extrudesInSpace = extrude
        }
        if edit.projectionTarget != nil || edit.projectionOffset != nil || edit.showsProjectors != nil
            || edit.projectionDirection != nil {
            guard layer.kind == .projection else {
                throw MCPToolError("Only 'projection' layers have target / offset / projectors / direction.")
            }
            if let direction = edit.projectionDirection {
                layer.projectionDirection = simd_length(direction) > 1e-9 ? direction : nil
            }
            if let target = edit.projectionTarget { layer.projectionTarget = target }
            if let offset = edit.projectionOffset { layer.projectionOffset = offset }
            if let projectors = edit.showsProjectors { layer.showsProjectors = projectors }
        }
        if edit.sourceA != nil || edit.sourceB != nil {
            guard layer.kind == .surfaceIntersection || layer.kind == .projection
                    || layer.kind == .tangent || layer.kind == .tangentPlane || layer.kind == .gradientField
                    || layer.kind == .gradientFlow else {
                throw MCPToolError("Only 'surfaceIntersection', 'projection', 'tangent', 'tangentPlane', 'gradientField' and 'gradientFlow' layers have source_a / source_b.")
            }
            if let id = edit.sourceA { layer.sourceA = id }
            if let id = edit.sourceB { layer.sourceB = id }
        }
        if layer.kind == .text {
            if let size = edit.fontSize {
                guard (6...96).contains(size) else { throw MCPToolError("font_size must be between 6 and 96.") }
                layer.fontSize = size
            }
            if let w = edit.anchorW {
                guard w.isFinite else { throw MCPToolError("at3 must be a finite number.") }
                layer.anchorW = w
            }
            if edit.drawsNormal != nil { throw MCPToolError("'text' layers have no normal.") }
            for (name, value, keyPath) in [("at", edit.anchorU, \Layer.anchorU), ("at2", edit.anchorV, \Layer.anchorV)] {
                guard let value else { continue }
                guard value.isFinite else { throw MCPToolError("\(name) must be a finite number.") }
                layer[keyPath: keyPath] = value
            }
        } else if edit.fontSize != nil || edit.anchorW != nil {
            throw MCPToolError("Only 'text' layers have at3 / font_size.")
        } else if edit.anchorU != nil || edit.anchorV != nil || edit.drawsNormal != nil {
            guard layer.kind == .tangent || layer.kind == .tangentPlane else {
                throw MCPToolError("Only 'tangent', 'tangentPlane' and 'text' layers have at / at2 / normal.")
            }
            if let u = edit.anchorU {
                guard u.isFinite else { throw MCPToolError("at must be a finite number.") }
                layer.anchorU = u
            }
            if let v = edit.anchorV {
                guard layer.kind == .tangentPlane else { throw MCPToolError("Only 'tangentPlane' layers have at2.") }
                guard v.isFinite else { throw MCPToolError("at2 must be a finite number.") }
                layer.anchorV = v
            }
            if let normal = edit.drawsNormal {
                guard layer.kind == .tangent else { throw MCPToolError("Only 'tangent' layers have normal.") }
                layer.drawsNormal = normal
            }
        }
        // 给了数就清掉旧公式，给了公式就以公式为准（上面各类型的检查已经确认这个字段对它有意义）。
        if edit.anchorU != nil { layer.anchorUFormula = edit.anchorUFormula ?? "" }
        if edit.anchorV != nil { layer.anchorVFormula = edit.anchorVFormula ?? "" }
        if edit.anchorW != nil { layer.anchorWFormula = edit.anchorWFormula ?? "" }
        if edit.projectionOffset != nil { layer.projectionOffsetFormula = edit.projectionOffsetFormula ?? "" }
        if edit.gridDensity != nil || edit.arrowScale != nil || edit.gradientOnFloor != nil {
            guard layer.kind == .gradientField || layer.kind == .gradientFlow else {
                throw MCPToolError("Only 'gradientField' and 'gradientFlow' layers have density / arrow_scale / on_floor.")
            }
            if edit.gridDensity != nil, layer.kind != .gradientField {
                throw MCPToolError("Only 'gradientField' layers have density.")
            }
            if let density = edit.gridDensity {
                guard (2...40).contains(density) else { throw MCPToolError("density must be between 2 and 40.") }
                layer.gridDensity = density
            }
            if let scale = edit.arrowScale {
                guard scale.isFinite, abs(scale) >= 0.1, abs(scale) <= 5 else {
                    throw MCPToolError("arrow_scale must be between 0.1 and 5 (negative draws the descent direction −∇f).")
                }
                layer.arrowScale = scale
            }
            if let onFloor = edit.gradientOnFloor { layer.gradientOnFloor = onFloor }
        }
        if let byslope = edit.colorsBySlope {
            guard layer.kind == .surface else { throw MCPToolError("Only 'surface' layers (z = f(x, y)) can be colored by slope.") }
            layer.colorsBySlope = byslope
        }
        if let fit = edit.showsFit {
            guard layer.kind == .scatter else { throw MCPToolError("Only 'scatter' layers have fit.") }
            layer.showsFit = fit
        }
        if layer.kind == .scatter, ScatterData.parse(layer.formula).isEmpty {
            throw MCPToolError("The scatter data has no valid points. Write one \"x, y\" pair per line, e.g. \"1, 2.5\\n2, 4.1\".")
        }
        if let label = edit.showsLabel {
            guard layer.kind == .point else { throw MCPToolError("Only 'point' layers have a label.") }
            layer.showsLabel = label
        }
        if let opacity = edit.opacity {
            guard layer.kind.isSurfaceSource || layer.kind == .region || (layer.kind.canExtrude && layer.extrudesInSpace) else {
                throw MCPToolError("'\(layer.kind.rawValue)' layers have no opacity; only surfaces and regions do.")
            }
            guard (0.05...1).contains(opacity) else { throw MCPToolError("opacity must be between 0.05 and 1.") }
            layer.fillStyle.opacity = opacity
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
        if layer.kind == .projection {
            try validateProjection(layer, in: state)
            return []
        }
        if layer.kind == .tangent || layer.kind == .tangentPlane {
            try validateTangent(layer, in: state)
            return []
        }
        if layer.kind == .gradientField {
            try validateGradient(layer, in: state)
            return []
        }
        if layer.kind == .gradientFlow {
            try validateGradient(layer, in: state)
            guard !ScatterData.parse(layer.formula).isEmpty else {
                throw MCPToolError("The starting points have no valid \"x, y\" line. Write one pair per line, e.g. \"1.5, 0.5\".")
            }
            // 往下走：小球位置公式（secondary_formula）照常编译检查。
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
        if let error = compiled.domainError { messages.append("domain_formulas: \(error.description)") }
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

    /// 梯度场：来源必须是显式曲面 z = f(x, y) 图层。
    private func validateGradient(_ layer: Layer, in state: AppState) throws {
        guard let id = layer.sourceA else {
            throw MCPInvalidParams("'gradientField' layers need 'source_a' (the id of a surface layer z = f(x, y))")
        }
        guard let source = state.layer(with: id) else {
            throw MCPToolError("source_a: no layer with id \(id.uuidString). Call get_document to list layers.")
        }
        guard source.kind.isGradientSource else {
            throw MCPToolError("source_a is a '\(source.kind.rawValue)' layer; a gradient field needs a 'surface' layer z = f(x, y).")
        }
    }

    /// 切线 / 切平面：来源必须是对应的曲线 / 曲面图层，切点处要有切线 / 切平面。
    private func validateTangent(_ layer: Layer, in state: AppState) throws {
        guard let id = layer.sourceA else { throw MCPInvalidParams("'\(layer.kind.rawValue)' layers need 'source_a'") }
        // 切点可能是含参数的公式：把这个图层放进文档副本里编译一遍，用算好的数检查。
        let (compiled, resolved) = compiledWith(layer, in: state)
        if let error = compiled.first(where: { $0.layer.id == layer.id })?.domainError {
            throw MCPToolError("A position formula (at / at2) was rejected: \(error.description)")
        }
        guard let source = compiled.first(where: { $0.layer.id == id }) else {
            throw MCPToolError("source_a: no layer with id \(id.uuidString). Call get_document to list layers.")
        }
        if layer.kind == .tangent {
            guard source.layer.kind.isTangentSource else {
                throw MCPToolError("source_a is a '\(source.layer.kind.rawValue)' layer; a tangent needs an explicit, parametric or polar curve.")
            }
            guard Tangents.tangent(of: source, at: resolved.anchorU) != nil else {
                throw MCPToolError("The curve has no tangent at at = \(resolved.anchorU) (undefined or singular there).")
            }
        } else {
            guard source.layer.kind.isTangentPlaneSource else {
                throw MCPToolError("source_a is a '\(source.layer.kind.rawValue)' layer; a tangent plane needs a surface or parametricSurface layer.")
            }
            guard Tangents.tangentPlane(of: source, u: resolved.anchorU, v: resolved.anchorV) != nil else {
                throw MCPToolError("The surface has no tangent plane at (\(resolved.anchorU), \(resolved.anchorV)) (undefined or singular there).")
            }
        }
    }

    /// 把 `layer` 放进文档副本（已有就换掉）编译：返回整份编译结果与这个图层算好数的样子。
    private func compiledWith(_ layer: Layer, in state: AppState) -> ([LayerCompiler.CompiledLayer], Layer) {
        var document = state.document
        if let index = document.layers.firstIndex(where: { $0.id == layer.id }) {
            document.layers[index] = layer
        } else {
            document.layers.append(layer)
        }
        let compiled = LayerCompiler().compile(document)
        return (compiled, compiled.first { $0.layer.id == layer.id }?.layer ?? layer)
    }

    /// 投影：来源必须是点 / 空间曲线 / 交线；目标是 `plane` 时 source_b 必须是线性的平面图层。
    private func validateProjection(_ layer: Layer, in state: AppState) throws {
        let (merged, _) = compiledWith(layer, in: state)
        if let error = merged.first(where: { $0.layer.id == layer.id })?.domainError {
            throw MCPToolError("The offset formula was rejected: \(error.description)")
        }
        guard let a = layer.sourceA else {
            throw MCPInvalidParams("'projection' layers need 'source_a' (the layer to project)")
        }
        guard let source = state.layer(with: a) else {
            throw MCPToolError("source_a: no layer with id \(a.uuidString). Call get_document to list layers.")
        }
        guard source.kind.isProjectable else {
            throw MCPToolError("source_a is a '\(source.kind.rawValue)' layer; it must be a point, spaceCurve or surfaceIntersection layer.")
        }
        guard layer.projectionTarget == .plane else { return }
        guard let b = layer.sourceB else {
            throw MCPToolError("target 'plane' needs source_b: the id of a plane layer (a linear implicitSurface or surface).")
        }
        let compiled = LayerCompiler().compile(state.document)
        guard let target = compiled.first(where: { $0.layer.id == b }) else {
            throw MCPToolError("source_b: no layer with id \(b.uuidString). Call get_document to list layers.")
        }
        guard case .plane? = SpaceGeometry.recognize(target, in: compiled) else {
            throw MCPToolError("source_b must be a plane: an implicitSurface or surface layer whose formula is linear (a*x + b*y + c*z + d).")
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
        case .projection, .tangent, .tangentPlane: return "(none; it has no formula)"
        case .text: return "(none; the text is not a formula)"
        case .scatter: return "(none; the data is one \"x, y\" point per line)"
        case .gradientField: return "(none; it has no formula)"
        case .gradientFlow: return "(secondary_formula may use parameters only; the ball position, 0 to 1)"
        }
    }

    // MARK: - 位置关系

    /// 两个图层各自认成点 / 直线 / 平面，再算它们的位置关系（同检查器里的「位置关系」面板）。
    func relation(in document: GraphDocument, a: UUID, b: UUID) throws -> GeometryRelation {
        let state = document.state
        guard state.document.dimension == .space else {
            throw MCPToolError("Relations of points, lines and planes need a 3D document.")
        }
        let compiled = LayerCompiler().compile(state.document)
        func object(_ id: UUID, _ field: String) throws -> SpaceObject {
            guard let entry = compiled.first(where: { $0.layer.id == id }) else {
                throw MCPToolError("\(field): no layer with id \(id.uuidString). Call get_document to list layers.")
            }
            guard let recognized = SpaceGeometry.recognize(entry, in: compiled) else {
                throw MCPToolError(
                    "\(field) is a '\(entry.layer.kind.rawValue)' layer that is not a point, a straight line or a plane. "
                        + "Use a point layer, a spaceCurve that is linear in t (e.g. 1+t, 2*t, 3-t), "
                        + "an implicitSurface or surface that is linear in x, y, z, or a tangentPlane."
                )
            }
            return recognized
        }
        guard a != b else { throw MCPToolError("layer_a and layer_b must be two different layers.") }
        return SpaceGeometry.relation(try object(a, "layer_a"), try object(b, "layer_b"))
    }

    /// 把关系里的辅助对象（垂足、交点、公垂线段、交线）加成新图层，返回新图层。
    func drawRelation(in document: GraphDocument, a: UUID, b: UUID) throws -> [Layer] {
        let relation = try self.relation(in: document, a: a, b: b)
        guard !relation.constructions.isEmpty else { return [] }
        let state = document.state
        let box = state.document.view3D
        let base = state.document.layers.count
        let created = relation.constructions.enumerated().map { offset, construction -> Layer in
            let anchor: SIMD3<Double>
            switch construction {
            case .point(let p, _): anchor = p
            case .segment(let p, _, _): anchor = p
            case .line(let origin, _, _): anchor = origin
            }
            let reach = simd_length(anchor - box.center) + 2 * 3.0.squareRoot() * box.halfExtent
            return construction.makeLayer(index: base + offset, lineExtent: reach)
        }
        state.mutateLayers(L("Add Construction")) { $0.layers.append(contentsOf: created) }
        return created
    }

    func describe(_ relation: GeometryRelation) -> MCPObject {
        func vector(_ v: SIMD3<Double>) -> [Double] { [v.x, v.y, v.z] }
        let constructions: [MCPObject] = relation.constructions.map { construction in
            switch construction {
            case .point(let p, let name): return ["type": "point", "name": name, "position": vector(p)]
            case .segment(let a, let b, let name): return ["type": "segment", "name": name, "from": vector(a), "to": vector(b)]
            case .line(let origin, let direction, let name):
                return ["type": "line", "name": name, "origin": vector(origin), "direction": vector(direction)]
            }
        }
        return [
            "relation": relation.code,
            "summary": relation.summary,
            "measures": relation.measures.map { ["name": $0.key, "value": $0.value, "unit": $0.isAngle ? "degrees" : "length"] as MCPObject },
            "constructions": constructions,
        ]
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
