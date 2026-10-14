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
            description: "Render the document as a PNG you can look at, to check that the graph is what you intended. Uses the saved view of the document.",
            inputSchema: MCPSchema.object([
                "document_id": documentIDSchema,
                "width": MCPSchema.integer("Image width in pixels (default 900)", minimum: 200, maximum: 2400),
                "height": MCPSchema.integer("Image height in pixels (default 600)", minimum: 200, maximum: 2400),
            ]),
            tier: .read
        ) { args in
            let document = try await facade.resolve(try args.optionalUUID("document_id"))
            let width = try args.optionalInt("width") ?? 900
            let height = try args.optionalInt("height") ?? 600
            try checkImageSize(width: width, height: height)
            let png = try await facade.renderPNG(of: document, width: width, height: height)
            return MCPToolResult(text: "Rendered \(width)×\(height) PNG.", imagePNG: png)
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
            "extrude": MCPSchema.boolean("3D documents, 2D curve kinds only: sweep the curve along z into a vertical surface"),
            "source_a": MCPSchema.string("surfaceIntersection only: id of the first surface layer (surface, parametricSurface or implicitSurface)"),
            "source_b": MCPSchema.string("surfaceIntersection only: id of the second surface layer"),
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
        edit.extrude = try args.optionalBool("extrude")
        edit.sourceA = try args.optionalUUID("source_a")
        edit.sourceB = try args.optionalUUID("source_b")
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
                + "Every kind except surfaceIntersection requires 'formula'.",
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
      surface             formula = f(x,y)     z = f(x,y), over the axis box's x/y range
      parametricSurface   formula = x(u,v), secondary_formula = y(u,v), tertiary_formula = z(u,v), domain = [u0,u1], domain2 = [v0,v1]
      spaceCurve          formula = x(t), secondary_formula = y(t), tertiary_formula = z(t), domain = [t0,t1]
      implicitSurface     formula = F(x,y,z)   draws F = 0
      point               formula = x, secondary_formula = y, tertiary_formula = z   (numbers and parameters only, no variables); line_width = size
      surfaceIntersection source_a = id of one surface layer, source_b = id of another (surface / parametricSurface / implicitSurface); no formula.
                          Draws the curve where the two surfaces meet. Hiding the source layers keeps the curve.
      explicit / parametric / polar / implicit also work: drawn on the z = 0 plane, or with extrude = true swept along z into a vertical surface.
    Write the F of an implicit layer WITHOUT "= 0": x^2 + y^2 - 4, not x^2 + y^2 = 4.
    Everything in a 3D document is clipped to the axis box (default −4 … 4 on each axis); scale shapes to fit or call set_view.

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
    """
}
