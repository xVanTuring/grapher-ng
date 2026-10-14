import CoreGraphics
import CoreText
import Foundation
import GrapherKit

/// 不经过界面，把一份文档按存下时的样子画出来：Finder 缩略图、欢迎窗口的最近文档、立体图导出 PNG 共用；
/// 空格预览的初始取景（`planeViewport` / `spaceView`）也取自这里。图形按目标尺寸重新采样，不是把屏幕上的图缩放。
/// 只依赖 Core Graphics / Core Text / Metal，不碰 AppKit，Quick Look 扩展里也能用。
public enum GraphSnapshot {

    // MARK: - 取景

    /// 文档存下时没被侧栏 / 工具栏盖住的那块（像素）。
    public static func savedCanvasSize(of document: GrapherDocument) -> CGSize {
        let viewport = document.viewport.unobscured
        return CGSize(width: max(viewport.widthPixels, 1), height: max(viewport.heightPixels, 1))
    }

    /// 平面图：存下时没被盖住的那块，铺满 `pixelWidth × pixelHeight`（比例不同时多出的裁掉）。
    public static func planeViewport(of document: GrapherDocument, pixelWidth: Double, pixelHeight: Double) -> Viewport2D {
        var viewport = document.viewport.unobscured
        let fill = max(pixelWidth / max(viewport.widthPixels, 1), pixelHeight / max(viewport.heightPixels, 1))
        viewport.widthPixels = pixelWidth
        viewport.heightPixels = pixelHeight
        viewport.scale *= fill
        return viewport
    }

    /// 立体图：存下时的视角与坐标盒，画布换成 `pixelWidth × pixelHeight`、不留遮挡。
    public static func spaceView(of document: GrapherDocument, pixelWidth: Double, pixelHeight: Double) -> View3D {
        var view = document.view3D
        view.widthPixels = pixelWidth
        view.heightPixels = pixelHeight
        view.insetLeft = 0
        view.insetTop = 0
        view.insetRight = 0
        view.insetBottom = 0
        return view
    }

    // MARK: - 位图

    /// - Parameters:
    ///   - pointScale: 像素 / 点：线宽、字号按它放大。
    ///   - labels: 是否画刻度数字与轴名（缩略图不画，太小看不清）。
    public static func image(
        of document: GrapherDocument,
        pixelWidth: Int,
        pixelHeight: Int,
        pointScale: Double,
        quality: SampleQuality = .full,
        labels: Bool
    ) -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        if document.dimension == .space {
            let view = spaceView(of: document, pixelWidth: Double(pixelWidth), pixelHeight: Double(pixelHeight))
            return spaceImage(of: document, view: view, pointScale: pointScale, quality: quality, labels: labels)
        }

        let viewport = planeViewport(of: document, pixelWidth: Double(pixelWidth), pixelHeight: Double(pixelHeight))
        let built = SceneBuilder2D.build(SceneBuildRequest(
            document: document, compiled: LayerCompiler().compile(document), viewport: viewport,
            quality: quality, backingScale: pointScale))
        // 小图多采一倍再缩回来，边缘更干净；大图（预览、导出）本身像素够多，不必。
        let supersample = pixelWidth * pixelHeight <= 1_000_000 ? 2 : 1
        guard let context = MetalContext.shared,
              let renderer = OffscreenRenderer2D(context: context, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                                 supersample: supersample),
              let rendered = renderer.makeImage(built.scene)
        else { return nil }
        guard labels else { return rendered }
        return drawing(on: rendered) { context in
            drawPlaneLabels(document: document, viewport: viewport, pointScale: pointScale, in: context)
        }
    }

    /// 立体图按给定视图出图：缩略图、预览用 `spaceView` 取景，导出 PNG 用窗口眼前的视图。
    public static func spaceImage(
        of document: GrapherDocument,
        view: View3D,
        pointScale: Double,
        quality: SampleQuality,
        labels: Bool
    ) -> CGImage? {
        let width = Int(view.widthPixels)
        let height = Int(view.heightPixels)
        let built = SceneBuilder3D.build(SceneBuild3DRequest(
            document: document, compiled: LayerCompiler().compile(document), view: view,
            quality: quality, backingScale: pointScale))
        let chrome = Chrome3D.make(view: view, document: document, backingScale: pointScale)
        guard width > 0, height > 0,
              let context = MetalContext.shared,
              let renderer = OffscreenRenderer3D(context: context, pixelWidth: width, pixelHeight: height),
              let rendered = renderer.makeImage(content: built.scene, contentView: built.view, chrome: chrome.scene,
                                                view: view, background: document.theme.background)
        else { return nil }
        guard labels else { return rendered }
        return drawing(on: rendered) { context in
            let painter = LabelPainter(pointScale: pointScale, color: document.theme.label, axisNameSize: 12)
            for label in chrome.labels {
                guard let screen = view.project(label.position) else { continue }
                let point = CGPoint(x: screen.x, y: screen.y)
                switch label.kind {
                case .tick(let value, let decimals):
                    painter.draw(AxisLabelFormat.tick(value, decimals: decimals), font: painter.tick,
                                 at: point, anchor: .center, in: context)
                case .axisName(let name):
                    painter.draw(name, font: painter.axisName, at: point, anchor: .center, in: context)
                }
            }
        }
    }

    // MARK: - 文字

    /// 平面图的坐标轴文字，位置与画布上一致（`PlaneLabels`）。`context` 是像素坐标、左上角原点。
    private static func drawPlaneLabels(document: GrapherDocument, viewport: Viewport2D, pointScale: Double, in context: CGContext) {
        let chrome = ChromeLayout.make(viewport: viewport)
        let painter = LabelPainter(pointScale: pointScale, color: document.theme.label, axisNameSize: 11)
        let labels = PlaneLabels.make(
            chrome: chrome, viewport: viewport, showTickLabels: document.showTickLabels,
            width: viewport.widthPixels / pointScale, height: viewport.heightPixels / pointScale, pointScale: pointScale)
        for label in labels {
            let font: CTFont
            switch label.role {
            case .tick: font = painter.tick
            case .origin: font = painter.origin
            case .axisName: font = painter.axisName
            }
            painter.draw(label.text, font: font, at: CGPoint(x: label.point.x * pointScale, y: label.point.y * pointScale),
                         anchor: label.anchor, in: context)
        }
    }

    /// 在渲染好的图上再画一层：交给 `body` 的上下文是像素坐标、左上角原点、y 向下。
    private static func drawing(on image: CGImage, _ body: (CGContext) -> Void) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        body(context)
        return context.makeImage()
    }
}

/// 用 Core Text 画坐标轴文字：字号与画布上一致（刻度 10.5 点、等宽数字，原点与轴名加粗），按像素倍率放大。
/// 上下文是 y 向下的坐标，所以每串字局部再翻一次。
private struct LabelPainter {
    let tick: CTFont
    let origin: CTFont
    let axisName: CTFont
    let color: CGColor

    init(pointScale: Double, color: RGBAColor, axisNameSize: Double) {
        tick = Self.font(size: 10.5 * pointScale, bold: false, monospacedDigits: true)
        origin = Self.font(size: 10.5 * pointScale, bold: true, monospacedDigits: false)
        axisName = Self.font(size: axisNameSize * pointScale, bold: true, monospacedDigits: false)
        self.color = CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a)
    }

    private static func font(size: Double, bold: Bool, monospacedDigits: Bool) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        guard monospacedDigits else { return base }
        let descriptor = CTFontDescriptorCreateCopyWithFeature(
            CTFontCopyFontDescriptor(base), NSNumber(value: kNumberSpacingType), NSNumber(value: kMonospacedNumbersSelector))
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// 锚点的意思同画布叠加层（`LabelAnchor`）：`.top` 是锚点在字的上沿正中，依此类推。
    func draw(_ text: String, font: CTFont, at point: CGPoint, anchor: LabelAnchor, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let height = ascent + descent
        let left: CGFloat
        let top: CGFloat
        switch anchor {
        case .top: (left, top) = (point.x - width / 2, point.y)
        case .bottom: (left, top) = (point.x - width / 2, point.y - height)
        case .leading: (left, top) = (point.x, point.y - height / 2)
        case .trailing: (left, top) = (point.x - width, point.y - height / 2)
        case .center: (left, top) = (point.x - width / 2, point.y - height / 2)
        }
        context.saveGState()
        context.translateBy(x: left, y: top + ascent)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
