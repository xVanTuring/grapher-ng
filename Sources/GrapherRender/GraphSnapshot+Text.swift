import CoreGraphics
import Foundation
import GrapherKit

extension GraphSnapshot {

    /// 文字描述（`GrapherText`）画成的一张图，连同读文字时的错误。出错的行被跳过，其余照常画。
    public struct TextRendering {
        public var image: CGImage?
        public var errors: [GrapherText.Diagnostic]
        /// 宽 / 高。
        public var aspect: Double
    }

    /// 把一段文字描述画成位图：宽度给定，高度按文字里的 `aspect:`（默认 3:2）。
    /// - Parameters:
    ///   - theme: 宿主指定的深浅色；nil 时文字里写了 `theme:` 听文字的，否则浅色。
    ///   - pointScale: 像素 / 点（线宽、字号按它放大）。
    public static func image(
        text: String,
        pixelWidth: Int,
        theme: Theme? = nil,
        pointScale: Double = 2,
        quality: SampleQuality = .high,
        labels: Bool = true
    ) -> TextRendering {
        var parsed = GrapherText.parse(text)
        if let theme { parsed.document.theme = theme }
        let height = max(Int((Double(pixelWidth) / parsed.aspect).rounded()), 1)
        let image = self.image(of: parsed.document, pixelWidth: pixelWidth, pixelHeight: height,
                               pointScale: pointScale, quality: quality, labels: labels)
        return TextRendering(image: image, errors: parsed.errors, aspect: parsed.aspect)
    }
}
