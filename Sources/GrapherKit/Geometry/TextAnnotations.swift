import Foundation
import simd

/// 画布上的自由文字：文字图层（`.text`）的内容与位置。画布叠加层与导出的图片共用，两边写的一样。
public struct TextAnnotation: Equatable, Sendable {
    public var text: String
    /// 数据坐标：平面图只用 x、y（z 为 0）。
    public var position: SIMD3<Double>
    public var color: RGBAColor
    /// 字号，点。
    public var fontSize: Double
}

public enum TextAnnotations {
    /// 文档里可见的、有内容的文字图层，按图层顺序。位置可以写成含参数的公式，所以要用编译后的图层
    /// （`compiled` 里的位置已经按当前参数算成了数）；没传就现编一份（不带缓存，画布每帧调用时请传进来）。
    public static func all(
        in document: GrapherDocument, compiled: [LayerCompiler.CompiledLayer]? = nil
    ) -> [TextAnnotation] {
        let resolved = (compiled ?? LayerCompiler().compile(document)).map(\.layer)
        return resolved.compactMap { layer in
            guard layer.kind == .text, layer.isVisible, !layer.formula.isEmpty else { return nil }
            let position = SIMD3(layer.anchorU, layer.anchorV, document.dimension == .space ? layer.anchorW : 0)
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { return nil }
            return TextAnnotation(
                text: layer.formula, position: position, color: layer.lineStyle.color,
                fontSize: min(max(layer.fontSize, 6), 96))
        }
    }
}
