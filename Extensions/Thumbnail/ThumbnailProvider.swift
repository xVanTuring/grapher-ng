import Foundation
import GrapherKit
import GrapherRender
import QuickLookThumbnailing

/// 访达里 .grapher 文件的缩略图：文档存下时的样子，比例同存下时的画布，不画刻度文字
/// （`GraphSnapshot.image`，与欢迎窗口最近文档同一份画法）。
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        do {
            let document = try DocumentStore.load(from: request.fileURL)
            let saved = GraphSnapshot.savedCanvasSize(of: document)
            let maximum = request.maximumSize
            let fit = min(maximum.width / saved.width, maximum.height / saved.height)
            let size = CGSize(width: max((saved.width * fit).rounded(), 1), height: max((saved.height * fit).rounded(), 1))
            let pixelWidth = Int(size.width * request.scale)
            let pixelHeight = Int(size.height * request.scale)
            // 线宽跟着缩略图大小走：长边 160 像素时按 1 倍（同欢迎窗口），大图相应加粗，小图不至于细到看不见。
            let pointScale = max(Double(max(pixelWidth, pixelHeight)) / 160, 0.5)
            guard let image = GraphSnapshot.image(of: document, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                                  pointScale: pointScale, labels: false)
            else { throw CocoaError(.fileReadCorruptFile) }
            handler(QLThumbnailReply(contextSize: size, drawing: { context in
                // 交来的上下文是像素口径（Retina 下是 `size` 的两倍），不能按点画：那样只占左下四分之一。
                // 取整块可画区域，什么倍率都铺满。
                context.draw(image, in: context.boundingBoxOfClipPath)
                return true
            }), nil)
        } catch {
            handler(nil, error)
        }
    }
}
