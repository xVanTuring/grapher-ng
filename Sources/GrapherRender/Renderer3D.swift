import Foundation
import GrapherKit
import Metal
import simd

/// 3D 画布的渲染：曲面（不透明、写深度）+ 线（空间曲线、盒子棱线与盒壁网格；半透明叠加、只测深度）。
///
/// 和 2D 一样，场景只在换几何时上传一次显存（`prepare` → `PreparedScene3D`），重画只换 uniforms：
/// 旋转只改投影矩阵，平移、缩放时旧几何经 `boxTransform` 换到新盒子里，不等后台重采。
///
/// 抗锯齿：曲面的边缘靠 4× MSAA（三角形边缘没法像 2D 那样解析地算覆盖率），线照旧按像素距离算覆盖率。
/// 所以 3D 的 `sampleCount` 是 4，与 2D 必须为 1 的那条规矩互不相干。
public final class Renderer3D {
    public static let sampleCount = 4
    public static let depthFormat: MTLPixelFormat = .depth32Float

    private let device: MTLDevice
    private let meshPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let meshDepth: MTLDepthStencilState
    private let lineDepth: MTLDepthStencilState

    public init?(context: MetalContext) {
        let device = context.device
        guard let meshPipeline = Self.makePipeline(device: device, library: context.library,
                                                   vertex: "mesh3d_vertex", fragment: "mesh3d_fragment", blends: false),
              let linePipeline = Self.makePipeline(device: device, library: context.library,
                                                   vertex: "line3d_vertex", fragment: "line3d_fragment", blends: true)
        else { return nil }

        let meshDescriptor = MTLDepthStencilDescriptor()
        meshDescriptor.depthCompareFunction = .less
        meshDescriptor.isDepthWriteEnabled = true
        let lineDescriptor = MTLDepthStencilDescriptor()
        lineDescriptor.depthCompareFunction = .lessEqual
        lineDescriptor.isDepthWriteEnabled = false
        guard let meshDepth = device.makeDepthStencilState(descriptor: meshDescriptor),
              let lineDepth = device.makeDepthStencilState(descriptor: lineDescriptor)
        else { return nil }

        self.device = device
        self.meshPipeline = meshPipeline
        self.linePipeline = linePipeline
        self.meshDepth = meshDepth
        self.lineDepth = lineDepth
    }

    /// 一份已上传的几何，加上它属于哪个坐标盒、要不要按盒子裁剪。
    public struct Pass {
        public var scene: PreparedScene3D
        /// 几何归一化时依据的视图（只看盒子）。
        public var source: View3D
        /// 曲线与曲面按坐标盒裁剪；盒子自己的棱线、盒壁网格不裁。
        public var clipToBox: Bool

        public init(scene: PreparedScene3D, source: View3D, clipToBox: Bool) {
            self.scene = scene
            self.source = source
            self.clipToBox = clipToBox
        }
    }

    /// 上传一份场景。结果不可变，任意多帧都能同时读。
    public func prepare(_ scene: Scene3D) -> PreparedScene3D {
        var batches: [PreparedScene3D.MeshBatch] = []
        for mesh in scene.meshes where mesh.triangleCount > 0 {
            guard let vertices = makeBuffer(mesh.vertices, label: "mesh3d.vertices"),
                  let indices = makeBuffer(mesh.indices, label: "mesh3d.indices")
            else { continue }
            batches.append(PreparedScene3D.MeshBatch(
                vertices: vertices,
                indices: indices,
                indexCount: mesh.indices.count,
                color: Self.vector(mesh.color)
            ))
        }

        var instances: [LineInstance3D] = []
        for polyline in scene.polylines where polyline.points.count >= 2 {
            let color = Self.vector(polyline.color)
            let halfWidth = Float(max(polyline.width, 0) / 2)
            instances.reserveCapacity(instances.count + polyline.points.count - 1)
            for (a, b) in zip(polyline.points, polyline.points.dropFirst()) {
                instances.append(LineInstance3D(a: a, b: b, color: color, halfWidth: halfWidth))
            }
        }

        return PreparedScene3D(
            meshes: batches,
            lines: makeBuffer(instances, label: "line3d"),
            lineCount: instances.count
        )
    }

    /// 把若干份几何编进一个渲染通道：先画所有曲面（写深度），再画所有线（只测深度、半透明叠加），
    /// 线才能被挡在曲面后面、又能盖在曲面前面。
    public func encode(
        _ passes: [Pass],
        view: View3D,
        encoder: MTLRenderCommandEncoder,
        viewportSize: SIMD2<Double>
    ) {
        guard viewportSize.x > 0, viewportSize.y > 0 else { return }
        let viewProjection = Self.floatMatrix(view.viewProjection())
        let eye = SIMD4<Float>(SIMD3<Float>(view.eye), 1)
        func uniforms(for pass: Pass) -> Uniforms3D {
            let (scale, translation) = view.boxTransform(from: pass.source)
            return Uniforms3D(
                viewProjection: viewProjection,
                boxTransform: SIMD4<Float>(SIMD3<Float>(translation), Float(scale)),
                eye: eye,
                viewportSize: SIMD2<Float>(Float(viewportSize.x), Float(viewportSize.y)),
                clipToBox: pass.clipToBox ? 1 : 0,
                pad: 0
            )
        }

        encoder.setCullMode(.none)
        encoder.setRenderPipelineState(meshPipeline)
        encoder.setDepthStencilState(meshDepth)
        for pass in passes where !pass.scene.meshes.isEmpty {
            var u = uniforms(for: pass)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms3D>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms3D>.stride, index: 1)
            for batch in pass.scene.meshes {
                var style = MeshStyle3D(color: batch.color)
                encoder.setVertexBuffer(batch.vertices, offset: 0, index: 0)
                encoder.setFragmentBytes(&style, length: MemoryLayout<MeshStyle3D>.stride, index: 0)
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: batch.indexCount,
                    indexType: .uint32,
                    indexBuffer: batch.indices,
                    indexBufferOffset: 0
                )
            }
        }

        encoder.setRenderPipelineState(linePipeline)
        encoder.setDepthStencilState(lineDepth)
        for pass in passes {
            guard let lines = pass.scene.lines, pass.scene.lineCount > 0 else { continue }
            var u = uniforms(for: pass)
            encoder.setVertexBuffer(lines, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms3D>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: pass.scene.lineCount)
        }
    }

    // MARK: - Helpers

    private func makeBuffer<T>(_ items: [T], label: String) -> MTLBuffer? {
        guard !items.isEmpty else { return nil }
        let buffer = items.withUnsafeBytes { bytes -> MTLBuffer? in
            guard let base = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }
        buffer?.label = "GrapherRender.\(label)"
        return buffer
    }

    private static func vector(_ color: RGBAColor) -> SIMD4<Float> {
        SIMD4<Float>(Float(color.r), Float(color.g), Float(color.b), Float(color.a))
    }

    static func floatMatrix(_ m: simd_double4x4) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1),
            SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3)
        ))
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertex: String,
        fragment: String,
        blends: Bool
    ) -> MTLRenderPipelineState? {
        guard let vertexFunction = library.makeFunction(name: vertex),
              let fragmentFunction = library.makeFunction(name: fragment)
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = vertex
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = sampleCount
        descriptor.depthAttachmentPixelFormat = depthFormat
        guard let attachment = descriptor.colorAttachments[0] else { return nil }
        attachment.pixelFormat = MetalContext.colorFormat
        if blends {
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}

/// 已上传的 3D 几何，不可变。
public final class PreparedScene3D {
    struct MeshBatch {
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let indexCount: Int
        let color: SIMD4<Float>
    }

    let meshes: [MeshBatch]
    let lines: MTLBuffer?
    let lineCount: Int

    init(meshes: [MeshBatch], lines: MTLBuffer?, lineCount: Int) {
        self.meshes = meshes
        self.lines = lines
        self.lineCount = lineCount
    }

    public var triangleCount: Int { meshes.reduce(0) { $0 + $1.indexCount / 3 } }
    public var isEmpty: Bool { meshes.isEmpty && lineCount == 0 }
}

// MARK: - Buffer layout（与 ShaderSource3D 逐字段对应）

struct Uniforms3D {
    var viewProjection: simd_float4x4
    var boxTransform: SIMD4<Float>
    var eye: SIMD4<Float>
    var viewportSize: SIMD2<Float>
    var clipToBox: Float
    var pad: Float
}

struct MeshStyle3D {
    var color: SIMD4<Float>
}

struct LineInstance3D {
    var a: SIMD3<Float>
    var b: SIMD3<Float>
    var color: SIMD4<Float>
    var halfWidth: Float
}
