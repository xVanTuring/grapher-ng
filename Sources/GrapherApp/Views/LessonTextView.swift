import AppKit
import GrapherKit
import GrapherRender

/// 显示一段讲解文字（正文夹 TeX 公式）的视图：按自己的宽度排版（`LessonTextLayout`），高度随内容。
/// 颜色在画的时候按当前外观取，深浅色切换不用重排。只依赖 AppKit 与 GrapherRender，嵌入块也能用。
final class LessonTextView: NSView {

    var text: String = "" {
        didSet { if text != oldValue { invalidateLayout() } }
    }
    var fontSize: CGFloat = 14 {
        didSet { if fontSize != oldValue { invalidateLayout() } }
    }
    var bold = false {
        didSet { if bold != oldValue { invalidateLayout() } }
    }
    var textColor: NSColor = .labelColor {
        didSet { needsDisplay = true }
    }

    private var cached: LessonTextLayout?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// 给定宽度时排出来多高。
    func height(forWidth width: CGFloat) -> CGFloat {
        layout(forWidth: width).height
    }

    private func layout(forWidth width: CGFloat) -> LessonTextLayout {
        if let cached, abs(cached.width - max(width, 1)) < 0.5 { return cached }
        let made = LessonTextLayout(text: text, width: width, fontSize: fontSize, bold: bold)
        cached = made
        return made
    }

    private func invalidateLayout() {
        cached = nil
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        guard bounds.width > 1 else { return NSSize(width: NSView.noIntrinsicMetric, height: fontSize * 1.4) }
        return NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let layout = layout(forWidth: bounds.width)
        var color = CGColor(gray: 0, alpha: 1)
        effectiveAppearance.performAsCurrentDrawingAppearance { color = self.textColor.cgColor }
        // 本视图是 y 向下的，排版按 y 向上画：翻一下。
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        layout.draw(in: context, topLeft: CGPoint(x: 0, y: bounds.height), color: color)
        context.restoreGState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
