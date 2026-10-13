import CoreGraphics
import Foundation
import GrapherKit
import ImageIO
import Metal

/// Renders a `Scene2D` offscreen and hands back a `CGImage` / PNG.
///
/// Export is not a hot path, so supersampling is done by rendering at a larger
/// size and box-filtering back down on the CPU: that buys extra edge quality for
/// the rect batches, whose coverage the renderer deliberately takes as-is.
public final class OffscreenRenderer2D {
    public enum ExportError: Error {
        case renderFailed
        case encodeFailed
    }

    private let renderer: Renderer2D
    private let queue: MTLCommandQueue
    private let texture: MTLTexture
    private let readback: MTLBuffer
    private let pixelWidth: Int
    private let pixelHeight: Int
    private let supersample: Int
    private let renderWidth: Int
    private let renderHeight: Int
    private let readbackBytesPerRow: Int

    public init?(context: MetalContext, pixelWidth: Int, pixelHeight: Int, supersample: Int) {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        guard supersample == 1 || supersample == 2 || supersample == 4 else { return nil }
        guard let renderer = Renderer2D(context: context) else { return nil }

        let renderWidth = pixelWidth * supersample
        let renderHeight = pixelHeight * supersample

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalContext.colorFormat,
            width: renderWidth,
            height: renderHeight,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private

        // Row stride is padded: blit copies out of a texture want roomier rows
        // than a tight pixel count on some drivers.
        let bytesPerRow = ((renderWidth * 4 + 255) / 256) * 256
        let byteCount = bytesPerRow * renderHeight

        guard let texture = context.device.makeTexture(descriptor: descriptor),
              let readback = context.device.makeBuffer(length: byteCount, options: .storageModeShared)
        else { return nil }

        self.renderer = renderer
        self.queue = context.queue
        self.texture = texture
        self.readback = readback
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.supersample = supersample
        self.renderWidth = renderWidth
        self.renderHeight = renderHeight
        self.readbackBytesPerRow = bytesPerRow
    }

    /// Renders `scene` and returns it at `pixelWidth` x `pixelHeight`.
    public func makeImage(_ scene: Scene2D) -> CGImage? {
        guard let bytes = rasterize(scene) else { return nil }
        return Self.makeCGImage(
            bgra: bytes,
            width: pixelWidth,
            height: pixelHeight,
            bytesPerRow: pixelWidth * 4
        )
    }

    public func writePNG(_ scene: Scene2D, to url: URL) throws {
        guard let image = makeImage(scene) else { throw ExportError.renderFailed }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { throw ExportError.encodeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodeFailed }
    }

    // MARK: - Rasterisation

    /// Returns tightly packed BGRA bytes, top row first.
    private func rasterize(_ scene: Scene2D) -> [UInt8]? {
        guard let commandBuffer = queue.makeCommandBuffer() else { return nil }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: scene.background.r,
            green: scene.background.g,
            blue: scene.background.b,
            alpha: scene.background.a
        )

        renderer.encode(
            scene: Self.scaled(scene, by: Double(supersample)),
            commandBuffer: commandBuffer,
            descriptor: descriptor,
            viewportSize: SIMD2(Double(renderWidth), Double(renderHeight))
        )

        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: renderWidth, height: renderHeight, depth: 1),
            to: readback,
            destinationOffset: 0,
            destinationBytesPerRow: readbackBytesPerRow,
            destinationBytesPerImage: readbackBytesPerRow * renderHeight
        )
        blit.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let source = readback.contents().assumingMemoryBound(to: UInt8.self)
        return downsample(source)
    }

    private func downsample(_ source: UnsafePointer<UInt8>) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let factor = supersample
        guard factor > 1 else {
            let rowBytes = pixelWidth * 4
            for y in 0..<pixelHeight {
                let row = UnsafeBufferPointer(start: source + y * readbackBytesPerRow, count: rowBytes)
                output.replaceSubrange(y * rowBytes..<(y + 1) * rowBytes, with: row)
            }
            return output
        }

        let samples = Float(factor * factor)
        output.withUnsafeMutableBufferPointer { out in
            guard let destination = out.baseAddress else { return }
            for y in 0..<pixelHeight {
                for x in 0..<pixelWidth {
                    var sums = SIMD4<Float>(repeating: 0)
                    for sy in 0..<factor {
                        let row = source + (y * factor + sy) * readbackBytesPerRow + x * factor * 4
                        for sx in 0..<factor {
                            let pixel = row + sx * 4
                            sums += SIMD4<Float>(
                                Float(pixel[0]),
                                Float(pixel[1]),
                                Float(pixel[2]),
                                Float(pixel[3])
                            )
                        }
                    }
                    let averaged = sums / samples
                    let base = (y * pixelWidth + x) * 4
                    destination[base + 0] = UInt8(clamping: Int(averaged.x.rounded()))
                    destination[base + 1] = UInt8(clamping: Int(averaged.y.rounded()))
                    destination[base + 2] = UInt8(clamping: Int(averaged.z.rounded()))
                    destination[base + 3] = UInt8(clamping: Int(averaged.w.rounded()))
                }
            }
        }
        return output
    }

    /// Upscales the scene rather than the target: the coverage ramp must stay
    /// one *rendered* pixel wide for the extra samples to actually help.
    private static func scaled(_ scene: Scene2D, by scale: Double) -> Scene2D {
        guard scale != 1 else { return scene }
        var commands: [Draw2D] = []
        commands.reserveCapacity(scene.commands.count)
        for command in scene.commands {
            switch command {
            case .polyline(var polyline):
                polyline.points = polyline.points.map { $0 * scale }
                polyline.width *= scale
                commands.append(.polyline(polyline))
            case .rects(var batch):
                batch.geometry = batch.geometry.map {
                    SIMD4($0.x * Float(scale), $0.y * Float(scale), $0.z * Float(scale), $0.w * Float(scale))
                }
                commands.append(.rects(batch))
            case .markers(var batch):
                batch.positions = batch.positions.map { $0 * scale }
                batch.radius *= scale
                commands.append(.markers(batch))
            }
        }
        return Scene2D(background: scene.background, commands: commands)
    }

    /// `bgra8Unorm` lands in memory as B, G, R, A; declaring the same order on
    /// the image keeps the channels from being swapped on the way out.
    private static func makeCGImage(
        bgra: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> CGImage? {
        let expected = bytesPerRow * height
        guard bgra.count >= expected else { return nil }
        guard let provider = CGDataProvider(data: Data(bgra[0..<expected]) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
