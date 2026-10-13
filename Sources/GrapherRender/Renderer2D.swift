import Foundation
import GrapherKit
import Metal

/// Batched, analytic-coverage renderer for `Scene2D`.
///
/// Two geometry buffers are filled per frame — one of instanced strokes (which
/// also carry markers) and one of plain triangles for region fills — plus an
/// ordered list of draw ranges so the layer stacking order of the scene
/// survives all the way to the draw calls.
public final class Renderer2D {
    private let device: MTLDevice
    private let strokePipeline: MTLRenderPipelineState
    private let fillPipeline: MTLRenderPipelineState
    private let pool: GeometryPool

    private var instances: [LineInstance] = []
    private var vertices: [FillVertex] = []

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
        self.pool = GeometryPool(device: context.device)
    }

    /// Encodes `scene` into an already started render pass.
    public func encode(
        scene: Scene2D,
        commandBuffer: MTLCommandBuffer,
        descriptor: MTLRenderPassDescriptor,
        viewportSize: SIMD2<Double>
    ) {
        guard viewportSize.x > 0, viewportSize.y > 0 else { return }
        let viewport = SIMD2<Float>(Float(viewportSize.x), Float(viewportSize.y))

        instances.removeAll(keepingCapacity: true)
        vertices.removeAll(keepingCapacity: true)
        var ranges: [DrawRange] = []
        ranges.reserveCapacity(scene.commands.count)

        for command in scene.commands {
            switch command {
            case .polyline(let polyline):
                let start = instances.count
                append(polyline, viewport: viewport)
                if instances.count > start {
                    ranges.append(.lines(instanceOffset: start, instanceCount: instances.count - start))
                }

            case .rects(let batch):
                let start = vertices.count
                append(batch, viewport: viewport)
                if vertices.count > start {
                    ranges.append(.triangles(vertexOffset: start, vertexCount: vertices.count - start))
                }

            case .markers(let batch):
                let start = instances.count
                append(batch, viewport: viewport)
                if instances.count > start {
                    ranges.append(.lines(instanceOffset: start, instanceCount: instances.count - start))
                }
            }
        }

        // The pool rotates so that the CPU never overwrites geometry the GPU may
        // still be reading from an earlier in-flight frame.
        let slot = pool.advance()

        var strokeBuffer: MTLBuffer?
        if !instances.isEmpty {
            let bytes = instances.count * MemoryLayout<LineInstance>.stride
            strokeBuffer = pool.strokeBuffer(slot: slot, bytes: bytes)
            guard let buffer = strokeBuffer else { return }
            instances.withUnsafeBytes { source in
                guard let base = source.baseAddress else { return }
                memcpy(buffer.contents(), base, source.count)
            }
        }

        var fillBuffer: MTLBuffer?
        if !vertices.isEmpty {
            let bytes = vertices.count * MemoryLayout<FillVertex>.stride
            fillBuffer = pool.fillBuffer(slot: slot, bytes: bytes)
            guard let buffer = fillBuffer else { return }
            vertices.withUnsafeBytes { source in
                guard let base = source.baseAddress else { return }
                memcpy(buffer.contents(), base, source.count)
            }
        }

        // Even an empty scene goes through a pass so that the clear still lands.
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        var uniforms = Uniforms(viewportSize: viewport)
        for range in ranges {
            switch range {
            case .lines(let offset, let count):
                guard let buffer = strokeBuffer else { continue }
                encoder.setRenderPipelineState(strokePipeline)
                encoder.setVertexBuffer(
                    buffer,
                    offset: offset * MemoryLayout<LineInstance>.stride,
                    index: 0
                )
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawPrimitives(
                    type: .triangleStrip,
                    vertexStart: 0,
                    vertexCount: 4,
                    instanceCount: count
                )

            case .triangles(let offset, let count):
                guard let buffer = fillBuffer else { continue }
                encoder.setRenderPipelineState(fillPipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: offset, vertexCount: count)
            }
        }
        encoder.endEncoding()
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

    private func append(_ polyline: PolylinePrimitive, viewport: SIMD2<Float>) {
        let points = polyline.points
        guard points.count >= 2 else { return }
        let halfWidth = max(polyline.width, 0) / 2
        let color = Self.vector(polyline.color)

        let segmentCount = polyline.isClosed ? points.count : points.count - 1
        for i in 0..<segmentCount {
            appendSegment(
                from: points[i],
                to: points[(i + 1) % points.count],
                halfWidth: halfWidth,
                color: color,
                viewport: viewport
            )
        }
    }

    private func append(_ batch: RectPrimitiveBatch, viewport: SIMD2<Float>) {
        let count = min(batch.geometry.count, batch.coverage.count)
        guard count > 0 else { return }
        let base = batch.color
        for i in 0..<count {
            let rect = batch.geometry[i]
            let x0 = rect.x, x1 = rect.y, y0 = rect.z, y1 = rect.w
            guard x1 > x0, y1 > y0 else { continue }
            guard x1 > 0, x0 < viewport.x, y1 > 0, y0 < viewport.y else { continue }

            let coverage = min(max(Double(batch.coverage[i]), 0), 1)
            let alpha = Float(base.a * coverage)
            guard alpha > 0 else { continue }
            let color = SIMD4<Float>(Float(base.r), Float(base.g), Float(base.b), alpha)

            // Half-open [x0, x1) x [y0, y1): pixel centres inside the bounds are
            // covered, which is exactly the area the CPU coverage accounted for.
            let topLeft = FillVertex(position: SIMD2(x0, y0), color: color)
            let topRight = FillVertex(position: SIMD2(x1, y0), color: color)
            let bottomLeft = FillVertex(position: SIMD2(x0, y1), color: color)
            let bottomRight = FillVertex(position: SIMD2(x1, y1), color: color)
            vertices.append(topLeft)
            vertices.append(topRight)
            vertices.append(bottomLeft)
            vertices.append(bottomLeft)
            vertices.append(topRight)
            vertices.append(bottomRight)
        }
    }

    private func append(_ batch: MarkerPrimitiveBatch, viewport: SIMD2<Float>) {
        guard !batch.positions.isEmpty else { return }
        let radius = max(batch.radius, 0)
        let color = Self.vector(batch.color)
        for position in batch.positions {
            appendSegment(from: position, to: position, halfWidth: radius, color: color, viewport: viewport)
        }
    }

    /// A degenerate segment is the marker case: the shader falls back to a point
    /// distance, which produces a disc without ever taking a square root of zero
    /// length or a division by it.
    private func appendSegment(
        from a: SIMD2<Double>,
        to b: SIMD2<Double>,
        halfWidth: Double,
        color: SIMD4<Float>,
        viewport: SIMD2<Float>
    ) {
        let extend = Float(halfWidth + 0.5)
        let minX = Float(min(a.x, b.x)) - extend
        let maxX = Float(max(a.x, b.x)) + extend
        let minY = Float(min(a.y, b.y)) - extend
        let maxY = Float(max(a.y, b.y)) + extend
        if maxX < 0 || minX > viewport.x || maxY < 0 || minY > viewport.y { return }

        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        let tangent = length > 1e-12
            ? SIMD2<Float>(Float(dx / length), Float(dy / length))
            : SIMD2<Float>(1, 0)

        instances.append(LineInstance(
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

/// Must match `FillVertex` in the Metal source.
private struct FillVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

/// Must match `Uniforms` in the Metal source.
private struct Uniforms {
    var viewportSize: SIMD2<Float>
}

private enum DrawRange {
    case lines(instanceOffset: Int, instanceCount: Int)
    case triangles(vertexOffset: Int, vertexCount: Int)
}

/// Keeps the CPU from writing into geometry an in-flight command buffer may
/// still be reading.
private final class GeometryPool {
    private let device: MTLDevice
    private let slotCount: Int
    private var slot = 0
    private var strokeBuffers: [MTLBuffer?]
    private var fillBuffers: [MTLBuffer?]

    init(device: MTLDevice, slotCount: Int = 3) {
        self.device = device
        self.slotCount = slotCount
        self.strokeBuffers = Array(repeating: nil, count: slotCount)
        self.fillBuffers = Array(repeating: nil, count: slotCount)
    }

    func advance() -> Int {
        let current = slot
        slot = (slot + 1) % slotCount
        return current
    }

    func strokeBuffer(slot: Int, bytes: Int) -> MTLBuffer? {
        allocate(into: &strokeBuffers, slot: slot, bytes: bytes, label: "stroke")
    }

    func fillBuffer(slot: Int, bytes: Int) -> MTLBuffer? {
        allocate(into: &fillBuffers, slot: slot, bytes: bytes, label: "fill")
    }

    private func allocate(into buffers: inout [MTLBuffer?], slot: Int, bytes: Int, label: String) -> MTLBuffer? {
        if let existing = buffers[slot], existing.length >= bytes { return existing }

        var capacity = max(buffers[slot]?.length ?? 0, 16 * 1024)
        while capacity < bytes { capacity *= 2 }
        guard let buffer = device.makeBuffer(length: capacity, options: .storageModeShared) else { return nil }
        buffer.label = "GrapherRender.\(label)"
        buffers[slot] = buffer
        return buffer
    }
}
