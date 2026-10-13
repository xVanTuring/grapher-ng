import AppKit

enum TextAnchor {
    case top, bottom, leading, trailing, center
}

/// 一池文字小图层：同一串字只渲染一次（Core Text 画进位图，字形与 `NSAttributedString.draw` 一样清楚），
/// 之后只挪图层位置、不重画。2D、3D 画布的刻度文字都用它。
///
/// 用法：每帧 `begin()`，逐个 `place(...)`，最后 `end()` 收掉这一帧没用到的图层。
/// 所有属性改动都在调用方的 `CATransaction`（关掉隐式动画）里做。
@MainActor
final class TextLayerPool {

    struct Rendered {
        let image: CGImage
        /// 点。
        let size: CGSize
    }

    /// 文字图层都挂在它下面，按左上角原点摆放（调用方负责把它铺满、翻转好）。
    let root = CALayer()
    var scale: Double = 2
    var appearance: NSAppearance = NSAppearance(named: .aqua)!

    private var layers: [String: CALayer] = [:]
    private var rendered: [String: Rendered] = [:]
    private var used = Set<String>()

    static let noAnimations: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(),
        "contents": NSNull(), "hidden": NSNull(), "path": NSNull(),
        "strokeColor": NSNull(), "sublayers": NSNull(), "opacity": NSNull(),
    ]

    init() {
        root.actions = Self.noAnimations
    }

    func begin() {
        used.removeAll(keepingCapacity: true)
    }

    /// 摆一串字。`key` 区分同一串字的不同用途（比如 x 轴与 y 轴上都有 "5.0"）。
    func place(_ key: String, _ text: String, font: NSFont, color: NSColor, at point: CGPoint, anchor: TextAnchor) {
        let cacheKey = "\(key)|\(text)|\(font.fontName)|\(font.pointSize)|\(color.description)"
        guard let image = render(cacheKey, NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        else { return }
        used.insert(cacheKey)
        let layer: CALayer
        if let existing = layers[cacheKey] {
            layer = existing
        } else {
            layer = CALayer()
            layer.actions = Self.noAnimations
            layer.contents = image.image
            layer.contentsScale = scale
            root.addSublayer(layer)
            layers[cacheKey] = layer
        }
        let size = image.size
        let origin: CGPoint
        switch anchor {
        case .top: origin = CGPoint(x: point.x - size.width / 2, y: point.y)
        case .bottom: origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height)
        case .leading: origin = CGPoint(x: point.x, y: point.y - size.height / 2)
        case .trailing: origin = CGPoint(x: point.x - size.width, y: point.y - size.height / 2)
        case .center: origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        }
        // 落在整点上，位图不被插值糊掉。
        layer.frame = CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }

    /// 收掉这一帧没用到的图层；缓存太大时只留这一帧用到的。
    func end() {
        for (key, layer) in layers where !used.contains(key) {
            layer.removeFromSuperlayer()
            layers[key] = nil
        }
        if rendered.count > 600 {
            rendered = rendered.filter { used.contains($0.key) }
        }
    }

    /// 换了屏幕倍率或外观：位图全部重出。
    func reset() {
        rendered.removeAll()
        for layer in layers.values { layer.removeFromSuperlayer() }
        layers.removeAll()
    }

    private func render(_ key: String, _ text: NSAttributedString) -> Rendered? {
        if let cached = rendered[key] { return cached }
        let measured = text.size()
        let size = CGSize(width: measured.width.rounded(.up), height: measured.height.rounded(.up))
        guard let image = Self.renderImage(size: size, scale: scale, appearance: appearance, { _ in
            text.draw(at: .zero)
        }) else { return nil }
        rendered[key] = image
        return image
    }

    /// 在一张 `size`（点）× `scale` 的透明位图里画，画法用 AppKit 的当前上下文（不翻转，原点左下）。
    static func renderImage(
        size: CGSize,
        scale: Double,
        appearance: NSAppearance,
        _ draw: (CGRect) -> Void
    ) -> Rendered? {
        let pixelWidth = Int((size.width * scale).rounded(.up))
        let pixelHeight = Int((size.height * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        appearance.performAsCurrentDrawingAppearance {
            draw(CGRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        return Rendered(image: image, size: size)
    }
}
