import CoreGraphics
import CoreText
import Foundation
import GrapherKit

/// 排好的一块公式：宽、基线以上的高度、基线以下的深度，以及画法（摊平成相对「基线左端」的图元，y 向上）。
public struct MathBox {
    public internal(set) var width: CGFloat
    public internal(set) var ascent: CGFloat
    public internal(set) var descent: CGFloat
    /// 斜体字母右上角伸出前进宽度的那一点：上标要往右让开它。
    var italicCorrection: CGFloat = 0
    var items: [MathItem] = []

    init(width: CGFloat = 0, ascent: CGFloat = 0, descent: CGFloat = 0, items: [MathItem] = []) {
        self.width = width
        self.ascent = ascent
        self.descent = descent
        self.items = items
    }

    public static let empty = MathBox()

    /// 把 `box` 摆到 (dx, dy)（相对本盒基线左端，y 向上），图元并进来；尺寸不自动变。
    mutating func place(_ box: MathBox, dx: CGFloat, dy: CGFloat) {
        let transform = CGAffineTransform(translationX: dx, y: dy)
        for item in box.items {
            switch item {
            case .line(let line, let origin):
                items.append(.line(line, CGPoint(x: origin.x + dx, y: origin.y + dy)))
            case .rule(let rect):
                items.append(.rule(rect.applying(transform)))
            case .stroke(let path, let width):
                var t = transform
                items.append(.stroke(path.copy(using: &t) ?? path, width))
            case .fill(let path):
                var t = transform
                items.append(.fill(path.copy(using: &t) ?? path))
            }
        }
    }

    /// 整块上下挪 `dy`（正数往上）。
    func shifted(by dy: CGFloat) -> MathBox {
        var box = MathBox(width: width, ascent: ascent + dy, descent: descent - dy)
        box.italicCorrection = italicCorrection
        box.place(self, dx: 0, dy: dy)
        return box
    }

    /// 在 `context` 里画：`origin` 是基线左端；上下文 y 向上（Core Graphics 默认）。
    public func draw(in context: CGContext, at origin: CGPoint, color: CGColor) {
        context.saveGState()
        context.setFillColor(color)
        context.setStrokeColor(color)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.textMatrix = .identity
        for item in items {
            switch item {
            case .line(let line, let point):
                context.textPosition = CGPoint(x: origin.x + point.x, y: origin.y + point.y)
                CTLineDraw(line, context)
            case .rule(let rect):
                context.fill(rect.offsetBy(dx: origin.x, dy: origin.y))
            case .stroke(let path, let width):
                context.saveGState()
                context.translateBy(x: origin.x, y: origin.y)
                context.setLineWidth(width)
                context.addPath(path)
                context.strokePath()
                context.restoreGState()
            case .fill(let path):
                context.saveGState()
                context.translateBy(x: origin.x, y: origin.y)
                context.addPath(path)
                context.fillPath()
                context.restoreGState()
            }
        }
        context.restoreGState()
    }
}

enum MathItem {
    /// 一串字，`CGPoint` 是它的基线原点。颜色取上下文的填充色。
    case line(CTLine, CGPoint)
    case rule(CGRect)
    case stroke(CGPath, CGFloat)
    case fill(CGPath)
}

/// 把 TeX 公式（`MathTeX` 解析出的语法树）排成 `MathBox`。规则照 TeX 的思路简化：原子按类别留空、上下标按
/// 几个最小升降量摆、分数线和根号线粗细取字号的 6.6%；可伸缩的括号、根号自己画路径。字体是系统自带的
/// STIX Two Math（数学字母、符号都在里面），中文与 `\text{}` 用系统正文字体。
public enum MathTypesetter {

    /// 排一段 TeX。`display` 为真是行间公式（`$$…$$`）：分数、积分号更大。
    public static func layout(_ tex: String, fontSize: CGFloat, display: Bool) -> MathBox {
        layout(MathTeX.parse(tex), fontSize: fontSize, display: display)
    }

    public static func layout(_ nodes: [MathNode], fontSize: CGFloat, display: Bool) -> MathBox {
        let engine = Engine(baseSize: fontSize)
        return engine.list(nodes, Style(level: display ? .display : .text, cramped: false))
    }

    // MARK: - 字体

    static let mathFontName = "STIXTwoMath-Regular"

    /// 数学字体；没有 STIX Two Math 的系统退回 Times。
    static func mathFont(size: CGFloat) -> CTFont {
        let font = CTFontCreateWithName(mathFontName as CFString, size, nil)
        if (CTFontCopyPostScriptName(font) as String) == mathFontName { return font }
        return CTFontCreateWithName("TimesNewRomanPSMT" as CFString, size, nil)
    }

    static func textFont(size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    // MARK: - 样式

    enum Level: Int, Comparable {
        case display, text, script, scriptScript
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    struct Style {
        var level: Level
        var cramped: Bool

        var isScript: Bool { level >= .script }
        var sup: Style {
            switch level {
            case .display, .text: return Style(level: .script, cramped: cramped)
            case .script, .scriptScript: return Style(level: .scriptScript, cramped: cramped)
            }
        }
        var sub: Style { Style(level: sup.level, cramped: true) }
        /// 分数线上下（分子、分母）的样式。
        var fractionPart: Style {
            switch level {
            case .display: return Style(level: .text, cramped: cramped)
            case .text: return Style(level: .script, cramped: cramped)
            case .script, .scriptScript: return Style(level: .scriptScript, cramped: cramped)
            }
        }
        var crampedCopy: Style { Style(level: level, cramped: true) }
    }

    // MARK: - 排版

    final class Engine {
        let baseSize: CGFloat
        private var fonts: [CGFloat: CTFont] = [:]
        private var textFonts: [CGFloat: CTFont] = [:]

        init(baseSize: CGFloat) { self.baseSize = baseSize }

        func size(_ style: Style) -> CGFloat {
            switch style.level {
            case .display, .text: return baseSize
            case .script: return baseSize * 0.7
            case .scriptScript: return baseSize * 0.5
            }
        }

        func font(_ size: CGFloat) -> CTFont {
            if let font = fonts[size] { return font }
            let font = MathTypesetter.mathFont(size: size)
            fonts[size] = font
            return font
        }

        func textFont(_ size: CGFloat) -> CTFont {
            if let font = textFonts[size] { return font }
            let font = MathTypesetter.textFont(size: size)
            textFonts[size] = font
            return font
        }

        /// 一串字的盒子：宽是前进宽度，高 / 深取字形的墨迹（排上下标、根号要的是看得见的高度）。
        func glyphs(_ string: String, font: CTFont) -> MathBox {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            guard !ink.isNull, !ink.isEmpty else { return MathBox(width: width, items: [.line(line, .zero)]) }
            var box = MathBox(width: width, ascent: max(ink.maxY, 0), descent: max(-ink.minY, 0))
            box.items = [.line(line, .zero)]
            if ink.maxX > width { box.italicCorrection = ink.maxX - width }
            return box
        }

        func space(_ width: CGFloat) -> MathBox { MathBox(width: width) }

        // MARK: 横排

        func list(_ nodes: [MathNode], _ start: Style) -> MathBox {
            var style = start
            var atoms: [(box: MathBox, kind: MathClass?)] = []
            for node in nodes {
                if case .style(let change) = node {
                    switch change {
                    case .display: style = Style(level: .display, cramped: style.cramped)
                    case .text: style = Style(level: .text, cramped: style.cramped)
                    case .script: style = Style(level: .script, cramped: style.cramped)
                    }
                    continue
                }
                if case .space(let em) = node {
                    atoms.append((space(CGFloat(em) * size(style)), nil))
                    continue
                }
                let (box, kind) = atom(node, style)
                atoms.append((box, kind))
            }

            // 二元运算符出现在开头、运算符 / 关系 / 左括号 / 标点之后，或紧接着关系 / 右括号 / 标点时，当普通符号（一元负号）。
            var previous: Int?
            for index in atoms.indices {
                guard let kind = atoms[index].kind else { continue }
                if kind == .bin {
                    let before = previous.flatMap { atoms[$0].kind }
                    if let before, ![.bin, .op, .rel, .open, .punct].contains(before) {
                        // 前面是普通符号：真的二元运算符，两边留空。
                    } else {
                        atoms[index].kind = .ord
                    }
                }
                if [.rel, .close, .punct].contains(kind), let previous, atoms[previous].kind == .bin {
                    atoms[previous].kind = .ord
                }
                previous = index
            }
            if let previous, atoms[previous].kind == .bin { atoms[previous].kind = .ord }

            var result = MathBox()
            let mu = size(style) / 18
            var lastKind: MathClass?
            for entry in atoms {
                if let kind = entry.kind {
                    if let lastKind {
                        result.width += CGFloat(Engine.spacing(lastKind, kind, script: style.isScript)) * mu
                    }
                    lastKind = kind
                }
                result.place(entry.box, dx: result.width, dy: 0)
                result.width += entry.box.width
                result.ascent = max(result.ascent, entry.box.ascent)
                result.descent = max(result.descent, entry.box.descent)
            }
            if atoms.count == 1 { result.italicCorrection = atoms[0].box.italicCorrection }
            return result
        }

        /// TeX 的原子间距表：1 细空、2 中空、3 粗空（3 / 4 / 5 mu，mu = 1/18 em）；负数表示上下标里不留。
        private static let spacingTable: [[Int]] = [
            //  ord  op  bin  rel open close punct inner
            [0, 1, -2, -3, 0, 0, 0, -1],        // ord
            [1, 1, 0, -3, 0, 0, 0, -1],         // op
            [-2, -2, 0, 0, -2, 0, 0, -2],       // bin
            [-3, -3, 0, 0, -3, 0, 0, -3],       // rel
            [0, 0, 0, 0, 0, 0, 0, 0],           // open
            [0, 1, -2, -3, 0, 0, 0, -1],        // close
            [-1, -1, 0, -1, -1, -1, -1, -1],    // punct
            [-1, 1, -2, -3, -1, 0, -1, -1],     // inner
        ]

        private static func row(_ kind: MathClass) -> Int {
            switch kind {
            case .ord: return 0
            case .op: return 1
            case .bin: return 2
            case .rel: return 3
            case .open: return 4
            case .close: return 5
            case .punct: return 6
            case .inner: return 7
            }
        }

        /// 两个原子之间留多少 mu。
        static func spacing(_ left: MathClass, _ right: MathClass, script: Bool) -> Int {
            let code = spacingTable[row(left)][row(right)]
            if code < 0, script { return 0 }
            return [0, 3, 4, 5][abs(code)]
        }

        // MARK: 原子

        func atom(_ node: MathNode, _ style: Style) -> (MathBox, MathClass) {
            switch node {
            case .symbol(let string, let kind):
                return (glyphs(string, font: font(size(style))), kind)
            case .text(let string):
                return (glyphs(string, font: textFont(size(style))), .ord)
            case .largeOperator(let symbol, let large, _, let integral):
                return (largeOperator(symbol, large: large, integral: integral, style), .op)
            case .group(let nodes, let kind):
                return (list(nodes, style), kind)
            case .scripts(let base, let sub, let sup):
                return scripts(base: base, sub: sub, sup: sup, style)
            case .fraction(let numerator, let denominator, let fractionStyle, let rule):
                return (fraction(numerator, denominator, fractionStyle, rule: rule, style), .inner)
            case .radical(let index, let body):
                return (radical(index: index, body: body, style), .ord)
            case .accent(let accent, let body):
                return (self.accent(accent, body, style), .ord)
            case .delimited(let left, let body, let right):
                return (delimited(left: left, body: body, right: right, style), .inner)
            case .bigDelimiter(let symbol, let kind, let height):
                return (delimiter(symbol, height: CGFloat(height) * size(style), style: style, forceDrawn: true), kind)
            case .space(let em):
                return (space(CGFloat(em) * size(style)), .ord)
            case .style:
                return (.empty, .ord)
            }
        }

        func axis(_ style: Style) -> CGFloat { size(style) * 0.258 }
        func rule(_ style: Style) -> CGFloat { max(size(style) * 0.066, 0.5) }

        /// 积分号、求和号：行间放大，竖直方向对准数学轴（减号的高度）居中。
        func largeOperator(_ symbol: String, large: Bool, integral: Bool, _ style: Style) -> MathBox {
            let isWord = symbol.unicodeScalars.allSatisfy { $0.isASCII }
            if isWord { return glyphs(symbol, font: font(size(style))) }
            var factor: CGFloat = 1
            if large, style.level == .display { factor = integral ? 1.75 : 1.45 }
            if large, style.level == .text, !integral { factor = 1.05 }
            var box = glyphs(symbol, font: font(size(style) * factor))
            let center = (box.ascent - box.descent) / 2
            box = box.shifted(by: axis(style) - center)
            return box
        }

        // MARK: 上下标

        func scripts(base: MathNode, sub: [MathNode]?, sup: [MathNode]?, _ style: Style) -> (MathBox, MathClass) {
            let (baseBox, kind) = atom(base, style)
            let em = size(style)
            if case .largeOperator(_, _, let limits, _) = base,
               limits == .always || (limits == .displayOnly && style.level == .display) {
                return (limitsLayout(baseBox, sub: sub, sup: sup, style), kind)
            }
            let isCharacter: Bool
            switch base {
            case .symbol, .text: isCharacter = true
            default: isCharacter = false
            }
            let integral: Bool
            if case .largeOperator(_, _, _, true) = base { integral = true } else { integral = false }

            let supBox = sup.map { list($0, style.sup) }
            let subBox = sub.map { list($0, style.sub) }
            let scriptEm = size(style.sup)
            var u: CGFloat = isCharacter ? 0 : baseBox.ascent - scriptEm * 0.386
            var v: CGFloat = isCharacter ? 0 : baseBox.descent + scriptEm * 0.05

            var result = MathBox()
            result.place(baseBox, dx: 0, dy: 0)
            result.ascent = baseBox.ascent
            result.descent = baseBox.descent
            var width = baseBox.width
            let scriptSpace = em * 0.05

            if let supBox {
                let minimum: CGFloat = style.level == .display ? 0.413 : (style.cramped ? 0.289 : 0.363)
                u = max(u, em * minimum, supBox.descent + em * 0.11)
            }
            if let subBox {
                v = max(v, em * (supBox == nil ? 0.15 : 0.247), subBox.ascent - em * 0.36)
            }
            if let supBox, let subBox {
                // 上下标之间至少留 4 倍线宽。
                let gap = (u - supBox.descent) - (subBox.ascent - v)
                let need = 4 * rule(style)
                if gap < need {
                    v += need - gap
                }
            }
            let italic = baseBox.italicCorrection
            if let supBox {
                let x = baseBox.width + italic
                result.place(supBox, dx: x, dy: u)
                result.ascent = max(result.ascent, u + supBox.ascent)
                result.descent = max(result.descent, supBox.descent - u)
                width = max(width, x + supBox.width)
            }
            if let subBox {
                // 积分号是斜的：下标往左收一点，贴着积分号的下端。
                let x = baseBox.width - (integral ? max(italic, em * 0.18) : 0)
                result.place(subBox, dx: x, dy: -v)
                result.ascent = max(result.ascent, subBox.ascent - v)
                result.descent = max(result.descent, v + subBox.descent)
                width = max(width, x + subBox.width)
            }
            result.width = width + scriptSpace
            return (result, kind)
        }

        /// 行间的 ∑、lim：上下标写在正上方、正下方。
        func limitsLayout(_ base: MathBox, sub: [MathNode]?, sup: [MathNode]?, _ style: Style) -> MathBox {
            let em = size(style)
            let supBox = sup.map { list($0, style.sup) }
            let subBox = sub.map { list($0, style.sub) }
            let width = max(base.width, supBox?.width ?? 0, subBox?.width ?? 0)
            var result = MathBox(width: width, ascent: base.ascent, descent: base.descent)
            result.place(base, dx: (width - base.width) / 2, dy: 0)
            if let supBox {
                let y = base.ascent + em * 0.12 + supBox.descent
                result.place(supBox, dx: (width - supBox.width) / 2, dy: y)
                result.ascent = y + supBox.ascent
            }
            if let subBox {
                let y = base.descent + em * 0.1 + subBox.ascent
                result.place(subBox, dx: (width - subBox.width) / 2, dy: -y)
                result.descent = y + subBox.descent
            }
            return result
        }

        // MARK: 分数

        func fraction(_ numerator: [MathNode], _ denominator: [MathNode], _ kind: MathFractionStyle, rule hasRule: Bool,
                      _ style: Style) -> MathBox {
            var outer = style
            switch kind {
            case .auto: break
            case .display: outer = Style(level: .display, cramped: style.cramped)
            case .text: outer = Style(level: style.level == .display ? .text : style.level, cramped: style.cramped)
            }
            let numBox = list(numerator, outer.fractionPart)
            let denBox = list(denominator, Style(level: outer.fractionPart.level, cramped: true))
            let em = size(outer)
            let theta = hasRule ? rule(outer) : 0
            let a = axis(outer)
            let display = outer.level == .display
            var u = em * (display ? 0.677 : (hasRule ? 0.394 : 0.444))
            var v = em * (display ? 0.686 : 0.345)
            if hasRule {
                let clearance = display ? 3 * rule(outer) : rule(outer)
                u = max(u, a + theta / 2 + clearance + numBox.descent)
                v = max(v, denBox.ascent + clearance - a + theta / 2)
            } else {
                let clearance = display ? 7 * rule(outer) : 3 * rule(outer)
                let gap = (u - numBox.descent) - (denBox.ascent - v)
                if gap < clearance {
                    u += (clearance - gap) / 2
                    v += (clearance - gap) / 2
                }
            }
            let pad = em * 0.12
            let inner = max(numBox.width, denBox.width)
            var box = MathBox(width: inner + 2 * pad, ascent: u + numBox.ascent, descent: v + denBox.descent)
            box.place(numBox, dx: pad + (inner - numBox.width) / 2, dy: u)
            box.place(denBox, dx: pad + (inner - denBox.width) / 2, dy: -v)
            if hasRule {
                box.items.append(.rule(CGRect(x: pad * 0.6, y: a - theta / 2, width: inner + pad * 0.8, height: theta)))
            }
            return box
        }

        // MARK: 根号

        func radical(index: [MathNode]?, body: [MathNode], _ style: Style) -> MathBox {
            let bodyBox = list(body, style.crampedCopy)
            let em = size(style)
            let theta = rule(style)
            let clearance = style.level == .display ? theta + em * 0.11 : theta * 1.25 + em * 0.03
            // 内容至少按一个小写字母的高度算，`\sqrt{x}` 与 `\sqrt{2}` 的根号不至于太矮。
            let bodyAscent = max(bodyBox.ascent, em * 0.46)
            let top = bodyAscent + clearance + theta
            let bottom = -max(bodyBox.descent, 0) - em * 0.08
            let height = top - bottom
            let signWidth = min(em * 0.56 + max(height - em * 1.2, 0) * 0.12, em * 1.0)

            // 根指数（`\sqrt[3]{x}`）比根号的小钩宽时，整个根号往右让。
            var indexShift: CGFloat = 0
            var indexBox: MathBox?
            if let index {
                let made = list(index, Style(level: .scriptScript, cramped: false))
                indexShift = max(made.width - signWidth * 0.55, 0)
                indexBox = made
            }

            // 根号三笔：左边的小钩（细）、往下的一笔（粗）、往上到横线的一笔（细）。
            var box = MathBox()
            let x0 = indexShift
            let hookY = bottom + height * 0.42
            let hookTop = CGPoint(x: x0 + signWidth * 0.2, y: hookY + em * 0.07)
            let lowest = CGPoint(x: x0 + signWidth * 0.46, y: bottom)
            let hook = CGMutablePath()
            hook.move(to: CGPoint(x: x0, y: hookY))
            hook.addLine(to: hookTop)
            let down = CGMutablePath()
            down.move(to: hookTop)
            down.addLine(to: lowest)
            let up = CGMutablePath()
            up.move(to: lowest)
            up.addLine(to: CGPoint(x: x0 + signWidth, y: top - theta / 2))
            box.items.append(.stroke(hook, theta * 0.9))
            box.items.append(.stroke(down, theta * 2.1))
            box.items.append(.stroke(up, theta))
            let bodyX = indexShift + signWidth + em * 0.05
            box.items.append(.rule(CGRect(x: indexShift + signWidth - theta * 0.3, y: top - theta,
                                          width: bodyBox.width + em * 0.1 + theta * 0.3, height: theta)))
            box.place(bodyBox, dx: bodyX, dy: 0)
            if let indexBox {
                let y = bottom + height * 0.62 + indexBox.descent
                box.place(indexBox, dx: indexShift + signWidth * 0.55 - indexBox.width, dy: y)
            }
            box.width = bodyX + bodyBox.width + em * 0.1
            box.ascent = max(top, bodyBox.ascent)
            box.descent = max(-bottom, bodyBox.descent)
            return box
        }

        // MARK: 重音

        func accent(_ kind: MathAccent, _ body: [MathNode], _ style: Style) -> MathBox {
            let bodyBox = list(body, style.crampedCopy)
            let em = size(style)
            let theta = rule(style)
            // 单个斜体字母：重音往右挪一点，对准斜着的字母中间。
            let isSingleLetter: Bool = {
                guard body.count == 1, case .symbol(let s, _) = body[0] else { return false }
                return s.count == 1
            }()
            let skew = isSingleLetter ? em * 0.06 : 0
            let mid = bodyBox.width / 2 + skew
            let base = max(bodyBox.ascent, em * 0.46) + em * 0.06
            var box = MathBox(width: bodyBox.width, ascent: bodyBox.ascent, descent: bodyBox.descent)
            box.place(bodyBox, dx: 0, dy: 0)
            switch kind {
            case .vec, .overrightarrow, .overleftarrow:
                let length = kind == .vec && isSingleLetter ? max(bodyBox.width * 0.95, em * 0.42) : max(bodyBox.width, em * 0.42)
                let y = base + em * 0.1
                let x0 = kind == .vec ? mid - length / 2 : (bodyBox.width - length) / 2
                let x1 = x0 + length
                let path = CGMutablePath()
                path.move(to: CGPoint(x: x0, y: y))
                path.addLine(to: CGPoint(x: x1, y: y))
                let head = em * 0.13
                let tip = kind == .overleftarrow ? x0 : x1
                let back = kind == .overleftarrow ? head : -head
                path.move(to: CGPoint(x: tip + back, y: y + head * 0.6))
                path.addLine(to: CGPoint(x: tip, y: y))
                path.addLine(to: CGPoint(x: tip + back, y: y - head * 0.6))
                box.items.append(.stroke(path, theta))
                box.ascent = max(box.ascent, y + head * 0.6 + theta)
                box.width = max(box.width, x1 + theta)
            case .hat:
                let width = max(min(bodyBox.width, em * 1.2), em * 0.32)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: mid - width / 2, y: base + em * 0.03))
                path.addLine(to: CGPoint(x: mid, y: base + em * 0.17))
                path.addLine(to: CGPoint(x: mid + width / 2, y: base + em * 0.03))
                box.items.append(.stroke(path, theta * 0.9))
                box.ascent = max(box.ascent, base + em * 0.17 + theta)
            case .tilde:
                let width = max(min(bodyBox.width, em * 1.2), em * 0.36)
                let y = base + em * 0.09
                let path = CGMutablePath()
                path.move(to: CGPoint(x: mid - width / 2, y: y - em * 0.02))
                path.addCurve(to: CGPoint(x: mid + width / 2, y: y + em * 0.02),
                              control1: CGPoint(x: mid - width / 6, y: y + em * 0.12),
                              control2: CGPoint(x: mid + width / 6, y: y - em * 0.12))
                box.items.append(.stroke(path, theta * 0.9))
                box.ascent = max(box.ascent, y + em * 0.1)
            case .bar, .overline:
                let width = kind == .bar && isSingleLetter ? max(bodyBox.width * 0.9, em * 0.36) : bodyBox.width
                let x = kind == .bar && isSingleLetter ? mid - width / 2 : 0
                let y = base + em * 0.05
                box.items.append(.rule(CGRect(x: x, y: y, width: width, height: theta)))
                box.ascent = max(box.ascent, y + theta)
            case .underline:
                let y = -bodyBox.descent - em * 0.1
                box.items.append(.rule(CGRect(x: 0, y: y - theta, width: bodyBox.width, height: theta)))
                box.descent = max(box.descent, -y + theta)
            case .dot, .ddot:
                let r = em * 0.048
                let y = base + em * 0.08
                let path = CGMutablePath()
                let xs = kind == .dot ? [mid] : [mid - em * 0.11, mid + em * 0.11]
                for x in xs { path.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
                box.items.append(.fill(path))
                box.ascent = max(box.ascent, y + r)
            }
            return box
        }

        // MARK: 定界符

        func delimited(left: String, body: [MathNode], right: String, _ style: Style) -> MathBox {
            let bodyBox = list(body, style)
            let a = axis(style)
            let half = max(bodyBox.ascent - a, bodyBox.descent + a)
            let em = size(style)
            let height = max(2 * half * 0.901, 2 * half - em * 0.5)
            let leftBox = delimiter(left, height: height, style: style, forceDrawn: false)
            let rightBox = delimiter(right, height: height, style: style, forceDrawn: false)
            var box = MathBox()
            for part in [leftBox, bodyBox, rightBox] {
                box.place(part, dx: box.width, dy: 0)
                box.width += part.width
                box.ascent = max(box.ascent, part.ascent)
                box.descent = max(box.descent, part.descent)
            }
            return box
        }

        /// 高 `height`、对准数学轴居中的定界符。不太高时直接用字体里的字形（行内的小括号就是普通括号）。
        func delimiter(_ symbol: String, height: CGFloat, style: Style, forceDrawn: Bool) -> MathBox {
            let em = size(style)
            if symbol == "." || symbol.isEmpty { return space(em * 0.12) }
            if !forceDrawn, height <= em * 1.18 {
                return glyphs(symbol, font: font(em))
            }
            let a = axis(style)
            let top = a + height / 2
            let bottom = a - height / 2
            let stroke = em * 0.055 + height * 0.008
            var box = MathBox(ascent: top, descent: -bottom)
            let path = CGMutablePath()
            func mirrored(_ build: (CGMutablePath, CGFloat) -> CGFloat) {
                // 先按左边那只画，右边那只水平翻过来。
                let shape = CGMutablePath()
                let width = build(shape, stroke)
                let isRight = [")", "]", "}", "⟩", "⌋", "⌉"].contains(symbol)
                if isRight {
                    path.addPath(shape, transform: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0))
                } else {
                    path.addPath(shape)
                }
                box.width = width
            }
            switch symbol {
            case "(", ")":
                mirrored { shape, stroke in
                    let width = min(em * 0.32 + height * 0.06, em * 0.7)
                    let xr = width - em * 0.06
                    let xl = em * 0.1
                    let thick = stroke * 1.5
                    let reach = height * 0.24
                    shape.move(to: CGPoint(x: xr, y: top))
                    shape.addCurve(to: CGPoint(x: xr, y: bottom), control1: CGPoint(x: xl, y: top - reach),
                                   control2: CGPoint(x: xl, y: bottom + reach))
                    shape.addLine(to: CGPoint(x: xr - stroke * 0.35, y: bottom))
                    shape.addCurve(to: CGPoint(x: xr - stroke * 0.35, y: top),
                                   control1: CGPoint(x: xl + thick * 1.33, y: bottom + reach),
                                   control2: CGPoint(x: xl + thick * 1.33, y: top - reach))
                    shape.closeSubpath()
                    return width
                }
                box.items.append(.fill(path))
            case "[", "]", "⌊", "⌋", "⌈", "⌉":
                mirrored { shape, stroke in
                    let width = em * 0.34
                    let x = em * 0.12
                    let serif = width - em * 0.06
                    let hasTop = symbol != "⌊" && symbol != "⌋"
                    let hasBottom = symbol != "⌈" && symbol != "⌉"
                    shape.move(to: CGPoint(x: hasTop ? serif : x, y: top - stroke / 2))
                    shape.addLine(to: CGPoint(x: x, y: top - stroke / 2))
                    shape.addLine(to: CGPoint(x: x, y: bottom + stroke / 2))
                    shape.addLine(to: CGPoint(x: hasBottom ? serif : x, y: bottom + stroke / 2))
                    return width
                }
                box.items.append(.stroke(path, stroke))
            case "{", "}":
                mirrored { shape, _ in
                    let width = em * 0.42
                    let xm = width * 0.5
                    let xl = em * 0.06
                    let xr = width - em * 0.04
                    let curl = min(height * 0.12, em * 0.3)
                    shape.move(to: CGPoint(x: xr, y: top))
                    shape.addQuadCurve(to: CGPoint(x: xm, y: top - curl), control: CGPoint(x: xm, y: top))
                    shape.addLine(to: CGPoint(x: xm, y: a + curl))
                    shape.addQuadCurve(to: CGPoint(x: xl, y: a), control: CGPoint(x: xm, y: a))
                    shape.addQuadCurve(to: CGPoint(x: xm, y: a - curl), control: CGPoint(x: xm, y: a))
                    shape.addLine(to: CGPoint(x: xm, y: bottom + curl))
                    shape.addQuadCurve(to: CGPoint(x: xr, y: bottom), control: CGPoint(x: xm, y: bottom))
                    return width
                }
                box.items.append(.stroke(path, stroke))
            case "⟨", "⟩", "<", ">":
                mirrored { shape, _ in
                    let width = min(em * 0.36 + height * 0.05, em * 0.6)
                    shape.move(to: CGPoint(x: width - em * 0.06, y: top))
                    shape.addLine(to: CGPoint(x: em * 0.08, y: a))
                    shape.addLine(to: CGPoint(x: width - em * 0.06, y: bottom))
                    return width
                }
                box.items.append(.stroke(path, stroke))
            case "|", "∣":
                let width = em * 0.26
                path.move(to: CGPoint(x: width / 2, y: top))
                path.addLine(to: CGPoint(x: width / 2, y: bottom))
                box.width = width
                box.items.append(.stroke(path, stroke))
            case "‖":
                let width = em * 0.4
                for x in [width / 2 - em * 0.07, width / 2 + em * 0.07] {
                    path.move(to: CGPoint(x: x, y: top))
                    path.addLine(to: CGPoint(x: x, y: bottom))
                }
                box.width = width
                box.items.append(.stroke(path, stroke))
            default:
                // 不认识的定界符：放大字形凑合。
                let factor = max(height / (em * 1.0), 1)
                var glyph = glyphs(symbol, font: font(em * factor))
                glyph = glyph.shifted(by: a - (glyph.ascent - glyph.descent) / 2)
                return glyph
            }
            return box
        }
    }
}
