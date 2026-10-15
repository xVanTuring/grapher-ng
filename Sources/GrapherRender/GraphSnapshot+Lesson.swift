import CoreGraphics
import CoreText
import Foundation
import GrapherKit

extension GraphSnapshot {

    /// 讲解第 `step` 步的样子：图层按这一步显示，参数与取景取「一路讲到这一步」时的（`lessonState(at:)`），
    /// 底部画讲解卡片（第几步、标题、讲解文字，公式按 TeX 排好），图形摆在卡片上方。
    /// MCP 出图、无界面渲染、测试用；App 里的卡片是 AppKit 视图，排版是同一份 `LessonTextLayout`。
    /// - Parameter caption: 为假时不画卡片，只出这一步的图。
    public static func lessonImage(
        of document: GrapherDocument,
        step: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        pointScale: Double,
        quality: SampleQuality = .full,
        caption: Bool = true
    ) -> CGImage? {
        guard document.lessonSteps.indices.contains(step), pixelWidth > 0, pixelHeight > 0 else {
            return image(of: document, pixelWidth: pixelWidth, pixelHeight: pixelHeight, pointScale: pointScale,
                         quality: quality, labels: true)
        }
        var shown = document.presenting(step: step)
        let state = document.lessonState(at: step)
        for index in shown.parameters.indices {
            if let value = state.parameters[shown.parameters[index].name], value.isFinite {
                shown.parameters[index].value = value
            }
        }

        let scale = CGFloat(max(pointScale, 0.1))
        let widthPoints = CGFloat(pixelWidth) / scale
        let margin: CGFloat = 12
        let dark = document.theme.background.r < 0.5
        let card = caption
            ? LessonCaptionCard(step: document.lessonSteps[step], index: step, count: document.lessonSteps.count,
                                width: min(860, widthPoints - 2 * margin), dark: dark)
            : nil
        let reserved = Double(card.map { ($0.height + 2 * margin) * scale } ?? 0)

        let width = Double(pixelWidth), height = Double(pixelHeight)
        let rendered: CGImage?
        if shown.dimension == .space {
            var view = spaceView(of: shown, pixelWidth: width, pixelHeight: height)
            if let camera = state.camera?.space {
                view.center = camera.center
                view.halfExtent = camera.halfExtent
                view.azimuth = camera.azimuth
                view.elevation = camera.elevation
                view.cameraZoom = camera.cameraZoom
            }
            view.insetBottom = reserved
            rendered = spaceImage(of: shown, view: view, pointScale: pointScale, quality: quality, labels: true)
        } else {
            var viewport = planeViewport(of: shown, pixelWidth: width, pixelHeight: height)
            if let center = state.camera?.planeCenter, let frameWidth = state.camera?.planeWidth, frameWidth > 0 {
                viewport.centerX = center.x
                viewport.centerY = center.y
                viewport.scale = width / frameWidth
            }
            viewport.insetBottom = reserved
            rendered = planeImage(of: shown, viewport: viewport, pointScale: pointScale, quality: quality, labels: true)
        }
        guard let rendered, let card else { return rendered }
        return drawing(on: rendered) { context in
            // 上下文是像素、左上角原点、y 向下；卡片按点算，贴着底边居中。
            context.scaleBy(x: scale, y: scale)
            let heightPoints = CGFloat(pixelHeight) / scale
            let rect = CGRect(x: (widthPoints - card.width) / 2, y: heightPoints - margin - card.height,
                              width: card.width, height: card.height)
            card.draw(in: context, rect: rect)
        }
    }
}

/// 出图用的讲解卡片：圆角底板、「2 / 7」、标题（加粗）、讲解文字。
struct LessonCaptionCard {
    static let padding: CGFloat = 14
    static let gap: CGFloat = 8

    let width: CGFloat
    let height: CGFloat
    private let counter: LessonTextLayout
    private let title: LessonTextLayout
    private let body: LessonTextLayout?
    private let dark: Bool

    init(step: LessonStep, index: Int, count: Int, width: CGFloat, dark: Bool) {
        self.width = max(width, 120)
        self.dark = dark
        let inner = self.width - 2 * Self.padding
        counter = LessonTextLayout(text: "\(index + 1) / \(count)", width: 60, fontSize: 12)
        let counterWidth: CGFloat = 52
        let titleText = step.title.isEmpty ? "\(index + 1)" : step.title
        title = LessonTextLayout(text: titleText, width: inner - counterWidth, fontSize: 15, bold: true)
        body = step.text.isEmpty ? nil : LessonTextLayout(text: step.text, width: inner, fontSize: 14)
        var total = Self.padding + max(title.height, counter.height)
        if let body { total += Self.gap + body.height }
        height = total + Self.padding
    }

    /// `context` 是 y 向下的点坐标；`rect` 是卡片的位置。
    func draw(in context: CGContext, rect: CGRect) {
        let background = dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 0.95)
                              : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95)
        let border = dark ? CGColor(gray: 1, alpha: 0.12) : CGColor(gray: 0, alpha: 0.12)
        let ink = dark ? CGColor(gray: 0.94, alpha: 1) : CGColor(gray: 0.1, alpha: 1)
        let secondary = dark ? CGColor(gray: 0.65, alpha: 1) : CGColor(gray: 0.45, alpha: 1)

        context.saveGState()
        let path = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        context.addPath(path)
        context.setFillColor(background)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(border)
        context.setLineWidth(0.75)
        context.strokePath()

        // 排版按 y 向上画：在卡片范围里上下翻一次，卡片上沿翻到 `rect.maxY`。
        context.translateBy(x: 0, y: rect.minY + rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let left = rect.minX + Self.padding
        let top = rect.maxY - Self.padding
        counter.draw(in: context, topLeft: CGPoint(x: left, y: top - 2), color: secondary)
        title.draw(in: context, topLeft: CGPoint(x: left + 52, y: top), color: ink)
        if let body {
            let bodyTop = top - max(title.height, counter.height) - Self.gap
            body.draw(in: context, topLeft: CGPoint(x: left, y: bodyTop), color: ink)
        }
        context.restoreGState()
    }
}
