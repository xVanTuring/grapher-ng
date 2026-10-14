import Foundation
import GrapherKit
import GrapherRender
import QuickLookUI
import UniformTypeIdentifiers

/// 访达里按空格预览 .grapher：文档存下时眼前的那块，带刻度数字。平面图出矢量 PDF，立体图出 PNG
/// （`GraphSnapshot.preview`，与 App 的导出同一份画法）。
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let document = try DocumentStore.load(from: request.fileURL)
        let (preview, size) = try GraphSnapshot.preview(of: document)
        switch preview {
        case .pdf(let data):
            return QLPreviewReply(dataOfContentType: .pdf, contentSize: size) { _ in data }
        case .png(let data):
            return QLPreviewReply(dataOfContentType: .png, contentSize: size) { _ in data }
        }
    }
}
