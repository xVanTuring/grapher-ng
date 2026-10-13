import Foundation
import GrapherKit
import Metal

/// Batched, analytic-coverage renderer for `Scene2D`.
///
/// A scene is turned into GPU geometry **once** (`prepare`) — one buffer of
/// instanced strokes (which also carry markers), one of instanced rectangles for
/// region fills, plus an ordered list of draw ranges so the layer stacking order
/// survives all the way to the draw calls. Drawing a prepared scene again only
/// costs a few bytes of uniforms, which is what lets a drag re-draw the old
/// geometry under a new `ScreenTransform2D` every frame while fresh samples are
/// still being computed.
public final class Renderer2D {
    private let device: MTLDevice
    private let strokePipeline: MTLRenderPipelineState
    private let fillPipeline: MTLRenderPipelineState

    public init?(context: MetalContext) {
        guard let strokePipeline = Self.makePipeline(
            device: context.device,
            library: context.library,
            vertex: "stroke_vertex",
            fragment: "stroke_fragment"
        ), let fillPipeline = Self.makePipeline(
            device: context.device,
            library: context.library,
            vertex: "fill_vertex",
            fragment: "fill_fragment"
        ) else { return nil }

        self.device = context.device
        self.strokePipeline = strokePipeline
        self.fillPipeline = fillPipeline
    }

    /// One prepared scene plus where to put it on screen.
    public struct Pass {
        public var scene: PreparedScene2D
        public var transform: ScreenTransform2D

        public init(scene: PreparedScene2D, transform: ScreenTransform2D = .identity) {
            self.scene = scene
            self.transform = transform
        }
    }

    /// Uploads `scene` into buffers of its own. The result is immutable and can be
    /// drawn any number of times, from any frame.
    ///
    /// - Parameter cullSize: geometry entirely outside `0...cullSize` (the scene's
    ///   own pixel space) is dropped. `nil` keeps everything.
    public func prepare(_ scene: Scene2D, cullSize: SIMD2<Double>? = nil) -> PreparedScene2D {
        var lines: [LineInstance] = []
        var rects: [RectInstance] = []
        var ranges: [DrawRange] = []
        ranges.reserveCapacity(scene.commands.count)
        let cull = cullSize.map { SIMD2<Float>(Float($0.x), Float($0.y)) }

        for command in scene.commands {
            switch command {
            case .polyline(let polyline):
                let start = lines.count
                Self.append(polyline, cull: cull, into: &lines)
                if lines.count > start {
                    ranges.append(.lines(offset: start, count: lines.count - start))
                }

            case .rects(let batch):
                let start = rects.count
                Self.append(batch, cull: cull, into: &rects)
                if rects.count > start {
                    ranges.append(.rects(offset: start, count: rects.count - start))
                }

            case .markers(let batch):
                let start = lines.count
                Self.append(batch, cull: cull, into: &lines)
                if lines.count > start {
                    ranges.append(.lines(offset: start, count: lines.count - start))
                }
            }
        }

        return PreparedScene2D(
            background: scene.background,
            lineBuffer: makeBuffer(lines, label: "stroke"),
            rectBuffer: makeBuffer(rects, label: "fill"),
            ranges: ranges,
            instanceCount: lines.count + rects.count
        )
    }

    /// Encodes the passes, in order, into one render pass.
    public func encode(
        _ passes: [Pass],
        commandBuffer: MTLCommandBuffer,
        descriptor: MTLRenderPassDescriptor,
        viewportSize: SIMD2<Double>
    ) {
        guard viewportSize.x > 0, viewportSize.y > 0 else { return }
        // Even an empty scene goes through a pass so that the clear still lands.
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        for pass in passes {
            var uniforms = Uniforms(
                viewportSize: SIMD2(Float(viewportSize.x), Float(viewportSize.y)),
                translation: SIMD2(Float(pass.transform.translation.x), Float(pass.transform.translation.y)),
                scale: Float(pass.transform.scale),
                pad: 0
            )
            for range in pass.scene.ranges {
                switch range {
                case .lines(let offset, let count):
                    guard let buffer = pass.scene.lineBuffer else { continue }
                    encoder.setRenderPipelineState(strokePipeline)
                    encoder.setVertexBuffer(buffer, offset: offset * MemoryLayout<LineInstance>.stride, index: 0)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)

                case .rects(let offset, let count):
                    guard let buffer = pass.scene.rectBuffer else { continue }
                    encoder.setRenderPipelineState(fillPipeline)
                    encoder.setVertexBuffer(buffer, offset: offset * MemoryLayout<RectInstance>.stride, index: 0)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
                }
            }
        }
        encoder.endEncoding()
    }

    /// Encodes `scene` into an already started render pass (one-off drawing:
    /// offscreen export and tests).
    public func encode(
        scene: Scene2D,
        commandBuffer: MTLCommandBuffer,
        descriptor: MTLRenderPassDescriptor,
        viewportSize: SIMD2<Double>
    ) {
        guard viewportSize.x > 0, viewportSize.y > 0 else { return }
        encode(
            [Pass(scene: prepare(scene, cullSize: viewportSize))],
            commandBuffer: commandBuffer,
            descriptor: descriptor,
            viewportSize: viewportSize
        )
    }

    /// Convenience path for offscreen work: builds the pass, clears to
    /// `scene.background`, submits and blocks until the GPU is done.
    @discardableResult
    public func renderSynchronously(
        scene: Scene2D,
        to texture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
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

        encode(
            scene: scene,
            commandBuffer: commandBuffer,
            descriptor: descriptor,
            viewportSize: SIMD2(Double(texture.width), Double(texture.height))
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    // MARK: - Geometry assembly

    private func makeBuffer<T>(_ items: [T], label: String) -> MTLBuffer? {
        guard !items.isEmpty else { return nil }
        let buffer = items.withUnsafeBytes { bytes -> MTLBuffer? in
            guard let base = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }
        buffer?.label = "GrapherRender.\(label)"
        return buffer
    }

    private static func append(_ polyline: PolylinePrimitive, cull: SIMD2<Float>?, into lines: inout [LineInstance]) {
        let points = polyline.points
        guard points.count >= 2 else { return }
        let halfWidth = max(polyline.width, 0) / 2
        let color = vector(polyline.color)

        let segmentCount = polyline.isClosed ? points.count : points.count - 1
        lines.reserveCapacity(lines.count + segmentCount)
        for i in 0..<segmentCount {
            appendSegment(
                from: points[i],
                to: points[(i + 1) % points.count],
                halfWidth: halfWidth,
                color: color,
                cull: cull,
                into: &lines
            )
        }
    }

    private static func append(_ batch: RectPrimitiveBatch, cull: SIMD2<Float>?, into rects: inout [RectInstance]) {
        let count = min(batch.geometry.count, batch.coverage.count)
        guard count > 0 else { return }
        let base = batch.color
        rects.reserveCapacity(rects.count + count)
        for i in 0..<count {
            let rect = batch.geometry[i]
            let x0 = rect.x, x1 = rect.y, y0 = rect.z, y1 = rect.w
            guard x1 > x0, y1 > y0 else { continue }
            if let cull, x1 <= 0 || x0 >= cull.x || y1 <= 0 || y0 >= cull.y { continue }

            let coverage = min(max(Double(batch.coverage[i]), 0), 1)
            let alpha = Float(base.a * coverage)
            guard alpha > 0 else { continue }
            // Half-open [x0, x1) x [y0, y1): pixel centres inside the bounds are
            // covered, which is exactly the area the CPU coverage accounted for.
            rects.append(RectInstance(
                rect: rect,
                color: SIMD4<Float>(Float(base.r), Float(base.g), Float(base.b), alpha)
            ))
        }
    }

    private static func append(_ batch: MarkerPrimitiveBatch, cull: SIMD2<Float>?, into lines: inout [LineInstance]) {
        guard !batch.positions.isEmpty else { return }
        let radius = max(batch.radius, 0)
        let color = vector(batch.color)
        for position in batch.positions {
            appendSegment(from: position, to: position, halfWidth: radius, color: color, cull: cull, into: &lines)
        }
    }

    /// A degenerate segment is the marker case: the shader falls back to a point
    /// distance, which produces a disc without ever taking a square root of zero
    /// length or a division by it.
    private static func appendSegment(
        from a: SIMD2<Double>,
        to b: SIMD2<Double>,
        halfWidth: Double,
        color: SIMD4<Float>,
        cull: SIMD2<Float>?,
        into lines: inout [LineInstance]
    ) {
        if let cull {
            let extend = Float(halfWidth + 0.5)
            let minX = Float(min(a.x, b.x)) - extend
            let maxX = Float(max(a.x, b.x)) + extend
            let minY = Float(min(a.y, b.y)) - extend
            let maxY = Float(max(a.y, b.y)) + extend
            if maxX < 0 || minX > cull.x || maxY < 0 || minY > cull.y { return }
        }

        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        let tangent = length > 1e-12
            ? SIMD2<Float>(Float(dx / length), Float(dy / length))
            : SIMD2<Float>(1, 0)

        lines.append(LineInstance(
            a: SIMD2(Float(a.x), Float(a.y)),
            b: SIMD2(Float(b.x), Float(b.y)),
            tangent: tangent,
            halfWidth: Float(halfWidth),
            pad: 0,
            color: color
        ))
    }

    private static func vector(_ color: RGBAColor) -> SIMD4<Float> {
        SIMD4<Float>(Float(color.r), Float(color.g), Float(color.b), Float(color.a))
    }

    // MARK: - Pipeline

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertex: String,
        fragment: String
    ) -> MTLRenderPipelineState? {
        guard let vertexFunction = library.makeFunction(name: vertex),
              let fragmentFunction = library.makeFunction(name: fragment)
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = vertex
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = MetalContext.sampleCount

        guard let attachment = descriptor.colorAttachments[0] else { return nil }
        attachment.pixelFormat = MetalContext.colorFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        // The colour channels stay straight (non-premultiplied), so the alpha
        // channel needs its own accumulator; `sourceAlpha` there would square
        // the coverage of every partially covered pixel.
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}

/// A scene already uploaded to the GPU. Immutable: the buffers are never written
/// after creation, so any number of in-flight frames may read them at once.
public final class PreparedScene2D {
    public let background: RGBAColor
    fileprivate let lineBuffer: MTLBuffer?
    fileprivate let rectBuffer: MTLBuffer?
    fileprivate let ranges: [DrawRange]
    /// Stroke segments + markers + fill rectangles that survived culling.
    public let instanceCount: Int

    fileprivate init(
        background: RGBAColor,
        lineBuffer: MTLBuffer?,
        rectBuffer: MTLBuffer?,
        ranges: [DrawRange],
        instanceCount: Int
    ) {
        self.background = background
        self.lineBuffer = lineBuffer
        self.rectBuffer = rectBuffer
        self.ranges = ranges
        self.instanceCount = instanceCount
    }
}

// MARK: - Buffer layout

/// Must match `Instance` in the Metal source.
private struct LineInstance {
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    var tangent: SIMD2<Float>
    var halfWidth: Float
    var pad: Float
    var color: SIMD4<Float>
}

/// Must match `RectInstance` in the Metal source.
private struct RectInstance {
    /// x0, x1, y0, y1 in pixels.
    var rect: SIMD4<Float>
    var color: SIMD4<Float>
}

/// Must match `Uniforms` in the Metal source.
private struct Uniforms {
    var viewportSize: SIMD2<Float>
    var translation: SIMD2<Float>
    var scale: Float
    var pad: Float
}

private enum DrawRange {
    case lines(offset: Int, count: Int)
    case rects(offset: Int, count: Int)
}
