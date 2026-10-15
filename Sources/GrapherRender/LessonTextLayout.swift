import CoreGraphics
import CoreText
import Foundation
import GrapherKit

/// 讲解文字排好的版：正文按宽度折行，行内公式（`$…$`）像一个字一样排在行里，行间公式（`$$…$$`）单独一行居中。
/// 只用 Core Text：App 的讲解卡片、嵌入块、导出图片共用这一份。
public final class LessonTextLayout {

    public let width: CGFloat
    public private(set) var height: CGFloat = 0
    /// 公式字号比正文大一点：STIX 的字面比系统字体小，同一字号看起来偏小。
    public static let mathScale: CGFloat = 1.1

    private enum Piece {
        /// 一段正文：每行的基线原点与这一行里要画的字（公式的占位不在里面），位置相对这段的左下角、y 向上。
        case frame(lines: [(origin: CGPoint, runs: [CTRun])], height: CGFloat, math: [(MathBox, CGPoint)])
        case display(MathBox, x: CGFloat, height: CGFloat)
        case gap(CGFloat)
    }

    private var pieces: [Piece] = []

    /// - Parameters:
    ///   - bold: 整段加粗（标题用）。
    ///   - lineSpacing: 行与行之间额外的空隙（点）。
    public init(text: String, width: CGFloat, fontSize: CGFloat, bold: Bool = false, lineSpacing: CGFloat? = nil) {
        self.width = max(width, 1)
        let spacing = lineSpacing ?? fontSize * 0.35
        for paragraph in LessonText.paragraphs(text) {
            switch paragraph {
            case .display(let tex):
                let box = MathTypesetter.layout(tex, fontSize: fontSize * Self.mathScale, display: true)
                let margin = fontSize * 0.4
                let x = max((self.width - box.width) / 2, 0)
                let piece = Piece.display(box, x: x, height: box.ascent + box.descent + 2 * margin)
                pieces.append(piece)
                height += box.ascent + box.descent + 2 * margin
            case .inline(let runs):
                if runs.isEmpty {
                    pieces.append(.gap(fontSize * 0.6))
                    height += fontSize * 0.6
                    continue
                }
                let piece = Self.frame(runs, width: self.width, fontSize: fontSize, bold: bold, lineSpacing: spacing)
                pieces.append(piece)
                if case .frame(_, let h, _) = piece { height += h }
            }
        }
        height = ceil(height)
    }

    /// 画在 y 向上的上下文里：`topLeft` 是这块文字的左上角（文字往下排，占到 `topLeft.y - height`）。
    public func draw(in context: CGContext, topLeft: CGPoint, color: CGColor) {
        var top = topLeft.y
        context.saveGState()
        context.textMatrix = .identity
        context.setFillColor(color)
        for piece in pieces {
            switch piece {
            case .gap(let h):
                top -= h
            case .display(let box, let x, let h):
                let margin = (h - box.ascent - box.descent) / 2
                box.draw(in: context, at: CGPoint(x: topLeft.x + x, y: top - margin - box.ascent), color: color)
                top -= h
            case .frame(let lines, let h, let math):
                let bottom = top - h
                // 逐个字串画、跳过公式的占位：颜色都取上下文的填充色，画的时候才定（深浅色切换不用重排）。
                for line in lines {
                    context.textPosition = CGPoint(x: topLeft.x + line.origin.x, y: bottom + line.origin.y)
                    for run in line.runs { CTRunDraw(run, context, CFRange(location: 0, length: 0)) }
                }
                for (box, origin) in math {
                    box.draw(in: context, at: CGPoint(x: topLeft.x + origin.x, y: bottom + origin.y), color: color)
                }
                top = bottom
            }
        }
        context.restoreGState()
    }

    // MARK: - 一段正文

    /// 留给公式的那个占位字符的尺寸由这个对象提供（`CTRunDelegate` 回调里取）。
    private final class Holder {
        let box: MathBox
        init(_ box: MathBox) { self.box = box }
    }

    private static let mathKey = NSAttributedString.Key("GrapherLessonMath")

    private static func frame(_ runs: [LessonRun], width: CGFloat, fontSize: CGFloat, bold: Bool,
                              lineSpacing: CGFloat) -> Piece {
        let regular = MathTypesetter.textFont(size: fontSize)
        let heavy = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil) ?? regular
        let string = NSMutableAttributedString()
        var boxes: [MathBox] = []
        let fromContext = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        for run in runs {
            switch run {
            case .text(let text, let isBold):
                string.append(NSAttributedString(string: text, attributes: [
                    fontKey: (bold || isBold) ? heavy : regular,
                    fromContext: true,
                ]))
            case .math(let tex):
                let box = MathTypesetter.layout(tex, fontSize: fontSize * mathScale, display: false)
                var callbacks = CTRunDelegateCallbacks(
                    version: kCTRunDelegateVersion1,
                    dealloc: { pointer in Unmanaged<Holder>.fromOpaque(pointer).release() },
                    getAscent: { pointer in Unmanaged<Holder>.fromOpaque(pointer).takeUnretainedValue().box.ascent },
                    getDescent: { pointer in Unmanaged<Holder>.fromOpaque(pointer).takeUnretainedValue().box.descent },
                    getWidth: { pointer in Unmanaged<Holder>.fromOpaque(pointer).takeUnretainedValue().box.width }
                )
                let holder = Unmanaged.passRetained(Holder(box)).toOpaque()
                guard let delegate = CTRunDelegateCreate(&callbacks, holder) else {
                    Unmanaged<Holder>.fromOpaque(holder).release()
                    continue
                }
                string.append(NSAttributedString(string: "\u{FFFC}", attributes: [
                    fontKey: regular,
                    NSAttributedString.Key(kCTRunDelegateAttributeName as String): delegate,
                    mathKey: boxes.count,
                ]))
                boxes.append(box)
            }
        }

        var spacing = lineSpacing
        var breakMode = CTLineBreakMode.byWordWrapping
        // 设置项里的指针只在闭包里有效，样式必须在里面建好。
        let style: CTParagraphStyle = withUnsafeBytes(of: &spacing) { spacingBytes in
            withUnsafeBytes(of: &breakMode) { breakBytes in
                let settings = [
                    CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size,
                                            value: spacingBytes.baseAddress!),
                    CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size,
                                            value: breakBytes.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        string.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: style,
                            range: NSRange(location: 0, length: string.length))

        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        let height = ceil(suggested.height) + 2
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        // 每一行要画的字，以及每个公式落在哪一行的哪个位置（相对这段的左下角，y 向上）。
        var math: [(MathBox, CGPoint)] = []
        var drawn: [(origin: CGPoint, runs: [CTRun])] = []
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (line, origin) in zip(lines, origins) {
            var runs: [CTRun] = []
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let index = attributes[mathKey] as? Int, boxes.indices.contains(index) else {
                    runs.append(run)
                    continue
                }
                var position = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                math.append((boxes[index], CGPoint(x: origin.x + position.x, y: origin.y + position.y)))
            }
            drawn.append((origin, runs))
        }
        return .frame(lines: drawn, height: height, math: math)
    }
}
