import Foundation

/// 把一小段文字描述变成一份文档（再画出来）：给 Markdown 笔记里的 ```grapher 代码块用，也给 AI 写。
/// 一行一个内容，不用写 `.grapher` 那种大 JSON。完整写法见 `docs/text-format.md`（`get_reference` 里也有一份）。
///
/// ```
/// space
/// view: azimuth=35 elevation=25
/// param a = 1.5 [0, 3]
/// surface S: a*sin(x)*cos(y); opacity=0.7
/// tangent-plane: of=S; at=0.5, 1
/// ```
///
/// - 文字是唯一的真源：块里改了视角、参数，是用 `patch` 把那几行改掉再存回文字，不是整份重写。
/// - 一行里写错只跳过那一行，其余照常画；错误按行号报在 `errors` 里。
/// - 只依赖 Foundation：能在 Quick Look 扩展、别的 App 里用。
public enum GrapherText {

    public struct Diagnostic: Equatable, Sendable {
        /// 第几行（从 1 数）；0 = 不属于某一行。
        public var line: Int
        public var message: String

        public init(line: Int, message: String) {
            self.line = line
            self.message = message
        }
    }

    /// 平面图取景：中心与横向看到多宽（数据单位）。画布多大就按多大换成倍率，所以和画布尺寸无关。
    public struct PlaneFrame: Equatable, Sendable {
        public var centerX: Double
        public var centerY: Double
        public var width: Double

        public init(centerX: Double = 0, centerY: Double = 0, width: Double = 16) {
            self.centerX = centerX
            self.centerY = centerY
            self.width = width
        }
    }

    public struct Result: Sendable {
        public var document: GrapherDocument
        /// 宽 / 高，宿主按它定块的高度。
        public var aspect: Double
        /// 文字里写了 `theme:` 才有；宿主可以用自己的深浅色盖掉。
        public var themeName: String?
        public var planeFrame: PlaneFrame
        public var errors: [Diagnostic]
        /// 每个图层来自第几行（给公式报错用）。
        public var layerLines: [UUID: Int]

        public var isValid: Bool { errors.isEmpty }
    }

    public static let defaultAspect = 1.5

    // MARK: - 解析

    public static func parse(_ source: String) -> Result {
        var parser = Parser()
        return parser.run(source)
    }

    /// 本格式里每种图层的写法名（`get_reference` 与错误提示用）。
    public static let kindKeywords: [(PlotKind, String)] = [
        (.explicit, "explicit"), (.parametric, "parametric"), (.polar, "polar"), (.implicit, "implicit"),
        (.region, "region"), (.tangent, "tangent"), (.text, "text"), (.scatter, "scatter"),
        (.surface, "surface"), (.parametricSurface, "parametric-surface"), (.spaceCurve, "space-curve"),
        (.implicitSurface, "implicit-surface"), (.surfaceIntersection, "intersection"), (.point, "point"),
        (.projection, "projection"), (.tangentPlane, "tangent-plane"), (.gradientField, "gradient-field"),
        (.gradientFlow, "gradient-flow"),
    ]

    static func kind(for word: String) -> PlotKind? {
        let key = normalize(word)
        for (kind, keyword) in kindKeywords where normalize(keyword) == key { return kind }
        switch key {
        case "function", "fx": return .explicit
        case "inequality": return .region
        case "label": return .text
        case "points", "data": return .scatter
        case "flow": return .gradientFlow
        default: return nil
        }
    }

    /// 小写、去掉 `-` `_` 与空格：`Tangent-Plane` / `tangent_plane` / `tangentPlane` 都认。
    static func normalize(_ word: String) -> String {
        word.lowercased().filter { $0 != "-" && $0 != "_" && $0 != " " }
    }

    // MARK: - 回写

    /// 立体图的视角（角度制）。
    public struct SpaceViewValues: Equatable, Sendable {
        public var azimuthDegrees: Double
        public var elevationDegrees: Double
        public var zoom: Double
        public var range: Double
        public var center: SIMD3<Double>

        public init(_ view: View3D) {
            azimuthDegrees = view.azimuth * 180 / .pi
            elevationDegrees = view.elevation * 180 / .pi
            zoom = view.cameraZoom
            range = view.halfExtent
            center = view.center
        }
    }

    public enum ViewValues: Equatable, Sendable {
        case plane(PlaneFrame)
        case space(SpaceViewValues)
    }

    /// 把当前的视角和参数值写回文字：只改 `view:` 那一行和各 `param` 行的数值，别的字一个不动。
    /// 没有 `view:` 行时插在第一条 `param` / 图层之前。参数名在文字里找不到的忽略。
    public static func patch(source: String, view: ViewValues?, parameters: [String: Double]) -> String {
        var lines = source.components(separatedBy: "\n")
        var viewIndex: Int?
        var firstBodyIndex: Int?
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else { continue }
            if let colon = line.firstIndex(of: ":"), normalize(String(line[..<colon])) == "view" {
                if viewIndex == nil { viewIndex = index }
                continue
            }
            if let name = paramName(of: line) {
                if firstBodyIndex == nil { firstBodyIndex = index }
                if let value = parameters[name] { lines[index] = replacingParamValue(in: raw, with: value) }
                continue
            }
            if isHeader(line) { continue }
            if firstBodyIndex == nil { firstBodyIndex = index }
        }

        if let view {
            let text = viewLine(view)
            if let viewIndex {
                let indent = String(lines[viewIndex].prefix { $0 == " " || $0 == "\t" })
                lines[viewIndex] = indent + text
            } else if let firstBodyIndex {
                lines.insert(text, at: firstBodyIndex)
            } else {
                // 全是文件头（或空）：追加在最后一个非空行之后。
                while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
                lines.append(text)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func viewLine(_ view: ViewValues) -> String {
        switch view {
        case .plane(let frame):
            return "view: center=\(number(frame.centerX)),\(number(frame.centerY)) width=\(number(frame.width))"
        case .space(let v):
            var text = "view: azimuth=\(number(v.azimuthDegrees)) elevation=\(number(v.elevationDegrees))"
            if abs(v.zoom - 1) > 1e-6 { text += " zoom=\(number(v.zoom))" }
            if abs(v.range - 4) > 1e-6 { text += " range=\(number(v.range))" }
            if v.center != .zero { text += " center=\(number(v.center.x)),\(number(v.center.y)),\(number(v.center.z))" }
            return text
        }
    }

    /// 最多 4 位小数，去掉多余的 0。
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 10_000).rounded() / 10_000
        if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int64(rounded)) }
        var text = String(format: "%.4f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    private static let headerKeys: Set<String> = ["view", "theme", "aspect", "grid", "axes", "ticks", "minorgrid"]

    /// 文件头：维度、`theme:` 之类的设置行（不是图层）。
    private static func isHeader(_ line: String) -> Bool {
        if ["plane", "space", "2d", "3d"].contains(line.lowercased()) { return true }
        guard let colon = line.firstIndex(of: ":") else { return false }
        return headerKeys.contains(normalize(String(line[..<colon])))
    }

    private static func paramName(of line: String) -> String? {
        guard line.lowercased().hasPrefix("param"), let match = paramPattern.firstMatch(in: line) else { return nil }
        return match[1]
    }

    /// `param a = 1.5 [0, 3]`：名字、值、可选的 `[下限, 上限]`。
    private static let paramPattern = Pattern(#"^param\s+([^\s=\[\]]+)\s*=\s*([^\s\[]+)\s*(?:\[([^\]]*)\])?\s*$"#)

    private static func replacingParamValue(in line: String, with value: Double) -> String {
        guard let range = paramPattern.range(of: line, group: 2) else { return line }
        return line.replacingCharacters(in: range, with: number(value))
    }

    // MARK: - 解析器

    private struct Parser {
        var dimension: DocumentDimension?
        var dimensionLine = 0
        var document = GrapherDocument()
        var aspect = GrapherText.defaultAspect
        var themeName: String?
        var plane = PlaneFrame()
        var errors: [Diagnostic] = []
        var layerLines: [UUID: Int] = [:]
        var pendingRefs: [PendingRef] = []
        var viewLine: (line: Int, options: [String: String])?
        var drawn: [(index: Int, line: Int)] = []

        struct PendingRef {
            var layerIndex: Int
            var line: Int
            var names: [String]
            var onto: String?
        }

        mutating func run(_ source: String) -> Result {
            for (offset, raw) in source.components(separatedBy: .newlines).enumerated() {
                parseLine(raw, number: offset + 1)
            }
            let resolved = dimension ?? (document.layers.contains { $0.kind.dimension == .space } ? .space : .plane)
            document.dimension = resolved
            let allowedKinds = PlotKind.cases(for: resolved)
            for (index, line) in drawn where document.layers.indices.contains(index) {
                let kind = document.layers[index].kind
                if !allowedKinds.contains(kind) {
                    let word = GrapherText.kindKeywords.first { $0.0 == kind }?.1 ?? kind.rawValue
                    fail(line, String(format: L("A %@ document cannot hold '%@' layers."),
                                      resolved == .space ? "3D" : "2D", word))
                }
            }
            applyView()
            resolveReferences()
            checkFormulas()
            applyPlaneFrame()
            errors.sort { $0.line < $1.line }
            return Result(document: document, aspect: aspect, themeName: themeName, planeFrame: plane,
                          errors: errors, layerLines: layerLines)
        }

        mutating func fail(_ line: Int, _ message: String) {
            errors.append(Diagnostic(line: line, message: message))
        }

        // MARK: 行

        mutating func parseLine(_ raw: String, number: Int) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else { return }

            switch line.lowercased() {
            case "plane", "2d": dimension = .plane; dimensionLine = number; return
            case "space", "3d": dimension = .space; dimensionLine = number; return
            default: break
            }
            if let paramMatch = GrapherText.paramPattern.firstMatch(in: line) {
                parseParam(paramMatch, number: number)
                return
            }
            let firstWord = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ":" }).first.map { $0.lowercased() }
            if firstWord == "param", !line.contains(":") || line.lowercased().hasPrefix("param ") {
                fail(number, L("Write a parameter like: param a = 1.5 [0, 3]"))
                return
            }
            guard let colon = line.firstIndex(of: ":") else {
                fail(number, String(format: L("Cannot read this line: '%@'. A layer looks like 'surface S: sin(x)*cos(y)'."), line))
                return
            }
            let head = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let body = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            let key = GrapherText.normalize(head)
            if GrapherText.headerKeys.contains(key) {
                parseSetting(key, body, number: number)
                return
            }
            parseLayer(head: head, body: body, number: number)
        }

        mutating func parseParam(_ match: Pattern.Match, number: Int) {
            let name = match[1]
            var definition = ParameterDefinition(name: name)
            guard definition.isNameValid else {
                fail(number, String(format: L("'%@' cannot be a parameter name (reserved or not a plain word)."), name))
                return
            }
            guard !document.parameters.contains(where: { $0.name == name }) else {
                fail(number, String(format: L("Parameter '%@' is defined twice."), name))
                return
            }
            guard let value = Value.number(match[2]) else {
                fail(number, String(format: L("Parameter '%@' needs a number, got '%@'."), name, match[2]))
                return
            }
            definition.value = value
            var lower = min(-5, value.rounded(.down))
            var upper = max(5, value.rounded(.up))
            if let range = match.optional(3) {
                let parts = range.split(separator: ",").map { String($0) }
                guard parts.count == 2, let low = Value.number(parts[0]), let high = Value.number(parts[1]), low < high else {
                    fail(number, String(format: L("The range of '%@' must be [lower, upper] with lower < upper."), name))
                    return
                }
                lower = low
                upper = high
            }
            definition.lowerBound = lower
            definition.upperBound = upper
            document.parameters.append(definition)
        }

        mutating func parseSetting(_ key: String, _ body: String, number: Int) {
            switch key {
            case "theme":
                switch body.lowercased() {
                case "light": document.theme = .light; themeName = "light"
                case "dark": document.theme = .dark; themeName = "dark"
                default: fail(number, L("theme must be light or dark."))
                }
            case "aspect":
                if let value = Value.ratio(body), (0.3...4).contains(value) {
                    aspect = value
                } else {
                    fail(number, L("aspect must be a ratio like 1.5 or 16:9 (between 0.3 and 4)."))
                }
            case "grid", "axes", "ticks", "minorgrid":
                guard let on = Value.bool(body) else {
                    fail(number, String(format: L("'%@' must be on or off."), key))
                    return
                }
                switch key {
                case "grid": document.showGrid = on
                case "axes": document.showAxes = on
                case "ticks": document.showTickLabels = on
                default: document.showMinorGrid = on
                }
            default:
                // view：视角依赖文档维度，等整份读完再套。
                viewLine = (number, Self.pairs(body))
            }
        }

        // MARK: 视角

        /// `a=1 b=2,3` → 字典；值里不含空格。
        static func pairs(_ text: String) -> [String: String] {
            var result: [String: String] = [:]
            for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { result[GrapherText.normalize(parts[0])] = parts[1] }
            }
            return result
        }

        mutating func applyView() {
            guard let (line, options) = viewLine else { return }
            let allowed: Set<String> = document.dimension == .space
                ? ["azimuth", "elevation", "zoom", "range", "center"]
                : ["center", "width"]
            for key in options.keys.sorted() where !allowed.contains(key) {
                fail(line, String(format: L("Unknown view setting '%@'. Allowed: %@."), key, allowed.sorted().joined(separator: ", ")))
            }
            func number(_ key: String) -> Double? { options[key].flatMap(Value.number) }
            func vector(_ key: String, count: Int) -> [Double]? {
                guard let text = options[key] else { return nil }
                let parts = text.split(separator: ",").compactMap { Value.number(String($0)) }
                return parts.count == count ? parts : nil
            }
            if document.dimension == .space {
                var view = View3D.standard
                if let a = number("azimuth") { view.azimuth = remainder(a * .pi / 180, 2 * .pi) }
                if let e = number("elevation") {
                    view.elevation = min(max(e * .pi / 180, -View3D.elevationLimit), View3D.elevationLimit)
                }
                if let z = number("zoom") { view.cameraZoom = min(max(z, View3D.cameraZoomRange.lowerBound), View3D.cameraZoomRange.upperBound) }
                if let r = number("range"), r > 0 { view.halfExtent = min(max(r, View3D.halfExtentRange.lowerBound), View3D.halfExtentRange.upperBound) }
                if let c = vector("center", count: 3) { view.center = SIMD3(c[0], c[1], c[2]) }
                if options["center"] != nil, vector("center", count: 3) == nil {
                    fail(line, L("center must be three numbers like center=0,0,1."))
                }
                document.view3D = view
            } else {
                if let c = vector("center", count: 2) { plane.centerX = c[0]; plane.centerY = c[1] }
                if options["center"] != nil, vector("center", count: 2) == nil {
                    fail(line, L("center must be two numbers like center=0,0."))
                }
                if let w = number("width") {
                    if w > 0 { plane.width = w } else { fail(line, L("width must be positive.")) }
                }
            }
        }

        mutating func applyPlaneFrame() {
            let widthPixels = 1200.0
            document.viewport = Viewport2D(
                centerX: plane.centerX, centerY: plane.centerY, scale: widthPixels / max(plane.width, 1e-9),
                widthPixels: widthPixels, heightPixels: (widthPixels / aspect).rounded())
        }

        // MARK: 图层

        mutating func parseLayer(head: String, body: String, number: Int) {
            let word = head.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? head
            let name = String(head.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
            guard let kind = GrapherText.kind(for: word) else {
                let known = GrapherText.kindKeywords.map(\.1).joined(separator: ", ")
                fail(number, String(format: L("Unknown layer type '%@'. Types: %@."), word, known))
                return
            }
            var layer = Layer.makeDefault(kind: kind, index: document.layers.count)
            layer.usesExplicitDomain = kind.usesDomain && kind != .explicit
            if !name.isEmpty {
                if name.contains(",") || name.contains("=") {
                    fail(number, L("A layer name cannot contain ',' or '='."))
                    return
                }
                if document.layers.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    fail(number, String(format: L("Two layers are named '%@'."), name))
                    return
                }
                layer.name = name
            }

            let parts = Segments.parse(body)
            let allowed = Self.allowedOptions(for: kind)
            var options: [String: String] = [:]
            var positional: [String] = []
            for part in parts {
                switch part {
                case .domain(let variable, let lower, let upper):
                    setDomain(&layer, variable: variable, lower: lower, upper: upper, number: number)
                case .option(let key, let value):
                    guard allowed.contains(key) || key == "opacity" else {
                        fail(number, String(format: L("'%@' layers have no option '%@'. Options: %@."),
                                            word, key, (allowed + ["opacity"]).sorted().joined(separator: ", ")))
                        continue
                    }
                    options[key] = value
                case .positional(let text):
                    positional.append(text)
                }
            }

            guard setFormulas(&layer, positional: positional, word: word, number: number) else { return }
            guard applyOptions(&layer, options: options, word: word, number: number) else { return }

            document.layers.append(layer)
            layerLines[layer.id] = number
            drawn.append((document.layers.count - 1, number))
        }

        static func allowedOptions(for kind: PlotKind) -> [String] {
            let base = ["color", "width", "dash", "hidden"]
            switch kind {
            case .explicit, .parametric, .polar: return base + ["extrude"]
            case .implicit: return base + ["extrude", "levels"]
            case .region: return ["color", "hidden"]
            case .surface: return base + ["slope"]
            case .parametricSurface, .implicitSurface, .spaceCurve: return base
            case .surfaceIntersection: return base + ["of"]
            case .point: return base + ["label"]
            case .projection: return base + ["of", "onto", "offset", "direction", "projectors"]
            case .tangent: return base + ["of", "at", "normal"]
            case .tangentPlane: return base + ["of", "at"]
            case .text: return ["color", "at", "size", "hidden"]
            case .scatter: return base + ["fit"]
            case .gradientField: return base + ["of", "density", "scale", "floor"]
            case .gradientFlow: return base + ["of", "ball", "scale"]
            }
        }

        mutating func setDomain(_ layer: inout Layer, variable: String, lower: String, upper: String, number: Int) {
            let kind = layer.kind
            let second = variable == "v"
            let valid: Bool
            switch kind {
            case .explicit: valid = variable == "x"
            case .parametric, .spaceCurve: valid = variable == "t"
            case .polar: valid = variable == "t" || variable == "theta" || variable == "θ"
            case .parametricSurface: valid = variable == "u" || second
            default: valid = false
            }
            guard valid else {
                fail(number, String(format: L("A %@ layer has no range for '%@'."), kind.rawValue, variable))
                return
            }
            let low = Value.numberOrFormula(lower)
            let high = Value.numberOrFormula(upper)
            if second {
                layer.domain2Lower = low.0
                layer.domain2Upper = high.0
                layer.domain2LowerFormula = low.1
                layer.domain2UpperFormula = high.1
            } else {
                layer.domainLower = low.0
                layer.domainUpper = high.0
                layer.domainLowerFormula = low.1
                layer.domainUpperFormula = high.1
                layer.usesExplicitDomain = true
            }
            if low.1.isEmpty, high.1.isEmpty, low.0 >= high.0 {
                fail(number, String(format: L("The range of '%@' must be lower..upper with lower < upper."), variable))
            }
        }

        /// 把位置参数（公式）放进图层的各公式字段。
        mutating func setFormulas(_ layer: inout Layer, positional: [String], word: String, number: Int) -> Bool {
            let kind = layer.kind
            func need(_ count: Int, _ example: String) -> Bool {
                guard positional.count == count else {
                    fail(number, String(format: L("A '%@' layer needs %ld formula(s) separated by ';', e.g. %@."), word, count, example))
                    return false
                }
                return true
            }
            switch kind {
            case .explicit:
                guard need(1, "sin(x)") else { return false }
                layer.formula = Self.stripPrefix(positional[0], names: ["y", "f(x)"])
            case .polar:
                guard need(1, "1+cos(theta)") else { return false }
                layer.formula = Self.stripPrefix(positional[0], names: ["r", "r(theta)", "r(t)", "r(θ)"])
            case .surface:
                guard need(1, "sin(x)*cos(y)") else { return false }
                layer.formula = Self.stripPrefix(positional[0], names: ["z", "f(x,y)", "f(x, y)"])
            case .implicit, .implicitSurface:
                guard need(1, kind == .implicit ? "x^2+y^2=1" : "x^2+y^2+z^2=4") else { return false }
                layer.formula = Self.equationToZero(positional[0])
            case .region:
                guard need(1, "x^2+y^2<=1") else { return false }
                guard let (formula, relation) = Self.splitRelation(positional[0]) else {
                    fail(number, L("A region needs an inequality such as x^2+y^2<=1."))
                    return false
                }
                layer.formula = formula
                layer.relation = relation
            case .parametric:
                guard need(2, "cos(t); sin(t)") else { return false }
                layer.formula = Self.stripAxis(positional[0])
                layer.secondaryFormula = Self.stripAxis(positional[1])
            case .spaceCurve, .parametricSurface:
                guard need(3, "cos(t); sin(t); t/4") else { return false }
                layer.formula = Self.stripAxis(positional[0])
                layer.secondaryFormula = Self.stripAxis(positional[1])
                layer.tertiaryFormula = Self.stripAxis(positional[2])
            case .point:
                guard need(3, "1; 2; 3") else { return false }
                layer.formula = Self.stripAxis(positional[0])
                layer.secondaryFormula = Self.stripAxis(positional[1])
                layer.tertiaryFormula = Self.stripAxis(positional[2])
            case .text:
                guard need(1, "\"hello\"") else { return false }
                layer.formula = Self.unquote(positional[0])
            case .scatter:
                guard !positional.isEmpty else {
                    fail(number, L("A scatter layer needs points: scatter: 1, 2.1; 2, 3.9; 3, 6.2"))
                    return false
                }
                layer.formula = positional.joined(separator: "\n")
            case .gradientFlow:
                layer.formula = positional.joined(separator: "\n")
            case .surfaceIntersection, .projection, .tangent, .tangentPlane, .gradientField:
                guard positional.isEmpty else {
                    fail(number, String(format: L("A '%@' layer has no formula; it only takes options such as of=."), word))
                    return false
                }
            }
            return true
        }

        mutating func applyOptions(_ layer: inout Layer, options: [String: String], word: String, number: Int) -> Bool {
            let kind = layer.kind
            var ok = true
            func fail(_ message: String) { self.fail(number, message); ok = false }

            if let text = options["extrude"] {
                guard let on = Value.bool(text) else { fail(String(format: L("'%@' must be on or off."), "extrude")); return false }
                layer.extrudesInSpace = on
            }
            if let text = options["color"] {
                if let color = Value.color(text) {
                    layer.lineStyle.color = color
                    layer.fillStyle.color = color.withAlpha(layer.fillStyle.color.a)
                } else {
                    fail(String(format: L("'%@' is not a color. Use #RRGGBB or a name like red, blue, green."), text))
                }
            }
            if let text = options["width"] {
                if let value = Value.number(text), (0.2...20).contains(value) {
                    layer.lineStyle.width = value
                } else {
                    fail(L("width must be a number between 0.2 and 20."))
                }
            }
            if let text = options["dash"] {
                if let on = Value.bool(text) { layer.lineStyle.isDashed = on } else { fail(String(format: L("'%@' must be on or off."), "dash")) }
            }
            if let text = options["hidden"] {
                if let on = Value.bool(text) { layer.isVisible = !on } else { fail(String(format: L("'%@' must be on or off."), "hidden")) }
            }
            if let text = options["opacity"] {
                let applies = kind.isSurfaceSource || kind == .region || kind == .tangentPlane
                    || (kind.canExtrude && layer.extrudesInSpace)
                if !applies {
                    fail(String(format: L("'%@' layers have no opacity; only surfaces and regions do."), word))
                } else if let value = Value.number(text), (0.05...1).contains(value) {
                    layer.fillStyle.opacity = value
                } else {
                    fail(L("opacity must be a number between 0.05 and 1."))
                }
            }
            if let text = options["levels"] {
                let values = text.split(separator: ",").compactMap { Value.number(String($0)) }
                if values.count == text.split(separator: ",").count, !values.isEmpty {
                    layer.extraLevels = values
                } else {
                    fail(L("levels must be numbers separated by commas, e.g. levels=1,2,-1."))
                }
            }
            if let text = options["label"] {
                if let on = Value.bool(text) { layer.showsLabel = on } else { fail(String(format: L("'%@' must be on or off."), "label")) }
            }
            if let text = options["slope"] {
                if let on = Value.bool(text) { layer.colorsBySlope = on } else { fail(String(format: L("'%@' must be on or off."), "slope")) }
            }
            if let text = options["fit"] {
                if let on = Value.bool(text) { layer.showsFit = on } else { fail(String(format: L("'%@' must be on or off."), "fit")) }
            }
            if let text = options["normal"] {
                if let on = Value.bool(text) { layer.drawsNormal = on } else { fail(String(format: L("'%@' must be on or off."), "normal")) }
            }
            if let text = options["floor"] {
                if let on = Value.bool(text) { layer.gradientOnFloor = on } else { fail(String(format: L("'%@' must be on or off."), "floor")) }
            }
            if let text = options["projectors"] {
                if let on = Value.bool(text) { layer.showsProjectors = on } else { fail(String(format: L("'%@' must be on or off."), "projectors")) }
            }
            if let text = options["density"] {
                if let value = Value.number(text), (2...40).contains(value) {
                    layer.gridDensity = Int(value.rounded())
                } else {
                    fail(L("density must be between 2 and 40."))
                }
            }
            if let text = options["scale"] {
                if let value = Value.number(text), abs(value) >= 0.1, abs(value) <= 5 {
                    layer.arrowScale = value
                } else {
                    fail(L("scale must be between 0.1 and 5 (negative draws the descent direction)."))
                }
            }
            if let text = options["size"] {
                if let value = Value.number(text), (6...96).contains(value) {
                    layer.fontSize = value
                } else {
                    fail(L("size must be between 6 and 96."))
                }
            }
            if let text = options["ball"] {
                layer.secondaryFormula = text
            } else if kind == .gradientFlow {
                layer.secondaryFormula = "1"
            }
            if let text = options["offset"] {
                let value = Value.numberOrFormula(text)
                layer.projectionOffset = value.0
                layer.projectionOffsetFormula = value.1
            }
            if let text = options["direction"] {
                let parts = text.split(separator: ",").compactMap { Value.number(String($0)) }
                if parts.count == 3 {
                    let v = SIMD3(parts[0], parts[1], parts[2])
                    layer.projectionDirection = (v * v).sum() > 1e-18 ? v : nil
                } else {
                    fail(L("direction must be three numbers like direction=1,0,1."))
                }
            }
            if let text = options["at"] {
                let parts = Segments.splitTopLevel(text, separator: ",")
                let values = parts.map(Value.numberOrFormula)
                switch kind {
                case .tangent:
                    if values.count == 1 {
                        layer.anchorU = values[0].0; layer.anchorUFormula = values[0].1
                    } else { fail(L("A tangent needs one position: at=1.2.")) }
                case .tangentPlane:
                    if values.count == 2 {
                        layer.anchorU = values[0].0; layer.anchorUFormula = values[0].1
                        layer.anchorV = values[1].0; layer.anchorVFormula = values[1].1
                    } else { fail(L("A tangent plane needs two positions: at=0.5, 1.")) }
                case .text:
                    if values.count == 2 || values.count == 3 {
                        layer.anchorU = values[0].0; layer.anchorUFormula = values[0].1
                        layer.anchorV = values[1].0; layer.anchorVFormula = values[1].1
                        if values.count == 3 { layer.anchorW = values[2].0; layer.anchorWFormula = values[2].1 }
                    } else { fail(L("Text needs a position: at=x, y (or x, y, z in 3D).")) }
                default: break
                }
            } else if kind == .tangent || kind == .tangentPlane {
                fail(String(format: L("A '%@' layer needs 'at'."), word))
            }

            var names: [String] = []
            if let text = options["of"] {
                names = Segments.splitTopLevel(text, separator: ",")
            }
            let needed: Int
            switch kind {
            case .surfaceIntersection: needed = 2
            case .projection, .tangent, .tangentPlane, .gradientField, .gradientFlow: needed = 1
            default: needed = 0
            }
            if needed > 0, names.count != needed {
                fail(String(format: L("A '%@' layer needs of= with %ld layer name(s)."), word, needed))
            }
            var onto: String?
            if kind == .projection {
                let target = (options["onto"] ?? "xy").trimmingCharacters(in: .whitespaces)
                switch target.lowercased() {
                case "xy": layer.projectionTarget = .xy
                case "yz": layer.projectionTarget = .yz
                case "xz": layer.projectionTarget = .xz
                default: layer.projectionTarget = .plane; onto = target
                }
            }
            if ok, needed > 0 {
                pendingRefs.append(PendingRef(layerIndex: document.layers.count, line: number, names: names, onto: onto))
            }
            return ok
        }

        // MARK: 引用与公式检查

        mutating func resolveReferences() {
            func find(_ name: String) -> Layer? {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                return document.layers.first { $0.name == trimmed }
                    ?? document.layers.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
            }
            for ref in pendingRefs where document.layers.indices.contains(ref.layerIndex) {
                var layer = document.layers[ref.layerIndex]
                var sources: [Layer] = []
                for name in ref.names {
                    guard let source = find(name) else {
                        fail(ref.line, String(format: L("No layer named '%@'. Layers: %@."), name,
                                              document.layers.map(\.name).joined(separator: ", ")))
                        continue
                    }
                    sources.append(source)
                }
                guard sources.count == ref.names.count else { continue }
                if let id = sources.first?.id { layer.sourceA = id }
                if layer.kind == .surfaceIntersection { layer.sourceB = sources.last?.id }
                if layer.kind == .surfaceIntersection, sources.count == 2, sources[0].id == sources[1].id {
                    fail(ref.line, L("An intersection needs two different layers."))
                }
                if let onto = ref.onto {
                    if let target = find(onto) { layer.sourceB = target.id } else {
                        fail(ref.line, String(format: L("onto must be xy, yz, xz or a plane layer name; no layer named '%@'."), onto))
                    }
                }
                document.layers[ref.layerIndex] = layer
            }
        }

        mutating func checkFormulas() {
            let compiled = LayerCompiler().compile(document)
            for item in compiled {
                guard let line = layerLines[item.layer.id] else { continue }
                let layer = item.layer
                let variables = Self.variableHint(layer.kind)
                if let error = item.primaryError { fail(line, String(format: L("Formula: %@ (variables: %@)"), error.description, variables)) }
                if let error = item.secondaryError { fail(line, String(format: L("Formula: %@ (variables: %@)"), error.description, variables)) }
                if let error = item.tertiaryError { fail(line, String(format: L("Formula: %@ (variables: %@)"), error.description, variables)) }
                if let error = item.domainError { fail(line, String(format: L("Range or position: %@ (only numbers and parameters)"), error.description)) }
                if layer.kind == .scatter, ScatterData.parse(layer.formula).isEmpty {
                    fail(line, L("The scatter data has no valid points. Write rows like: 1, 2.1; 2, 3.9."))
                }
                if layer.kind == .gradientFlow, GradientSeeds.fields(layer.formula).isEmpty {
                    fail(line, L("The starting points have no valid \"x, y\" row. Write rows like: 1.5, 0.5; -2, 2."))
                }
            }
            // 来源类型：引用解析完才能查。
            func compiledLayer(_ id: UUID?) -> LayerCompiler.CompiledLayer? { compiled.first { $0.layer.id == id } }
            for item in compiled {
                guard let line = layerLines[item.layer.id], !item.hasError else { continue }
                let layer = item.layer
                let source = compiledLayer(layer.sourceA)
                switch layer.kind {
                case .tangent:
                    guard let source else { continue }
                    if !source.layer.kind.isTangentSource {
                        fail(line, String(format: L("A tangent needs an explicit, parametric or polar curve; '%@' is not."), source.layer.name))
                    } else if Tangents.tangent(of: source, at: layer.anchorU) == nil {
                        fail(line, String(format: L("The curve has no tangent at %@."), GrapherText.number(layer.anchorU)))
                    }
                case .tangentPlane:
                    guard let source else { continue }
                    if !source.layer.kind.isTangentPlaneSource {
                        fail(line, String(format: L("A tangent plane needs a surface or parametric surface; '%@' is not."), source.layer.name))
                    } else if Tangents.tangentPlane(of: source, u: layer.anchorU, v: layer.anchorV) == nil {
                        fail(line, L("The surface has no tangent plane at that point."))
                    }
                case .gradientField, .gradientFlow:
                    if let source, !source.layer.kind.isGradientSource {
                        fail(line, String(format: L("A gradient needs a 'surface' layer z = f(x, y); '%@' is not."), source.layer.name))
                    }
                case .surfaceIntersection:
                    for other in [layer.sourceA, layer.sourceB] {
                        if let source = compiledLayer(other), !source.layer.kind.isSurfaceSource {
                            fail(line, String(format: L("An intersection needs surfaces; '%@' is not one."), source.layer.name))
                        }
                    }
                case .projection:
                    if let source, !source.layer.kind.isProjectable {
                        fail(line, String(format: L("A projection needs a point, space curve or intersection; '%@' is not."), source.layer.name))
                    }
                    if layer.projectionTarget == .plane {
                        if let target = compiledLayer(layer.sourceB) {
                            if case .plane? = SpaceGeometry.recognize(target, in: compiled) {} else {
                                fail(line, String(format: L("onto must be a plane (a linear surface); '%@' is not."), target.layer.name))
                            }
                        }
                    }
                default: break
                }
            }
        }

        static func variableHint(_ kind: PlotKind) -> String {
            let list = kind.primaryVariables.isEmpty ? "—" : kind.primaryVariables.joined(separator: ", ")
            switch kind {
            case .point, .text: return L("numbers and parameters only")
            case .parametric, .spaceCurve: return "t"
            case .polar: return "theta"
            default: return list
            }
        }

        // MARK: 公式文字的整理

        static func unquote(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
                return String(trimmed.dropFirst().dropLast())
            }
            return trimmed
        }

        /// 去掉 `y =` / `z =` / `f(x) =` 这样的前缀（后面不能是另一个 `=`）。
        static func stripPrefix(_ text: String, names: [String]) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            for name in names where trimmed.hasPrefix(name) {
                let rest = trimmed.dropFirst(name.count).drop { $0 == " " }
                if rest.first == "=", !rest.dropFirst().hasPrefix("=") {
                    return String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
            }
            return trimmed
        }

        /// 参数方程各分量的 `x =` / `y(t) =` 前缀。
        static func stripAxis(_ text: String) -> String {
            stripPrefix(text, names: ["x(t)", "y(t)", "z(t)", "x(u,v)", "y(u,v)", "z(u,v)",
                                     "x(u, v)", "y(u, v)", "z(u, v)", "x", "y", "z"])
        }

        /// `lhs = rhs` → `(lhs) - (rhs)`；没有等号原样（已经是 F = 0 的左边）。
        static func equationToZero(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let chars = Array(trimmed)
            var equalsAt: Int?
            for (i, c) in chars.enumerated() where c == "=" {
                let previous = i > 0 ? chars[i - 1] : " "
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if "<>=!".contains(previous) || next == "=" { continue }
                if equalsAt != nil { return trimmed }
                equalsAt = i
            }
            guard let at = equalsAt else { return trimmed }
            let lhs = String(chars[..<at]).trimmingCharacters(in: .whitespaces)
            let rhs = String(chars[(at + 1)...]).trimmingCharacters(in: .whitespaces)
            if rhs == "0" { return lhs }
            return "(\(lhs)) - (\(rhs))"
        }

        /// `lhs <= rhs` → (`lhs - rhs`, ≤)。
        static func splitRelation(_ text: String) -> (String, RegionRelation)? {
            for (symbol, relation) in [("<=", RegionRelation.lessOrEqual), (">=", .greaterOrEqual), ("≤", .lessOrEqual),
                                       ("≥", .greaterOrEqual), ("<", .less), (">", .greater)] {
                guard let range = text.range(of: symbol) else { continue }
                let lhs = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let rhs = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !lhs.isEmpty, !rhs.isEmpty else { return nil }
                return (rhs == "0" ? lhs : "(\(lhs)) - (\(rhs))", relation)
            }
            return nil
        }
    }

    // MARK: - 一行的分段

    /// 一个图层行冒号后面的内容，用 `;` 分段：选项 `key=value`、范围 `t=0..2*pi`、其余是公式（位置参数）。
    enum Segments {
        enum Part {
            case option(String, String)
            case domain(String, String, String)
            case positional(String)
        }

        static let flagKeys: Set<String> = [
            "dash", "hidden", "extrude", "slope", "fit", "normal", "floor", "label", "projectors",
        ]
        static let valueKeys: Set<String> = [
            "color", "width", "opacity", "levels", "of", "onto", "offset", "direction", "at",
            "density", "scale", "size", "ball",
        ]

        static func parse(_ body: String) -> [Part] {
            splitTopLevel(body, separator: ";").compactMap { raw in
                let text = raw.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                if let equals = optionEquals(in: text) {
                    let key = normalize(String(text[..<equals]))
                    let value = String(text[text.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                    if flagKeys.contains(key) || valueKeys.contains(key) { return .option(key, value) }
                    if ["x", "t", "theta", "θ", "u", "v"].contains(key), let dots = value.range(of: "..") {
                        let lower = value[..<dots.lowerBound].trimmingCharacters(in: .whitespaces)
                        let upper = value[dots.upperBound...].trimmingCharacters(in: .whitespaces)
                        if !lower.isEmpty, !upper.isEmpty { return .domain(key, lower, upper) }
                    }
                } else if flagKeys.contains(normalize(text)) {
                    return .option(normalize(text), "on")
                }
                return .positional(text)
            }
        }

        /// 第一个单独的 `=`（不是 `<=` `>=` `==` 的一部分）；它前面必须是一个简单的词，否则这一段是公式。
        private static func optionEquals(in text: String) -> String.Index? {
            guard let index = text.firstIndex(of: "=") else { return nil }
            let head = text[..<index].trimmingCharacters(in: .whitespaces)
            guard !head.isEmpty, head.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" || $0.isNumber }) else { return nil }
            let after = text.index(after: index)
            if after < text.endIndex, text[after] == "=" { return nil }
            return index
        }

        /// 只在最外层（不在引号、括号里）按 `separator` 切开。
        static func splitTopLevel(_ text: String, separator: Character) -> [String] {
            var parts: [String] = []
            var current = ""
            var depth = 0
            var inQuote = false
            for c in text {
                if c == "\"" { inQuote.toggle() }
                if !inQuote {
                    if c == "(" || c == "[" { depth += 1 }
                    if c == ")" || c == "]" { depth = max(0, depth - 1) }
                    if c == separator, depth == 0 {
                        parts.append(current)
                        current = ""
                        continue
                    }
                }
                current.append(c)
            }
            parts.append(current)
            return parts.map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    // MARK: - 取值

    enum Value {
        static func number(_ text: String) -> Double? {
            guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite else { return nil }
            return value
        }

        /// 是数就当数，否则当含参数的公式（数填 0 占位）。
        static func numberOrFormula(_ text: String) -> (Double, String) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let value = number(trimmed) { return (value, "") }
            return (0, trimmed)
        }

        static func bool(_ text: String) -> Bool? {
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "on", "true", "yes", "1": return true
            case "off", "false", "no", "0": return false
            default: return nil
            }
        }

        /// `1.5` 或 `16:9`。
        static func ratio(_ text: String) -> Double? {
            let parts = text.split(separator: ":").map { number(String($0)) }
            if parts.count == 1, let value = parts[0] { return value }
            if parts.count == 2, let w = parts[0], let h = parts[1], h > 0 { return w / h }
            return nil
        }

        static func color(_ text: String) -> RGBAColor? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                var digits = String(trimmed.dropFirst())
                if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
                guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
                let hasAlpha = digits.count == 8
                let shift: UInt64 = hasAlpha ? 8 : 0
                func channel(_ n: UInt64) -> Double { Double((value >> (shift + 8 * n)) & 0xFF) / 255 }
                return RGBAColor(channel(2), channel(1), channel(0), hasAlpha ? Double(value & 0xFF) / 255 : 1)
            }
            let named: [String: RGBAColor] = [
                "red": RGBAColor.paletteColor(0), "blue": RGBAColor.paletteColor(1), "green": RGBAColor.paletteColor(2),
                "orange": RGBAColor.paletteColor(3), "purple": RGBAColor.paletteColor(4), "teal": RGBAColor.paletteColor(5),
                "pink": RGBAColor.paletteColor(6), "brown": RGBAColor.paletteColor(7),
                "black": .black, "white": .white, "gray": RGBAColor(0.5, 0.5, 0.52), "grey": RGBAColor(0.5, 0.5, 0.52),
                "yellow": RGBAColor(0.95, 0.77, 0.06),
            ]
            return named[trimmed.lowercased()]
        }
    }

    // MARK: - 小正则

    struct Pattern {
        struct Match {
            let source: String
            let result: NSTextCheckingResult
            subscript(_ group: Int) -> String { optional(group) ?? "" }
            func optional(_ group: Int) -> String? {
                let range = result.range(at: group)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: source) else { return nil }
                return String(source[swiftRange])
            }
        }

        let expression: NSRegularExpression

        init(_ pattern: String) {
            expression = try! NSRegularExpression(pattern: pattern)
        }

        func firstMatch(in text: String) -> Match? {
            guard let result = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return Match(source: text, result: result)
        }

        func range(of text: String, group: Int) -> Range<String.Index>? {
            guard let result = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            let range = result.range(at: group)
            return range.location == NSNotFound ? nil : Range(range, in: text)
        }
    }
}
