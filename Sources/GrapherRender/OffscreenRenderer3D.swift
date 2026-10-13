import CoreGraphics
import Foundation
import GrapherKit
import ImageIO
import Metal

/// 3D 场景离屏渲染成图片：导出 PNG 与像素测试用。4× MSAA 渲染再在 GPU 上解析成单采样。
public final class OffscreenRenderer3D {
    public enum ExportError: Error {
        case renderFailed
        case encodeFailed
    }

    private let renderer: Renderer3D
    private let queue: MTLCommandQueue
    private let colorTexture: MTLTexture
    private let resolveTexture: MTLTexture
    private let depthTexture: MTLTexture
    private let readback: MTLBuffer
    private let bytesPerRow: Int
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init?(context: MetalContext, pixelWidth: Int, pixelHeight: Int) {
        guard pixelWidth > 0, pixelHeight > 0, let renderer = Renderer3D(context: context) else { return nil }
        let device = context.device

        let color = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalContext.colorFormat, width: pixelWidth, height: pixelHeight, mipmapped: false)
        color.textureType = .type2DMultisample
        color.sampleCount = Renderer3D.sampleCount
        color.usage = [.renderTarget]
        color.storageMode = .private

        let resolve = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalContext.colorFormat, width: pixelWidth, height: pixelHeight, mipmapped: false)
        resolve.usage = [.renderTarget, .shaderRead]
        resolve.storageMode = .private

        let depth = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Renderer3D.depthFormat, width: pixelWidth, height: pixelHeight, mipmapped: false)
        depth.textureType = .type2DMultisample
        depth.sampleCount = Renderer3D.sampleCount
        depth.usage = [.renderTarget]
        depth.storageMode = .private

        let bytesPerRow = ((pixelWidth * 4 + 255) / 256) * 256
        guard let colorTexture = device.makeTexture(descriptor: color),
              let resolveTexture = device.makeTexture(descriptor: resolve),
              let depthTexture = device.makeTexture(descriptor: depth),
              let readback = device.makeBuffer(length: bytesPerRow * pixelHeight, options: .storageModeShared)
        else { return nil }

        self.renderer = renderer
        self.queue = context.queue
        self.colorTexture = colorTexture
        self.resolveTexture = resolveTexture
        self.depthTexture = depthTexture
        self.readback = readback
        self.bytesPerRow = bytesPerRow
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// - Parameters:
    ///   - content: 曲面与曲线（按 `contentView` 的盒子归一化），按坐标盒裁剪。
    ///   - chrome: 盒子棱线、盒壁网格（按 `view` 的盒子归一化），不裁。
    ///   - view: 当前视图；它的像素尺寸应当等于本渲染器的尺寸。
    public func makeImage(
        content: Scene3D?,
        contentView: View3D,
        chrome: Scene3D?,
        view: View3D,
        background: RGBAColor
    ) -> CGImage? {
        guard let commandBuffer = queue.makeCommandBuffer() else { return nil }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = colorTexture
        descriptor.colorAttachments[0].resolveTexture = resolveTexture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .multisampleResolve
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: background.r, green: background.g, blue: background.b, alpha: background.a)
        descriptor.depthAttachment.texture = depthTexture
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.storeAction = .dontCare
        descriptor.depthAttachment.clearDepth = 1

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return nil }
        var passes: [Renderer3D.Pass] = []
        if let chrome { passes.append(Renderer3D.Pass(scene: renderer.prepare(chrome), source: view, clipToBox: false)) }
        if let content { passes.append(Renderer3D.Pass(scene: renderer.prepare(content), source: contentView, clipToBox: true)) }
        renderer.encode(passes, view: view, encoder: encoder,
                        viewportSize: SIMD2(Double(pixelWidth), Double(pixelHeight)))
        encoder.endEncoding()

        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: resolveTexture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: pixelWidth, height: pixelHeight, depth: 1),
            to: readback, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * pixelHeight
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let source = readback.contents().assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let rowBytes = pixelWidth * 4
        for y in 0..<pixelHeight {
            bytes.replaceSubrange(y * rowBytes..<(y + 1) * rowBytes,
                                  with: UnsafeBufferPointer(start: source + y * bytesPerRow, count: rowBytes))
        }
        return OffscreenRenderer2D.makeCGImage(bgra: bytes, width: pixelWidth, height: pixelHeight, bytesPerRow: rowBytes)
    }

    public func writePNG(
        content: Scene3D?,
        contentView: View3D,
        chrome: Scene3D?,
        view: View3D,
        background: RGBAColor,
        to url: URL
    ) throws {
        guard let image = makeImage(content: content, contentView: contentView, chrome: chrome,
                                    view: view, background: background)
        else { throw ExportError.renderFailed }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw ExportError.encodeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodeFailed }
    }
}
