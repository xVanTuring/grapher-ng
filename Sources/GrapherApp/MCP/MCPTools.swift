import Foundation
import GrapherKit

/// 注册所有工具。读工具随时可用，写工具（`.write`）受设置里的总闸控制，闸门在 `MCPCatalog.call`。
enum MCPTools {
    static let kindNames = PlotKind.allCases.map(\.rawValue)

    @MainActor
    static func registerAll(into catalog: MCPCatalog, facade: MCPFacade) {
        registerReadTools(into: catalog, facade: facade)
        registerDocumentTools(into: catalog, facade: facade)
        registerLayerTools(into: catalog, facade: facade)
        registerViewTools(into: catalog, facade: facade)
        registerLessonTools(into: catalog, facade: facade)
    }

    private static let documentIDSchema = MCPSchema.string(
        "Document id from get_state. Omit to use the frontmost graph window (or the only open one)."
    )

    // MARK: - Read

    @MainActor
    private static func registerReadTools(into catalog: MCPCatalog, facade: MCPFacade) {
        catalog.register(MCPTool(
            name: "get_state",
            title: "Grapher NG state",
            description: "List the open graph documents (id, title, 2D/3D, layer count) and whether write tools are allowed. Call this first.",
            inputSchema: MCPSchema.object([:]),
            tier: .read
        ) { _ in
            let state = await facade.state()
            let documents = state["documents"] as? [MCPObject] ?? []
            let writeAllowed = state["writeAllowed"] as? Bool ?? false
            return MCPToolResult(
                text: "\(documents.count) open document(s). Write access allowed: \(writeAllowed).",
                structured: state
            )
        })

        catalog.register(MCPTool(
            name: "get_document",
            title: "Get document",
            description: "Full content of one document: every layer (id, kind, formulas, color, errors), parameters, view and appearance.",
            inputSchema: MCPSchema.object(["document_id": documentIDSchema]),
            tier: .read
        ) { args in
            let document = try await facade.resolve(try args.optionalUUID("document_id"))
            let object = await facade.describe(document)
            let layerCount = (object["layers"] as? [MCPObject])?.count ?? 0
            return MCPToolResult(text: "\(layerCount) layer(s).", structured: object)
        })

        catalog.register(MCPTool(
            name: "get_reference",
            title: "Formula reference",
            description: "Plot kinds, which fields each needs, formula syntax and functions. Read this before adding layers.",
            inputSchema: MCPSchema.object([:]),
            tier: .read
        ) { _ in
            MCPToolResult(text: reference)
        })

        catalog.register(MCPTool(
            name: "render_image",
            title: "Render image",
            description: "Render the document as a PNG you can look at, to check that the graph is what you intended. Uses the saved view of the document. "
                + "With step=N (lesson documents) it renders that step: its layers, camera and slider values, with the step's text card at the bottom.",
            inputSchema: MCPSchema.object([
                "document_id": documentIDSchema,
                "width": MCPSchema.integer("Image width in pixels (default 900)", minimum: 200, maximum: 2400),
                "height": MCPSchema.integer("Image height in pixels (default 600; 760 with step)", minimum: 200, maximum: 2400),
                "step": MCPSchema.integer("Lesson step to render, counted from 1", minimum: 1),
            ]),
            tier: .read
        ) { args in
            let document = try await facade.resolve(try args.optionalUUID("document_id"))
            let step = try args.optionalInt("step")
            let width = try args.optionalInt("width") ?? 900
            let height = try args.optionalInt("height") ?? (step == nil ? 600 : 760)
            try checkImageSize(width: width, height: height)
            let png = try await facade.renderPNG(of: document, width: width, height: height, step: step)
            let what = step.map { " of lesson step \($0)" } ?? ""
            return MCPToolResult(text: "Rendered \(width)×\(height) PNG\(what).", imagePNG: png)
        })

        catalog.register(MCPTool(
            name: "get_text_reference",
            title: "Text format reference",
            description: "The short text format for a graph block (a ```grapher fenced block in a Markdown note, e.g. in UniReader): "
                + "one layer per line, sliders, camera, examples. Read this before writing a block, then check it with render_text.",
            inputSchema: MCPSchema.object([:]),
            tier: .read
        ) { _ in
            MCPToolResult(text: GrapherText.reference)
        })

        catalog.register(MCPTool(
            name: "render_text",
            title: "Render a text block",
            description: "Draw a graph from its text description (the body of a ```grapher block) and return a PNG plus line-numbered errors. "
                + "Does not touch any open document. Use it to check a block before putting it in a note.",
            inputSchema: MCPSchema.object([
                "text": MCPSchema.string("The block body, one layer per line (see get_text_reference)"),
                "width": MCPSchema.integer("Image width in pixels (default 900); the height follows the block's aspect", minimum: 200, maximum: 2400),
                "theme": MCPSchema.string("light or dark; default follows the text, then light", enumValues: ["light", "dark"]),
                "step": MCPSchema.integer("For a lesson (step lines): render that step, counted from 1, with its text card", minimum: 1),
            ], required: ["text"]),
            tier: .read
        ) { args in
            let text = try args.string("text")
            let width = try args.optionalInt("width") ?? 900
            try checkImageSize(width: width, height: 200)
            let theme = try args.optionalString("theme")
            let rendering = try await facade.renderText(text, width: width, theme: theme, step: try args.optionalInt("step"))
            let problems = rendering.errors.map { "line \($0.line): \($0.message)" }
            let summary = problems.isEmpty
                ? "Rendered \(width)×\(Int((Double(width) / rendering.aspect).rounded())) PNG. No errors."
                : "Rendered with \(problems.count) error(s); the lines named below were skipped:\n" + problems.joined(separator: "\n")
            return MCPToolResult(text: summary, imagePNG: rendering.png)
        })
    }

    // MARK: - Documents

    @MainActor
    private static func registerDocumentTools(into catalog: MCPCatalog, facade: MCPFacade) {
        catalog.register(MCPTool(
            name: "create_document",
            title: "Create document",
            description: "Open a new, empty graph window. A document is either 2D ('plane') or 3D ('space'); it cannot change later.",
            inputSchema: MCPSchema.object([
                "dimension": MCPSchema.string("plane = 2D graph, space = 3D graph", enumValues: ["plane", "space"]),
            ], required: ["dimension"]),
            tier: .write
        ) { args in
            let dimension: DocumentDimension = try args.string("dimension") == "space" ? .space : .plane
            let document = try await facade.createDocument(dimension: dimension, example: false)
            return MCPToolResult(
                text: "Created \(dimension == .space ? "3D" : "2D") document \(document.mcpID.uuidString).",
                structured: ["id": document.mcpID.uuidString, "dimension": dimension.rawValue]
            )
        })

        catalog.register(MCPTool(
            name: "open_document",
            title: "Open document",
            description: "Open a .grapher file in a new window.",
            inputSchema: MCPSchema.object(["path": MCPSchema.string("Absolute path of the .grapher file")], required: ["path"]),
            tier: .write
        ) { args in
            let document = try await facade.openDocument(path: try args.string("path"))
            return MCPToolResult(
                text: "Opened document \(document.mcpID.uuidString).",
                structured: await facade.describe(document)
            )
        })

        catalog.register(MCPTool(
            name: "save_document",
            title: "Save document",
            description: "Save the document as a .grapher file. Without a path it saves in place (only for documents that already have a file).",
            inputSchema: MCPSchema.object([
                "document_id": documentIDSchema,
                "path": MCPSchema.string("Absolute path; .grapher is appended if there is no extension"),
            ]),
            tier: .write
        ) { args in
            let document = try await facade.resolve(try args.optionalUUID("document_id"))
            let path = try await facade.saveDocument(document, path: try args.optionalString("path"))
            return MCPToolResult(text: "Saved to \(path).", structured: ["path": path])
        })

        catalog.register(MCPTool(
            name: "export_png",
            title: "Export PNG",
            description: "Write the graph as a PNG file (re-sampled at the requested size, tick labels included).",
            inputSchema: MCPSchema.object([
                "document_id": documentIDSchema,
                "path": MCPSchema.string("Absolute path of the PNG file"),
                "width": MCPSchema.integer("Width in pixels (default 1600)", minimum: 200, maximum: 4800),
                "height": MCPSchema.integer("Height in pixels (default 1000)", minimum: 200, maximum: 4800),
            ], required: ["path"]),
            tier: .write
        ) { args in
            let document = try await facade.resolve(try args.optionalUUID("document_id"))
            let width = try args.optionalInt("width") ?? 1600
            let height = try args.optionalInt("height") ?? 1000
            try checkImageSize(width: width, height: height, limit: 4800)
            let path = try await facade.exportPNG(of: document, path: try args.string("path"), width: width, height: height)
            return MCPToolResult(text: "Wrote \(width)×\(height) PNG to \(path).", structured: ["path": path])
        })
    }

    // MARK: - Layers and parameters

    private static func layerProperties(forAdd: Bool) -> MCPObject {
        var properties: MCPObject = [
            "document_id": documentIDSchema,
            "name": MCPSchema.string("Label shown in the layer list"),
            "formula": MCPSchema.string(
                "Main formula (see get_reference). explicit: f(x). parametric/spaceCurve: x(t). polar: r(theta). "
                    + "implicit/region: F(x,y). surface: f(x,y). parametricSurface: x(u,v). implicitSurface: F(x,y,z)."
            ),
            "secondary_formula": MCPSchema.string("y(t) for parametric and spaceCurve; y(u,v) for parametricSurface"),
            "tertiary_formula": MCPSchema.string("z(t) for spaceCurve; z(u,v) for parametricSurface"),
            "relation": MCPSchema.string("region only: which side of F=0 to fill", enumValues: ["<", "<=", ">", ">="]),
            "domain": MCPSchema.numbers("[min, max] of t / theta / u (explicit, parametric, polar, spaceCurve, parametricSurface)", count: 2),
            "domain2": MCPSchema.numbers("[min, max] of v (parametricSurface only)", count: 2),
            "domain_formulas": MCPSchema.strings(
                "[lower, upper] of t / theta / u as formulas that may use parameters, e.g. [\"0\", \"p*2*pi\"]: the range follows the parameter, so playing p draws the curve gradually. An empty string keeps that end's number from 'domain'", count: 2),
            "domain2_formulas": MCPSchema.strings("[lower, upper] of v as formulas (parametricSurface only), see domain_formulas", count: 2),
            "extrude": MCPSchema.boolean("3D documents, 2D curve kinds only: sweep the curve along z into a vertical surface"),
            "source_a": MCPSchema.string("surfaceIntersection only: id of the first surface layer (surface, parametricSurface or implicitSurface)"),
            "source_b": MCPSchema.string("surfaceIntersection only: id of the second surface layer"),
            "target": MCPSchema.string(
                "projection only: xy (z = offset), yz (x = offset), xz (y = offset) or plane (use source_b)",
                enumValues: ProjectionTarget.allCases.map(\.rawValue)),
            "offset": MCPSchema.numberOrFormula("projection only: position of the xy / yz / xz plane (default 0). May be a formula with parameters, e.g. \"2*p\": playing p slides the plane"),
            "direction": MCPSchema.numbers("projection only: [dx, dy, dz] for an oblique projection along that direction; [0, 0, 0] goes back to a perpendicular one", count: 3),
            "projectors": MCPSchema.boolean("projection only: draw thin lines from the original to its projection (default true)"),
            "at": MCPSchema.numberOrFormula("tangent / tangentPlane: the tangent point. tangent: x (explicit), t (parametric) or theta (polar). tangentPlane: x of a surface, u of a parametricSurface. text: x. May be a formula with parameters, e.g. \"p\": playing p slides the tangent along the curve"),
            "at2": MCPSchema.numberOrFormula("tangentPlane: y of a surface, v of a parametricSurface. text: y. Number or formula"),
            "at3": MCPSchema.numberOrFormula("text in a 3D document only: z of the text position. Number or formula"),
            "font_size": MCPSchema.number("text only: font size in points, 6–96 (default 14)"),
            "normal": MCPSchema.boolean("tangent only: draw the normal line instead of the tangent line"),
            "color_by_slope": MCPSchema.boolean("surface (z = f(x, y)) only: color the surface by its slope |∇f|, blue where flat to red where steep"),
            "density": MCPSchema.integer("gradientField only: arrows per axis, 2–40 (default 12)", minimum: 2, maximum: 40),
            "arrow_scale": MCPSchema.number("gradientField only: arrow length multiplier 0.1–5 (default 1); negative draws the descent direction −∇f"),
            "on_floor": MCPSchema.boolean("gradientField only: draw ∇f flat on the floor of the box instead of along the surface"),
            "fit": MCPSchema.boolean("scatter only: draw the least-squares line (get_document then reports slope, intercept and r)"),
            "label": MCPSchema.boolean("point only: write the layer name (A, B, C…) next to the point (default true)"),
            "arrow": MCPSchema.boolean("spaceCurve only: draw an arrowhead at the end of t, to show a vector (normal, tangent …)"),
            "opacity": MCPSchema.number("surface / region fill opacity, 0.05–1 (default 1); below 1 a surface becomes translucent"),
            "color": MCPSchema.string("#RRGGBB"),
            "line_width": MCPSchema.number("Stroke width in points (default 1.8)"),
            "dashed": MCPSchema.boolean("Dashed stroke"),
            "visible": MCPSchema.boolean("Show or hide the layer"),
        ]
        if forAdd {
            properties["kind"] = MCPSchema.string("Plot kind", enumValues: kindNames)
        } else {
            properties["layer_id"] = MCPSchema.string("Layer id from get_document")
        }
        return properties
    }

    private static func layerEdit(from args: MCPArgs) throws -> MCPFacade.LayerEdit {
        var edit = MCPFacade.LayerEdit()
        if let kind = try args.optionalString("kind") {
            guard let parsed = PlotKind(rawValue: kind) else {
                throw MCPInvalidParams("unknown kind '\(kind)'; one of: \(kindNames.joined(separator: ", "))")
            }
            edit.kind = parsed
        }
        edit.name = try args.optionalString("name")
        edit.formula = try args.optionalString("formula")
        edit.secondaryFormula = try args.optionalString("secondary_formula")
        edit.tertiaryFormula = try args.optionalString("tertiary_formula")
        if let relation = try args.optionalString("relation") { edit.relation = try MCPFacade.parseRelation(relation) }
        if let domain = try args.optionalDoubles("domain", count: 2) { edit.domain = (domain[0], domain[1]) }
        if let domain2 = try args.optionalDoubles("domain2", count: 2) { edit.domain2 = (domain2[0], domain2[1]) }
        if let formulas = try args.optionalStrings("domain_formulas", count: 2) { edit.domainFormulas = (formulas[0], formulas[1]) }
        if let formulas = try args.optionalStrings("domain2_formulas", count: 2) { edit.domain2Formulas = (formulas[0], formulas[1]) }
        edit.extrude = try args.optionalBool("extrude")
        edit.sourceA = try args.optionalUUID("source_a")
        edit.sourceB = try args.optionalUUID("source_b")
        if let target = try args.optionalString("target") {
            guard let parsed = ProjectionTarget(rawValue: target) else {
                throw MCPInvalidParams("unknown target '\(target)'; one of: \(ProjectionTarget.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            edit.projectionTarget = parsed
        }
        edit.opacity = try args.optionalDouble("opacity")
        edit.showsLabel = try args.optionalBool("label")
        edit.showsArrow = try args.optionalBool("arrow")
        edit.showsFit = try args.optionalBool("fit")
        edit.colorsBySlope = try args.optionalBool("color_by_slope")
        edit.gridDensity = try args.optionalInt("density")
        edit.arrowScale = try args.optionalDouble("arrow_scale")
        edit.gradientOnFloor = try args.optionalBool("on_floor")
        // at / at2 / at3 / offset 可以是数，也可以是含参数的公式（字符串）。
        (edit.anchorU, edit.anchorUFormula) = try args.numberOrFormula("at")
        (edit.anchorV, edit.anchorVFormula) = try args.numberOrFormula("at2")
        (edit.anchorW, edit.anchorWFormula) = try args.numberOrFormula("at3")
        edit.fontSize = try args.optionalDouble("font_size")
        edit.drawsNormal = try args.optionalBool("normal")
        (edit.projectionOffset, edit.projectionOffsetFormula) = try args.numberOrFormula("offset")
        if let direction = try args.optionalDoubles("direction", count: 3) {
            edit.projectionDirection = SIMD3(direction[0], direction[1], direction[2])
        }
        edit.showsProjectors = try args.optionalBool("projectors")
        if let color = try args.optionalString("color") { edit.color = try MCPFacade.parseColor(color) }
        edit.lineWidth = try args.optionalDouble("line_width")
        edit.dashed = try args.optionalBool("dashed")
        edit.visible = try args.optionalBool("visible")
        return edit
    }

    @MainActor
    private static func registerLayerTools(into catalog: MCPCatalog, facade: MCPFacade) {
        catalog.register(MCPTool(
            name: "add_layer",
            title: "Add layer",
            description: "Insert a graph (curve, region or surface) into a document. The formula is checked first; if it is wrong nothing is added and the error says where. "
                + "2D documents take explicit, parametric, polar, implicit, region; 3D documents take surface, parametricSurface, spaceCurve, implicitSurface, plus explicit/parametric/polar/implicit (drawn on z=0 or extruded), plus surfaceIntersection "
                + "(no formula: pass source_a and source_b, the ids of two surface layers; draws their intersection curve). "
                + "and projection (no formula: source_a = a point / spaceCurve / surfaceIntersection layer, target = xy | yz | xz | plane). "
                + "and tangent (2D: source_a = an explicit / parametric / polar layer, at = x or t or theta, normal = true for the normal line) "
                + "and tangentPlane (3D: source_a = a surface / parametricSurface layer, at + at2 = the point's x, y or u, v). "
                + "and text (a free label in either kind of document: formula = the text itself, at / at2 (/ at3 in 3D) = its position in data coordinates, font_size). "
                + "and gradientField (3D: source_a = a surface z = f(x, y) layer; arrows along the steepest ascent, longer and warmer where the slope is larger; on_floor = true draws ∇f flat on the floor; arrow_scale < 0 draws −∇f) "
                + "and gradientFlow (3D: source_a = a surface layer; formula = starting points one \"x, y\" per line; the path climbs along ∇f, arrow_scale < 0 descends, on_floor draws it flat; secondary_formula = ball position 0 to 1 along the path, may use a parameter so that playing the parameter slides the ball) "
                + "and scatter (2D: formula = the data, one \"x, y\" point per line; fit = true draws the least-squares line). "
                + "Every kind except surfaceIntersection, projection, tangent and tangentPlane requires 'formula'.",
            inputSchema: MCPSchema.object(layerProperties(forAdd: true), required: ["kind"]),
            tier: .write
        ) { args in
            let document = try await facade.resolve(try args.optionalUUID("document_id"))
            let (layer, _) = try await facade.addLayer(to: document, try layerEdit(from: args))
            return MCPToolResult(
                text: "Added \(layer.kind.rawValue) layer \(layer.id.uuidString).",
                structured: ["layerId": layer.id.uuidString, "documentId": document.mcpID.uuidString]
            )
        })

        catalog.register(MCPTool(
            name: "update_layer",
            title: "Update layer",
            description: "Change fields of an existing layer; omitted fields stay as they are. A layer's kind cannot change.",
            inputSchema: MCPSchema.object(layerProperties(forAdd: false), required: ["layer_id"]),
            tier: .write
        ) { args in
            let document = try await facade.resolve(try args.optionalUUID("document_id"))
            let (layer, _) = try await facade.updateLayer(in: document, id: try args.requiredUUID("layer_id"), try layerEdit(from: args))
            return MCPToolResult(text: "Updated layer \(layer.id.uuidString).", structured: ["layerId": layer.id.uuidString])
        })

        catalog.register(MCPTool(
            name: "remove_layer",
            title: "Remove layer",
            description: "Delete a layer. The user can undo it with ⌘Z.",
            inputSchema: MCPSchema.object([
                "document_id": documentIDSchema,
                "layer_id": MCPSchema.string("Layer id from get_document"),
            ], required: ["layer_id"]),
            tier: .write
        ) { args in
            let document = try await facade.resolve(try args.optionalUUID("document_id"))
            let id = try args.requiredUUID("layer_id")
            try await facade.removeLayer(in: document, id: id)
            return MCPToolResult(text: "Removed layer \(id.uuidString).")
        })

        catalog.register(MCPTool(
            name: "relate",
            title: "Relation of two points / lines / planes",
            description: "3D documents: how two layers relate and how far apart they are. A layer counts as a point (a point layer), "
                + "a straight line (a spaceCurve linear in t) or a plane (an implicitSurface or surface linear in x, y, z, or a tangentPlane). "
                + "Returns a relation code (e.g. lines_skew, line_meets_plane, planes_intersect, point_off_plane), "
                + "measures (distance, angle in degrees, dihedral_angle) and the helper objects "
                + "(foot of the perpendicular, intersection point, common perpendicular segment, line of intersection) with coordinates. "
                + "Does not change the document; use draw_relation to draw the helper objects.",
            inputSchema: MCPSchema.object([
                "document_id": documentIDSchema,
                "layer_a": MCPSchema.string("Layer id of the first point / line / plane"),
                "layer_b": MCPSchema.string("Layer id of the second point / line / plane"),
            ], required: ["layer_a", "layer_b"]),
            tier: .read
        ) { args in
            let document = try await facade.resolve(try args.optionalUUID("document_id"))
            let relation = try await facade.relation(
                in: document, a: try args.requiredUUID("layer_a"), b: try args.requiredUUID("layer_b"))
            let structured = await facade.describe(relation)
            return MCPToolResult(text: relation.summary, structured: structured)
        })

        catalog.register(MCPTool(
            name: "draw_relation",
            title: "Draw the helper objects of a relation",
            description: "Same as relate, and also adds the helper objects as new layers: points for feet / intersections, "
                + "dashed segments for perpendiculars, lines for lines of intersection. They are a snapshot, not linked to the sources. "
                + "Returns the new layer ids.",
            inputSchema: MCPSchema.object([
                "document_id": documentIDSchema,
                "layer_a": MCPSchema.string("Layer id of the first point / line / plane"),
                "layer_b": MCPSchema.string("Layer id of the second point / line / plane"),
            ], required: ["layer_a", "layer_b"]),
            tier: .write
        ) { args in
            let document = try await facade.resolve(try args.optionalUUID("document_id"))
            let a = try args.requiredUUID("layer_a")
            let b = try args.requiredUUID("layer_b")
            let relation = try await facade.relation(in: document, a: a, b: b)
            let created = try await facade.drawRelation(in: document, a: a, b: b)
            var structured = await facade.describe(relation)
            structured["layerIds"] = created.map { $0.id.uuidString }
            return MCPToolResult(text: "\(relation.summary) Added \(created.count) layer(s).", structured: structured)
        })

        catalog.register(MCPTool(
            name: "set_parameter",
            title: "Set parameter",
            description: "Create a named parameter (for example a) or change its value and slider range. Formulas can then use it as a constant, and the user can drag its slider.",
            inputSchema: MCPSchema.object([
                "document_id": documentIDSchema,
                "name": MCPSchema.string("Letters, digits or _; must not be a variable or function name (x, t, u, e, pi, sin, …)"),
                "value": MCPSchema.number("Current value (default 1 for a new parameter)"),
                "min": MCPSchema.number("Slider minimum (default -5)"),
                "max": MCPSchema.number("Slider maximum (default 5)"),
            ], required: ["name"]),
            tier: .write
        ) { args in
            let document = try await facade.resolve(try args.optionalUUID("document_id"))
            let parameter = try await facade.setParameter(
                in: document,
                name: try args.string("name"),
                value: try args.optionalDouble("value"),
                min: try args.optionalDouble("min"),
                max: try args.optionalDouble("max")
            )
            return MCPToolResult(
                text: "\(parameter.name) = \(parameter.value) (range \(parameter.lowerBound) … \(parameter.upperBound)).",
                structured: ["name": parameter.name, "value": parameter.value, "min": parameter.lowerBound, "max": parameter.upperBound]
            )
        })

        catalog.register(MCPTool(
            name: "remove_parameter",
            title: "Remove parameter",
            description: "Delete a parameter. Layers that still use it will show a formula error.",
            inputSchema: MCPSchema.object([
                "document_id": documentIDSchema,
                "name": MCPSchema.string("Parameter name"),
            ], required: ["name"]),
            tier: .write
        ) { args in
            let document = try await facade.resolve(try args.optionalUUID("document_id"))
            let name = try args.string("name")
            try await facade.removeParameter(in: document, name: name)
            return MCPToolResult(text: "Removed parameter \(name).")
        })
    }

    // MARK: - View

    @MainActor
    private static func registerViewTools(into catalog: MCPCatalog, facade: MCPFacade) {
        catalog.register(MCPTool(
            name: "set_view",
            title: "Set view",
            description: "Move the camera. 2D: center_x, center_y, scale (pixels per unit). 3D: center, half_extent (axis box half-size), azimuth, elevation (degrees), camera_zoom. "
                + "fit frames all content; reset returns to the default view. Applied in this order: reset, explicit values, fit.",
            inputSchema: MCPSchema.object([
                "document_id": documentIDSchema,
                "fit": MCPSchema.boolean("Frame all content"),
                "reset": MCPSchema.boolean("Back to the default view"),
                "center_x": MCPSchema.number("2D: x of the view centre"),
                "center_y": MCPSchema.number("2D: y of the view centre"),
                "scale": MCPSchema.number("2D: pixels per data unit (bigger = zoomed in)"),
                "center": MCPSchema.numbers("3D: [x, y, z] centre of the axis box", count: 3),
                "half_extent": MCPSchema.number("3D: half the box size in data units (smaller = zoomed in)"),
                "azimuth": MCPSchema.number("3D: degrees around the z axis, counter-clockwise from +x"),
                "elevation": MCPSchema.number("3D: degrees above the xy plane, −89 … 89"),
                "camera_zoom": MCPSchema.number("3D: enlarge the box on screen, 0.25 … 12"),
            ]),
            tier: .write
        ) { args in
            let document = try await facade.resolve(try args.optionalUUID("document_id"))
            var edit = MCPFacade.ViewEdit()
            edit.fit = try args.optionalBool("fit") ?? false
            edit.reset = try args.optionalBool("reset") ?? false
            let centerX = try args.optionalDouble("center_x")
            let centerY = try args.optionalDouble("center_y")
            if centerX != nil || centerY != nil {
                let current = await document.state.document.viewport
                edit.center = (centerX ?? current.centerX, centerY ?? current.centerY)
            }
            edit.scale = try args.optionalDouble("scale")
            edit.center3D = try args.optionalDoubles("center", count: 3)
            edit.halfExtent = try args.optionalDouble("half_extent")
            edit.azimuthDegrees = try args.optionalDouble("azimuth")
            edit.elevationDegrees = try args.optionalDouble("elevation")
            edit.cameraZoom = try args.optionalDouble("camera_zoom")
            try await facade.setView(of: document, edit)
            return MCPToolResult(text: "View updated.", structured: await facade.describe(document)["view"] as? MCPObject)
        })

        catalog.register(MCPTool(
            name: "set_appearance",
            title: "Set appearance",
            description: "Theme and which chrome is drawn: grid, minor grid, axes, tick labels.",
            inputSchema: MCPSchema.object([
                "document_id": documentIDSchema,
                "theme": MCPSchema.string("Colour theme", enumValues: ["light", "dark"]),
                "show_grid": MCPSchema.boolean("Grid lines"),
                "show_minor_grid": MCPSchema.boolean("Minor grid lines"),
                "show_axes": MCPSchema.boolean("Axes"),
                "show_tick_labels": MCPSchema.boolean("Tick numbers"),
            ]),
            tier: .write
        ) { args in
            let document = try await facade.resolve(try args.optionalUUID("document_id"))
            var dark: Bool?
            if let theme = try args.optionalString("theme") {
                guard theme == "light" || theme == "dark" else { throw MCPInvalidParams("theme must be light or dark") }
                dark = theme == "dark"
            }
            await facade.setAppearance(
                of: document,
                dark: dark,
                grid: try args.optionalBool("show_grid"),
                minorGrid: try args.optionalBool("show_minor_grid"),
                axes: try args.optionalBool("show_axes"),
                tickLabels: try args.optionalBool("show_tick_labels")
            )
            return MCPToolResult(text: "Appearance updated.")
        })
    }

    // MARK: - Lesson

    @MainActor
    private static func registerLessonTools(into catalog: MCPCatalog, facade: MCPFacade) {
        let stepSchema = MCPSchema.object([
            "title": MCPSchema.string("Step title; may contain TeX in $…$"),
            "text": MCPSchema.string("Explanation. Inline TeX $…$, a formula on its own line $$…$$, **bold**, newlines for paragraphs"),
            "show": MCPSchema.stringList("Names (or ids) of the layers this step shows. Omit to keep the previous step's set; a first step without it shows every layer"),
            "focus": MCPSchema.string("Layer name or id to highlight"),
            "azimuth": MCPSchema.number("3D: camera degrees around z (omitted camera values keep the previous step's)"),
            "elevation": MCPSchema.number("3D: camera degrees above the xy plane"),
            "zoom": MCPSchema.number("3D: enlarge the box on screen, 0.25 … 12"),
            "range": MCPSchema.number("3D: half the axis box size in data units"),
            "center": MCPSchema.array("3D: [x, y, z] box centre; 2D: [x, y] view centre", items: ["type": "number"]),
            "width": MCPSchema.number("2D: how many x units are visible across"),
            "parameters": MCPSchema.numberMap("Slider values for this step, e.g. {\"h\": 0.3}; they move there smoothly"),
            "play": MCPSchema.stringList("Parameters to start playing when the step opens"),
        ])
        catalog.register(MCPTool(
            name: "set_lesson",
            title: "Set lesson steps",
            description: "Turn the document into a step-by-step lesson (for explaining a derivation): replace all steps. "
                + "Each step chooses which layers are shown, may move the camera and sliders, and has a title and text with TeX formulas. "
                + "Build every layer first (hidden helpers included), then call this. An empty list removes the lesson. "
                + "Check each step with render_image step=N. Undoable.",
            inputSchema: MCPSchema.object([
                "document_id": documentIDSchema,
                "steps": MCPSchema.array("The steps in order", items: stepSchema),
                "start": MCPSchema.boolean("Open the lesson at step 1 in the window (default true)"),
            ], required: ["steps"]),
            tier: .write
        ) { args in
            let document = try await facade.resolve(try args.optionalUUID("document_id"))
            guard let steps = try args.optionalObjects("steps") else { throw MCPInvalidParams("missing required array 'steps'") }
            let count = try await facade.setLesson(in: document, steps: steps, start: try args.optionalBool("start") ?? true)
            return MCPToolResult(
                text: count == 0 ? "Lesson removed." : "Lesson set: \(count) step(s).",
                structured: await facade.describe(document)["lesson"] as? MCPObject)
        })

        catalog.register(MCPTool(
            name: "go_to_step",
            title: "Go to lesson step",
            description: "Show one step of the document's lesson in its window (counted from 1), or end the lesson with end=true.",
            inputSchema: MCPSchema.object([
                "document_id": documentIDSchema,
                "step": MCPSchema.integer("Step number, counted from 1", minimum: 1),
                "end": MCPSchema.boolean("End the lesson: every layer goes back to its own visibility"),
            ]),
            tier: .write
        ) { args in
            let document = try await facade.resolve(try args.optionalUUID("document_id"))
            if try args.optionalBool("end") == true {
                try await facade.goToStep(in: document, number: nil)
                return MCPToolResult(text: "Lesson ended.")
            }
            guard let step = try args.optionalInt("step") else { throw MCPInvalidParams("pass step (from 1) or end=true") }
            try await facade.goToStep(in: document, number: step)
            return MCPToolResult(text: "Showing step \(step).")
        })
    }

    private static func checkImageSize(width: Int, height: Int, limit: Int = 2400) throws {
        guard (200...limit).contains(width), (200...limit).contains(height) else {
            throw MCPToolError("width and height must be between 200 and \(limit).")
        }
    }

    // MARK: - Reference

    static let reference = """
    Grapher NG formula reference

    PLOT KINDS (field → variables)
    2D document:
      explicit            formula = f(x)                            y = f(x)
      parametric          formula = x(t), secondary_formula = y(t), domain = [t0, t1]
      polar               formula = r(theta)   (theta or t)         domain = [0, 2π] by default
      implicit            formula = F(x,y)     draws F(x,y) = 0
      region              formula = F(x,y), relation one of < <= > >=   fills where F relation 0
    3D document:
      surface             formula = f(x,y)     z = f(x,y), over the axis box's x/y range; color_by_slope = true colors it by steepness (blue flat → red steep)
      parametricSurface   formula = x(u,v), secondary_formula = y(u,v), tertiary_formula = z(u,v), domain = [u0,u1], domain2 = [v0,v1]
      spaceCurve          formula = x(t), secondary_formula = y(t), tertiary_formula = z(t), domain = [t0,t1]; arrow = true puts an arrowhead at t1 (vectors)
      implicitSurface     formula = F(x,y,z)   draws F = 0
      point               formula = x, secondary_formula = y, tertiary_formula = z   (numbers and parameters only, no variables); line_width = size
      surfaceIntersection source_a = id of one surface layer, source_b = id of another (surface / parametricSurface / implicitSurface); no formula.
                          Draws the curve where the two surfaces meet. Hiding the source layers keeps the curve.
      projection          source_a = id of a point / spaceCurve / surfaceIntersection layer; target = xy (plane z = offset) | yz (x = offset) | xz (y = offset)
                          | plane (source_b = id of a plane layer); projectors = draw projecting lines. Orthogonal projection; no formula.
                          A straight line is a spaceCurve linear in t, e.g. (1+t, 2*t, 3-t); a plane is an implicitSurface linear in x, y, z, e.g. x + 2*y - z - 3.
      tangent             (2D document) source_a = id of an explicit / parametric / polar layer, at = x (explicit) | t | theta, normal = true for the normal line; no formula
      tangentPlane        (3D document) source_a = id of a surface / parametricSurface layer, at, at2 = (x, y) or (u, v) of the tangent point; no formula.
                          The plane shows up in the relations panel like any other plane and can be a projection target.
      gradientField       (3D document) source_a = id of a surface layer z = f(x,y); density = arrows per axis, arrow_scale, on_floor; no formula. Shows where f is steep (red, long arrows) or flat (blue, short; none at extrema/saddles).
      gradientFlow        (3D document) source_a = id of a surface layer; formula = start points ("1.5, 0.5\n-2, 2"); secondary_formula = ball position along the path, 0 to 1 (e.g. "p" with a parameter p; play p to animate); arrow_scale < 0 = descend; on_floor
      scatter             (2D document) formula = the data, one point per line ("1, 2.5\n2, 4.1"; commas, spaces or tabs; header lines are skipped), fit = true draws y = a·x + b; line_width = point size
      text                (2D and 3D documents) formula = the text to write (NOT a formula), at / at2 (and at3 in 3D) = position, font_size, color
      explicit / parametric / polar / implicit also work: drawn on the z = 0 plane, or with extrude = true swept along z into a vertical surface.
    Write the F of an implicit layer WITHOUT "= 0": x^2 + y^2 - 4, not x^2 + y^2 = 4.
    Everything in a 3D document is clipped to the axis box (default −4 … 4 on each axis); scale shapes to fit or call set_view.
    Ranges (domain, domain2) can be formulas with parameters via domain_formulas / domain2_formulas, e.g. ["0", "p*2*pi"]: the curve or surface is drawn only up to that end,
    so animating p from 0 to 1 draws it gradually. Constants like pi work there too.

    SYNTAX
      Constants   pi π e tau τ
      Operators   + - * / % ^   comparisons < <= > >= == !=   logic && || !   ternary ? :
                  ^ is right-associative and binds tighter than unary minus: -x^2 = -(x^2), 2^-3 = 0.125.
                  Comparisons and logic give 0 or 1.
      Implicit multiplication   2x  3sin(x)  2(x+1)  2x^2  xy  2xy   (1/2x means (1/2)*x)
      Functions   sin cos tan cot sec csc asin acos atan atan2 sinh cosh tanh asinh acosh atanh
                  exp ln log log2 log10 sqrt cbrt abs sign floor ceil round trunc erf gamma
                  mod pow hypot min max clamp step smoothstep if
                  (log is the natural logarithm; if(cond, then, else) writes piecewise functions)
      Parameters  define with set_parameter, then use the name like a constant.
    PITFALLS
      - A name directly followed by ( is a function call: x(x+1) is an error, write x*(x+1).
      - Multi-letter names are split into single-letter variables: xy = x*y, but sinx is an error and xe must be x*e.
      - NaN counts as false; && and || short-circuit, so x>0 && log(x)>1 is safe at x = -1.
      - The tool call fails with the column of the mistake when a formula is wrong; fix it and retry.

    EXAMPLES
      explicit            a*sin(x)/x
      parametric          16*sin(t)^3   and   13*cos(t)-5*cos(2*t)-2*cos(3*t)-cos(4*t)   domain [0, 6.2832]
      polar               1 + cos(theta)
      implicit            x^3 + y^3 - 3*x*y
      region              x^2 + y^2 - 1   with relation <=
      surface             sin(x)*cos(y)
      parametricSurface   (2.4+0.7*cos(v))*cos(u), (2.4+0.7*cos(v))*sin(u), 0.7*sin(v)   (a torus, u and v in [0, 2π])
      spaceCurve          3*cos(t), 3*sin(t), t/4   domain [-12.57, 12.57]
      implicitSurface     x^2 + y^2 + z^2 - 4

    TYPICAL FLOW
      get_state → create_document (or use an open one) → set_parameter (optional) → add_layer … → render_image to check → set_view / save_document.
      Geometry (3D): add point / line (spaceCurve linear in t) / plane (implicitSurface linear in x,y,z) layers → relate or draw_relation for distances, angles, feet, intersections
      → projection layers for views and shadows. Hide a source layer (visible = false) to keep only the curve derived from it.
      Mistakes come back as tool errors that say what is wrong (with the column for formulas); fix and retry, nothing is half-added.
    """
}
