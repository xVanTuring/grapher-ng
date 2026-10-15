import Foundation

/// 公式里一个原子的类别：决定它两边留多少空（同 TeX 的 ord / op / bin / rel …）。
public enum MathClass: Sendable, Equatable {
    case ord, op, bin, rel, open, close, punct, inner
}

/// 大小可变的定界符（`\left( … \right)`、`\big(`）。
public enum MathFractionStyle: Sendable, Equatable {
    /// `\frac`：跟着所在的样式走（行内小一号，行间正常）。
    case auto
    /// `\dfrac`：总按行间样式排。
    case display
    /// `\tfrac`：总按行内样式排。
    case text
}

public enum MathAccent: Sendable, Equatable {
    case vec, hat, tilde, bar, dot, ddot, overline, underline, overrightarrow, overleftarrow
}

/// 大算子的上下标放哪：行间时放正上 / 正下方（∑、lim 的默认），总是放正上 / 正下方（写了 `\limits`），
/// 总是放右边（积分号的默认、写了 `\nolimits`）。
public enum MathLimits: Sendable, Equatable {
    case displayOnly, always, never
}

/// `\displaystyle` 之类：改后面同一组里的样式。
public enum MathStyleSwitch: Sendable, Equatable {
    case display, text, script
}

/// TeX 公式的语法树。字符在解析时就换成要显示的 Unicode（变量用数学斜体 𝑥、𝛾，`\mathbb R` 是 ℝ），
/// 排版（`GrapherRender.MathTypesetter`）只管量尺寸、摆位置。
public indirect enum MathNode: Sendable, Equatable {
    /// 一个或几个字符，用数学字体写。
    case symbol(String, MathClass)
    /// `\text{…}`、公式里的中文：用正文字体写。
    case text(String)
    /// 大算子：`large` 在行间公式里放大（∫ ∑），`limits` 上下标放哪，`integral` 积分号的下标往左收（斜体积分号）。
    case largeOperator(String, large: Bool, limits: MathLimits, integral: Bool)
    /// `{…}` 或 `\mathrel{…}` 之类：一组当一个原子。
    case group([MathNode], MathClass)
    case scripts(base: MathNode, sub: [MathNode]?, sup: [MathNode]?)
    case fraction([MathNode], [MathNode], style: MathFractionStyle, rule: Bool)
    case radical(index: [MathNode]?, body: [MathNode])
    case accent(MathAccent, [MathNode])
    /// `\left( … \right)`：两边的定界符随内容变高；"." 表示这一边不画。
    case delimited(left: String, body: [MathNode], right: String)
    /// `\big(` 这种指定大小的定界符；`size` 是高度（em）。
    case bigDelimiter(String, MathClass, size: Double)
    /// 空白（em），可以是负数（`\!`）。
    case space(Double)
    case style(MathStyleSwitch)
}

/// 把 TeX 公式（`$…$` 里面那段）解析成 `MathNode`。只认常用的一小部分；不认识的命令原样写出来，不报错。
public enum MathTeX {

    public static func parse(_ source: String) -> [MathNode] {
        var parser = Parser(Array(source))
        return parser.parseList(until: .end)
    }

    // MARK: - 字符映射

    /// 字母换成数学字母表里的字形（斜体、粗体、空心……）。
    public enum Alphabet: Sendable {
        case italic, upright, bold, boldItalic, blackboard, script
    }

    public static func styled(_ character: Character, _ alphabet: Alphabet) -> String {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return String(character)
        }
        let v = scalar.value
        let isUpper = (0x41...0x5A).contains(v)
        let isLower = (0x61...0x7A).contains(v)
        let isDigit = (0x30...0x39).contains(v)
        func code(_ value: UInt32) -> String {
            Unicode.Scalar(value).map { String(Character($0)) } ?? String(character)
        }
        switch alphabet {
        case .upright:
            return String(character)
        case .italic:
            if character == "h" { return "\u{210E}" }
            if isUpper { return code(0x1D434 + v - 0x41) }
            if isLower { return code(0x1D44E + v - 0x61) }
            return String(character)
        case .bold:
            if isUpper { return code(0x1D400 + v - 0x41) }
            if isLower { return code(0x1D41A + v - 0x61) }
            if isDigit { return code(0x1D7CE + v - 0x30) }
            return String(character)
        case .boldItalic:
            if isUpper { return code(0x1D468 + v - 0x41) }
            if isLower { return code(0x1D482 + v - 0x61) }
            if isDigit { return code(0x1D7CE + v - 0x30) }
            return String(character)
        case .blackboard:
            let special: [Character: UInt32] = ["C": 0x2102, "H": 0x210D, "N": 0x2115, "P": 0x2119,
                                                "Q": 0x211A, "R": 0x211D, "Z": 0x2124]
            if let s = special[character] { return code(s) }
            if isUpper { return code(0x1D538 + v - 0x41) }
            if isLower { return code(0x1D552 + v - 0x61) }
            if isDigit { return code(0x1D7D8 + v - 0x30) }
            return String(character)
        case .script:
            let special: [Character: UInt32] = ["B": 0x212C, "E": 0x2130, "F": 0x2131, "H": 0x210B, "I": 0x2110,
                                                "L": 0x2112, "M": 0x2133, "R": 0x211B,
                                                "e": 0x212F, "g": 0x210A, "o": 0x2134]
            if let s = special[character] { return code(s) }
            if isUpper { return code(0x1D49C + v - 0x41) }
            if isLower { return code(0x1D4B6 + v - 0x61) }
            return String(character)
        }
    }

    /// 小写希腊字母（数学斜体）与大写希腊字母（直立，同 TeX）。
    static let greek: [String: String] = {
        var table: [String: String] = [:]
        let lower: [(String, UInt32)] = [
            ("alpha", 0x1D6FC), ("beta", 0x1D6FD), ("gamma", 0x1D6FE), ("delta", 0x1D6FF), ("varepsilon", 0x1D700),
            ("zeta", 0x1D701), ("eta", 0x1D702), ("theta", 0x1D703), ("iota", 0x1D704), ("kappa", 0x1D705),
            ("lambda", 0x1D706), ("mu", 0x1D707), ("nu", 0x1D708), ("xi", 0x1D709), ("omicron", 0x1D70A),
            ("pi", 0x1D70B), ("rho", 0x1D70C), ("varsigma", 0x1D70D), ("sigma", 0x1D70E), ("tau", 0x1D70F),
            ("upsilon", 0x1D710), ("varphi", 0x1D711), ("chi", 0x1D712), ("psi", 0x1D713), ("omega", 0x1D714),
            ("epsilon", 0x1D716), ("vartheta", 0x1D717), ("varkappa", 0x1D718), ("phi", 0x1D719),
            ("varrho", 0x1D71A), ("varpi", 0x1D71B),
        ]
        for (name, value) in lower {
            if let scalar = Unicode.Scalar(value) { table[name] = String(Character(scalar)) }
        }
        let upper: [(String, String)] = [
            ("Gamma", "Γ"), ("Delta", "Δ"), ("Theta", "Θ"), ("Lambda", "Λ"), ("Xi", "Ξ"), ("Pi", "Π"),
            ("Sigma", "Σ"), ("Upsilon", "Υ"), ("Phi", "Φ"), ("Psi", "Ψ"), ("Omega", "Ω"),
        ]
        for (name, value) in upper { table[name] = value }
        return table
    }()

    static let binaries: [String: String] = [
        "pm": "±", "mp": "∓", "times": "×", "div": "÷", "cdot": "⋅", "ast": "∗", "star": "⋆", "circ": "∘",
        "bullet": "∙", "cup": "∪", "cap": "∩", "setminus": "∖", "wedge": "∧", "land": "∧", "vee": "∨", "lor": "∨",
        "oplus": "⊕", "otimes": "⊗", "odot": "⊙",
    ]

    static let relations: [String: String] = [
        "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "leqslant": "⩽", "geqslant": "⩾", "ne": "≠", "neq": "≠",
        "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝", "ll": "≪", "gg": "≫",
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "Leftrightarrow": "⇔", "leftrightarrow": "↔", "iff": "⟺", "implies": "⟹", "impliedby": "⟸",
        "mapsto": "↦", "longrightarrow": "⟶", "longleftarrow": "⟵", "Longrightarrow": "⟹",
        "perp": "⊥", "parallel": "∥", "mid": "∣", "uparrow": "↑", "downarrow": "↓", "nearrow": "↗",
        "searrow": "↘", "coloneqq": "≔", "doteq": "≐", "triangleq": "≜",
    ]

    static let ordinaries: [String: String] = [
        "infty": "∞", "partial": "\u{1D715}", "nabla": "∇", "forall": "∀", "exists": "∃", "emptyset": "∅",
        "varnothing": "∅", "angle": "∠", "triangle": "△", "ldots": "…", "dots": "…", "cdots": "⋯", "vdots": "⋮",
        "ddots": "⋱", "prime": "′", "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "neg": "¬",
        "lnot": "¬", "square": "□", "degree": "°", "vert": "|", "Vert": "‖", "|": "‖", "backslash": "∖",
        "#": "#", "%": "%", "&": "&", "$": "$", "_": "_", "therefore": "∴", "because": "∵", "top": "⊤", "bot": "⊥",
    ]

    static let delimiters: [String: (String, MathClass)] = [
        "{": ("{", .open), "}": ("}", .close), "lbrace": ("{", .open), "rbrace": ("}", .close),
        "langle": ("⟨", .open), "rangle": ("⟩", .close), "lfloor": ("⌊", .open), "rfloor": ("⌋", .close),
        "lceil": ("⌈", .open), "rceil": ("⌉", .close), "lvert": ("|", .open), "rvert": ("|", .close),
        "lVert": ("‖", .open), "rVert": ("‖", .close),
    ]

    /// 直立写、两边留算子空的函数名。
    static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "coth",
        "ln", "log", "lg", "exp", "det", "dim", "ker", "deg", "arg", "gcd", "hom", "sgn", "Pr",
    ]

    /// 行间时上下标写在正下方 / 正上方的函数名。
    static let limitFunctions: Set<String> = ["lim", "limsup", "liminf", "max", "min", "sup", "inf"]

    static let largeOperators: [String: (String, Bool)] = [
        "sum": ("∑", false), "prod": ("∏", false), "coprod": ("∐", false), "bigcup": ("⋃", false),
        "bigcap": ("⋂", false), "bigoplus": ("⨁", false), "bigotimes": ("⨂", false),
        "int": ("∫", true), "iint": ("∬", true), "iiint": ("∭", true), "oint": ("∮", true),
        "oiint": ("∯", true), "oiiint": ("∰", true),
    ]

    static let spaces: [String: Double] = [
        ",": 3.0 / 18, "thinspace": 3.0 / 18, ":": 4.0 / 18, ">": 4.0 / 18, "medspace": 4.0 / 18,
        ";": 5.0 / 18, "thickspace": 5.0 / 18, "!": -3.0 / 18, "negthinspace": -3.0 / 18,
        "quad": 1, "qquad": 2, " ": 0.3, "enspace": 0.5,
    ]

    static let accents: [String: MathAccent] = [
        "vec": .vec, "hat": .hat, "widehat": .hat, "tilde": .tilde, "widetilde": .tilde, "bar": .bar,
        "dot": .dot, "ddot": .ddot, "overline": .overline, "underline": .underline,
        "overrightarrow": .overrightarrow, "overleftarrow": .overleftarrow,
    ]

    static let bigSizes: [String: (Double, MathClass?)] = [
        "big": (1.2, nil), "Big": (1.8, nil), "bigg": (2.4, nil), "Bigg": (3.0, nil),
        "bigl": (1.2, .open), "Bigl": (1.8, .open), "biggl": (2.4, .open), "Biggl": (3.0, .open),
        "bigr": (1.2, .close), "Bigr": (1.8, .close), "biggr": (2.4, .close), "Biggr": (3.0, .close),
        "bigm": (1.2, .rel), "Bigm": (1.8, .rel),
    ]

    // MARK: - 解析器

    enum Terminator {
        case end, brace, bracket, right
    }

    struct Parser {
        let chars: [Character]
        var index = 0
        var alphabet: Alphabet = .italic
        /// `\right` 后面那个定界符（解析 `\left … \right` 时交回去）。
        var rightDelimiter = "."

        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool { index >= chars.count }
        var current: Character? { atEnd ? nil : chars[index] }

        mutating func skipSpaces() {
            while let c = current, c.isWhitespace { index += 1 }
        }

        /// `\` 后面的命令名：一串字母，或单个非字母字符（`\,` `\{`）。
        mutating func readCommandName() -> String {
            guard let first = current else { return "" }
            if first.isASCII, first.isLetter {
                var name = ""
                while let c = current, c.isASCII, c.isLetter {
                    name.append(c)
                    index += 1
                }
                return name
            }
            index += 1
            return String(first)
        }

        mutating func parseList(until terminator: Terminator) -> [MathNode] {
            var nodes: [MathNode] = []
            while true {
                skipSpaces()
                guard let c = current else { break }
                if c == "}" {
                    index += 1
                    if terminator == .brace { break }
                    continue  // 多出来的右括号：丢掉
                }
                if c == "]", terminator == .bracket {
                    index += 1
                    break
                }
                if c == "^" || c == "_" {
                    index += 1
                    let argument = parseArgument()
                    attachScript(argument, superscript: c == "^", to: &nodes)
                    continue
                }
                if c == "'" {
                    // 数学字体里的 ′ 本来就画在高处，直接跟在后面写，不再当上标抬一次。
                    var primes = ""
                    while current == "'" {
                        primes += "′"
                        index += 1
                    }
                    nodes.append(.symbol(primes, .ord))
                    continue
                }
                if c == "\\" {
                    let save = index
                    index += 1
                    let name = readCommandName()
                    if name == "right" {
                        rightDelimiter = readDelimiter()
                        if terminator == .right { break }
                        continue
                    }
                    if name == "limits" || name == "nolimits" || name == "displaylimits" {
                        setLimits(name == "limits" ? .always : name == "nolimits" ? .never : .displayOnly, on: &nodes)
                        continue
                    }
                    index = save
                }
                if let node = parseAtom() { nodes.append(node) }
            }
            return nodes
        }

        mutating func setLimits(_ limits: MathLimits, on nodes: inout [MathNode]) {
            guard let last = nodes.last, case .largeOperator(let symbol, let large, _, let integral) = last else { return }
            nodes[nodes.count - 1] = .largeOperator(symbol, large: large, limits: limits, integral: integral)
        }

        mutating func attachScript(_ argument: [MathNode], superscript: Bool, to nodes: inout [MathNode]) {
            let base = nodes.popLast() ?? .group([], .ord)
            if case .scripts(let inner, let sub, let sup) = base {
                if superscript, sup == nil {
                    nodes.append(.scripts(base: inner, sub: sub, sup: argument))
                    return
                }
                if !superscript, sub == nil {
                    nodes.append(.scripts(base: inner, sub: argument, sup: sup))
                    return
                }
            }
            nodes.append(superscript ? .scripts(base: base, sub: nil, sup: argument)
                                     : .scripts(base: base, sub: argument, sup: nil))
        }

        /// 命令的一个参数：`{…}`，或者单个记号（一个字符、一个命令）。
        mutating func parseArgument() -> [MathNode] {
            skipSpaces()
            guard let c = current else { return [] }
            if c == "{" {
                index += 1
                return parseList(until: .brace)
            }
            if c.isNumber {
                // `x^23` 在 TeX 里上标只有 2；照办。
                index += 1
                return [.symbol(String(c), .ord)]
            }
            return parseAtom().map { [$0] } ?? []
        }

        /// `\text{…}` 的原文：花括号里的字照抄（可以有空格、中文）。
        mutating func readRawArgument() -> String {
            skipSpaces()
            guard current == "{" else {
                guard let c = current else { return "" }
                index += 1
                return String(c)
            }
            index += 1
            var depth = 1
            var text = ""
            while let c = current {
                index += 1
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                if c == "\\", let next = current, "{}$%&#_ ".contains(next) {
                    text.append(next)
                    index += 1
                    continue
                }
                text.append(c)
            }
            return text
        }

        mutating func readOptionalBracket() -> [MathNode]? {
            skipSpaces()
            guard current == "[" else { return nil }
            index += 1
            return parseList(until: .bracket)
        }

        /// `\left` / `\right` / `\big` 后面跟的定界符。
        mutating func readDelimiter() -> String {
            skipSpaces()
            guard let c = current else { return "." }
            index += 1
            if c == "\\" {
                let name = readCommandName()
                if let (symbol, _) = MathTeX.delimiters[name] { return symbol }
                if name == "|" || name == "Vert" { return "‖" }
                if name == "vert" { return "|" }
                return "."
            }
            return String(c)
        }

        mutating func withAlphabet(_ alphabet: Alphabet, _ body: (inout Parser) -> [MathNode]) -> [MathNode] {
            let saved = self.alphabet
            self.alphabet = alphabet
            let result = body(&self)
            self.alphabet = saved
            return result
        }

        mutating func parseAtom() -> MathNode? {
            guard let c = current else { return nil }
            if c == "{" {
                index += 1
                return .group(parseList(until: .brace), .ord)
            }
            if c == "\\" {
                index += 1
                return command(readCommandName())
            }
            index += 1
            if c.isASCII, c.isLetter {
                return .symbol(MathTeX.styled(c, alphabet), .ord)
            }
            if c.isNumber, c.isASCII {
                var digits = alphabet == .bold || alphabet == .blackboard ? MathTeX.styled(c, alphabet) : String(c)
                while let next = current, next.isASCII, next.isNumber || next == "." {
                    // 小数点后面得是数字才算进来（"1." 结尾的点是句号）。
                    if next == ".", !(index + 1 < chars.count && chars[index + 1].isNumber) { break }
                    digits += alphabet == .bold || alphabet == .blackboard ? MathTeX.styled(next, alphabet) : String(next)
                    index += 1
                }
                return .symbol(digits, .ord)
            }
            switch c {
            case "+": return .symbol("+", .bin)
            case "-", "−": return .symbol("−", .bin)
            case "*": return .symbol("∗", .bin)
            case "=", "<", ">": return .symbol(String(c), .rel)
            case ":": return .symbol(":", .rel)
            case ",", ";": return .symbol(String(c), .punct)
            case "(", "[": return .symbol(String(c), .open)
            case ")", "]": return .symbol(String(c), .close)
            case "!", "?": return .symbol(String(c), .close)
            case "~": return .space(0.3)
            case "&": return .space(1)
            default:
                break
            }
            if c.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) {
                // 中文之类：连成一段，用正文字体写。
                var text = String(c)
                while let next = current, next.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) {
                    text.append(next)
                    index += 1
                }
                return .text(text)
            }
            if let greek = c.unicodeScalars.first, (0x3B1...0x3C9).contains(greek.value), alphabet == .italic {
                // 直接打的希腊字母也换成斜体。
                return .symbol(MathTeX.styled(c, .upright).italicGreek, .ord)
            }
            return .symbol(String(c), .ord)
        }

        mutating func command(_ name: String) -> MathNode? {
            if let value = MathTeX.greek[name] {
                if alphabet == .upright, name.first?.isLowercase == true {
                    return .symbol(value.uprightGreek, .ord)
                }
                return .symbol(value, .ord)
            }
            if let value = MathTeX.binaries[name] { return .symbol(value, .bin) }
            if let value = MathTeX.relations[name] { return .symbol(value, .rel) }
            if let value = MathTeX.ordinaries[name] { return .symbol(value, .ord) }
            if let (value, kind) = MathTeX.delimiters[name] { return .symbol(value, kind) }
            if let width = MathTeX.spaces[name] { return .space(width) }
            if MathTeX.functions.contains(name) { return .symbol(name, .op) }
            if MathTeX.limitFunctions.contains(name) {
                let display = name == "limsup" ? "lim sup" : name == "liminf" ? "lim inf" : name
                return .largeOperator(display, large: false, limits: .displayOnly, integral: false)
            }
            if let (symbol, integral) = MathTeX.largeOperators[name] {
                return .largeOperator(symbol, large: true, limits: integral ? .never : .displayOnly, integral: integral)
            }
            if let accent = MathTeX.accents[name] {
                return .accent(accent, parseArgument())
            }
            if let (size, kind) = MathTeX.bigSizes[name] {
                let symbol = readDelimiter()
                let resolved = kind ?? (["(", "[", "{", "⟨", "⌊", "⌈"].contains(symbol) ? .open : .close)
                return .bigDelimiter(symbol, resolved, size: size)
            }
            switch name {
            case "frac", "dfrac", "tfrac", "cfrac":
                let numerator = parseArgument()
                let denominator = parseArgument()
                let style: MathFractionStyle = name == "dfrac" || name == "cfrac" ? .display : name == "tfrac" ? .text : .auto
                return .fraction(numerator, denominator, style: style, rule: true)
            case "binom", "dbinom", "tbinom":
                let top = parseArgument()
                let bottom = parseArgument()
                let style: MathFractionStyle = name == "dbinom" ? .display : name == "tbinom" ? .text : .auto
                return .delimited(left: "(", body: [.fraction(top, bottom, style: style, rule: false)], right: ")")
            case "sqrt":
                let degree = readOptionalBracket()
                return .radical(index: degree, body: parseArgument())
            case "left":
                let left = readDelimiter()
                let body = parseList(until: .right)
                let right = rightDelimiter
                rightDelimiter = "."
                return .delimited(left: left, body: body, right: right)
            case "middle":
                return .symbol(readDelimiter(), .rel)
            case "mathrm", "mathup", "operatorname", "mathsf", "mathtt", "mathfrak":
                let body = withAlphabet(.upright) { $0.parseArgument() }
                return .group(body, name == "operatorname" ? .op : .ord)
            case "mathit":
                return .group(withAlphabet(.italic) { $0.parseArgument() }, .ord)
            case "mathbf", "textbf":
                if name == "textbf" { return .text(readRawArgument()) }
                return .group(withAlphabet(.bold) { $0.parseArgument() }, .ord)
            case "boldsymbol", "bm", "pmb":
                return .group(withAlphabet(.boldItalic) { $0.parseArgument() }, .ord)
            case "mathbb":
                return .group(withAlphabet(.blackboard) { $0.parseArgument() }, .ord)
            case "mathcal", "mathscr":
                return .group(withAlphabet(.script) { $0.parseArgument() }, .ord)
            case "text", "textrm", "mbox", "textit", "textnormal", "hbox":
                return .text(readRawArgument())
            case "mathop": return .group(parseArgument(), .op)
            case "mathbin": return .group(parseArgument(), .bin)
            case "mathrel": return .group(parseArgument(), .rel)
            case "mathord": return .group(parseArgument(), .ord)
            case "mathopen": return .group(parseArgument(), .open)
            case "mathclose": return .group(parseArgument(), .close)
            case "displaystyle": return .style(.display)
            case "textstyle": return .style(.text)
            case "scriptstyle": return .style(.script)
            case "not":
                // `\not=` → ≠，其它的叠一道斜线太复杂，直接写原符号。
                skipSpaces()
                if current == "=" {
                    index += 1
                    return .symbol("≠", .rel)
                }
                return parseAtom()
            case "\\", "newline", "cr":
                return .space(1)
            case "hspace", "hspace*":
                _ = readRawArgument()
                return .space(0.5)
            case "color", "textcolor":
                // 不支持颜色：跳过颜色名，内容照常排。
                _ = readRawArgument()
                return name == "textcolor" ? .group(parseArgument(), .ord) : nil
            case "phantom":
                _ = parseArgument()
                return .space(0.5)
            case "":
                return nil
            default:
                return .symbol("\\" + name, .ord)
            }
        }
    }
}

private extension String {
    /// α…ω 换成数学斜体。
    var italicGreek: String {
        guard let scalar = unicodeScalars.first, (0x3B1...0x3C9).contains(scalar.value) else { return self }
        let names = ["alpha", "beta", "gamma", "delta", "varepsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda",
                     "mu", "nu", "xi", "omicron", "pi", "rho", "varsigma", "sigma", "tau", "upsilon", "varphi", "chi",
                     "psi", "omega"]
        let offset = Int(scalar.value - 0x3B1)
        guard offset < names.count else { return self }
        return MathTeX.greek[names[offset]] ?? self
    }

    /// 数学斜体希腊字母换回直立的（`\mathrm{\pi}`）。
    var uprightGreek: String {
        guard let scalar = unicodeScalars.first, (0x1D6FC...0x1D714).contains(scalar.value),
              let upright = Unicode.Scalar(0x3B1 + scalar.value - 0x1D6FC) else { return self }
        return String(Character(upright))
    }
}

// MARK: - 讲解文字

/// 讲解文字的一段：正文里夹着行内公式，或者单独一行的行间公式。
public enum LessonParagraph: Sendable, Equatable {
    case inline([LessonRun])
    case display(String)
}

public enum LessonRun: Sendable, Equatable {
    case text(String, bold: Bool)
    case math(String)
}

public enum LessonText {

    /// 拆段：`$$…$$`（或 `\[…\]`）单独成段；其余按行分段，行内的 `$…$`（或 `\(…\)`）是公式，`**…**` 加粗，
    /// `\$` 是美元符号本身。空行留成一个空段（排版时是一段空隙）。没配对的 `$` 当普通字。
    public static func paragraphs(_ text: String) -> [LessonParagraph] {
        var result: [LessonParagraph] = []
        var runs: [LessonRun] = []
        var buffer = ""
        var bold = false
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        var i = 0

        func flushText() {
            guard !buffer.isEmpty else { return }
            runs.append(.text(buffer, bold: bold))
            buffer = ""
        }
        func flushParagraph() {
            flushText()
            result.append(.inline(runs))
            runs = []
        }
        func find(_ closing: [Character], from start: Int) -> Int? {
            var j = start
            while j + closing.count <= chars.count {
                if chars[j] == "\\", closing != ["\\", ")"], closing != ["\\", "]"] {
                    j += 2
                    continue
                }
                if Array(chars[j..<(j + closing.count)]) == closing { return j }
                j += 1
            }
            return nil
        }

        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "\\", next == "$" {
                buffer.append("$")
                i += 2
                continue
            }
            if (c == "$" && next == "$") || (c == "\\" && next == "[") {
                let closing: [Character] = c == "$" ? ["$", "$"] : ["\\", "]"]
                if let end = find(closing, from: i + 2) {
                    let math = String(chars[(i + 2)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    // 行间公式前面这一行有字就先结束它；公式后面紧跟的换行也吃掉。
                    if !buffer.isEmpty || !runs.isEmpty { flushParagraph() }
                    result.append(.display(math))
                    i = end + 2
                    // 公式后面紧跟的空格和一个换行一起吃掉：下一段不以空格开头。
                    while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
                    if i < chars.count, chars[i] == "\n" { i += 1 }
                    continue
                }
            }
            if c == "$" || (c == "\\" && next == "(") {
                let start = c == "$" ? i + 1 : i + 2
                let closing: [Character] = c == "$" ? ["$"] : ["\\", ")"]
                if let end = find(closing, from: start), end > start {
                    flushText()
                    runs.append(.math(String(chars[start..<end])))
                    i = end + closing.count
                    continue
                }
            }
            if c == "*", next == "*" {
                flushText()
                bold.toggle()
                i += 2
                continue
            }
            if c == "\n" {
                flushParagraph()
                i += 1
                continue
            }
            buffer.append(c)
            i += 1
        }
        if !buffer.isEmpty || !runs.isEmpty { flushParagraph() }
        return result
    }
}
