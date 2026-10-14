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
    private let glassPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let meshDepth: MTLDepthStencilState
    private let lineDepth: MTLDepthStencilState

    /// 选中高亮的颜色（曲面往它偏、曲线外面加一圈它的光晕）。
    static let highlightColor = SIMD3<Float>(1.0, 0.58, 0.05)

    public init?(context: MetalContext) {
        let device = context.device
        guard let meshPipeline = Self.makePipeline(device: device, library: context.library,
                                                   vertex: "mesh3d_vertex", fragment: "mesh3d_fragment", blends: false),
              let glassPipeline = Self.makePipeline(device: device, library: context.library,
                                                    vertex: "mesh3d_vertex", fragment: "mesh3d_fragment", blends: true),
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
        self.glassPipeline = glassPipeline
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
                color: Self.vector(mesh.color),
                layerID: mesh.layerID,
                isTranslucent: mesh.isTranslucent,
                colorsByScalar: mesh.colorsByScalar
            ))
        }

        var instances: [LineInstance3D] = []
        var ranges: [PreparedScene3D.LineRange] = []
        for polyline in scene.polylines where polyline.points.count >= 2 {
            let color = Self.vector(polyline.color)
            let halfWidth = Float(max(polyline.width, 0) / 2)
            let start = instances.count
            instances.reserveCapacity(instances.count + polyline.points.count - 1)
            for (a, b) in zip(polyline.points, polyline.points.dropFirst()) {
                instances.append(LineInstance3D(a: a, b: b, color: color, halfWidth: halfWidth))
            }
            if let id = polyline.layerID {
                ranges.append(PreparedScene3D.LineRange(layerID: id, start: start, count: instances.count - start))
            }
        }

        return PreparedScene3D(
            meshes: batches,
            lines: makeBuffer(instances, label: "line3d"),
            lineCount: instances.count,
            lineRanges: ranges
        )
    }

    /// 把若干份几何编进一个渲染通道：先画不透明曲面（写深度），再画半透明曲面（只测深度、不写，两面都画），
    /// 最后画所有线（只测深度、半透明叠加），线才能被挡在曲面后面、又能盖在曲面前面。
    /// `highlight` 是选中的图层：它的曲面往高亮色偏、半透明的更实一些，曲线外面加一圈光晕。
    public func encode(
        _ passes: [Pass],
        view: View3D,
        encoder: MTLRenderCommandEncoder,
        viewportSize: SIMD2<Double>,
        highlight: UUID? = nil
    ) {
        guard viewportSize.x > 0, viewportSize.y > 0 else { return }
        let viewProjection = Self.floatMatrix(view.viewProjection())
        let eye = SIMD4<Float>(SIMD3<Float>(view.eye), 1)
        func uniforms(for pass: Pass, lineBoost: Float = 0, tint: SIMD4<Float> = .zero, alphaScale: Float = 1) -> Uniforms3D {
            let (scale, translation) = view.boxTransform(from: pass.source)
            return Uniforms3D(
                viewProjection: viewProjection,
                boxTransform: SIMD4<Float>(SIMD3<Float>(translation), Float(scale)),
                eye: eye,
                viewportSize: SIMD2<Float>(Float(viewportSize.x), Float(viewportSize.y)),
                clipToBox: pass.clipToBox ? 1 : 0,
                lineBoost: lineBoost,
                tint: tint,
                alphaScale: alphaScale
            )
        }

        func drawMeshes(translucent: Bool) {
            encoder.setRenderPipelineState(translucent ? glassPipeline : meshPipeline)
            encoder.setDepthStencilState(translucent ? lineDepth : meshDepth)
            for pass in passes {
                let batches = pass.scene.meshes.filter { $0.isTranslucent == translucent }
                guard !batches.isEmpty else { continue }
                var u = uniforms(for: pass)
                encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms3D>.stride, index: 1)
                encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms3D>.stride, index: 1)
                for batch in batches {
                    var style = MeshStyle3D(
                        color: batch.color,
                        highlight: batch.layerID != nil && batch.layerID == highlight ? 1 : 0,
                        colorMode: batch.colorsByScalar ? 1 : 0)
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
        }

        encoder.setCullMode(.none)
        drawMeshes(translucent: false)
        drawMeshes(translucent: true)

        encoder.setRenderPipelineState(linePipeline)
        encoder.setDepthStencilState(lineDepth)
        // 选中图层的曲线：先画一圈宽的半透明光晕，再画本体盖在上面。
        if let highlight {
            for pass in passes {
                guard let lines = pass.scene.lines else { continue }
                var halo = uniforms(for: pass, lineBoost: 3.5, tint: SIMD4(Self.highlightColor, 1), alphaScale: 0.45)
                encoder.setVertexBuffer(lines, offset: 0, index: 0)
                encoder.setVertexBytes(&halo, length: MemoryLayout<Uniforms3D>.stride, index: 1)
                for range in pass.scene.lineRanges where range.layerID == highlight {
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                           instanceCount: range.count, baseInstance: range.start)
                }
            }
        }
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
        let layerID: UUID?
        let isTranslucent: Bool
        let colorsByScalar: Bool
    }

    /// 某个图层的曲线在线段实例缓冲里占的那一段（画高亮光晕用）。
    struct LineRange {
        let layerID: UUID
        let start: Int
        let count: Int
    }

    let meshes: [MeshBatch]
    let lines: MTLBuffer?
    let lineCount: Int
    let lineRanges: [LineRange]

    init(meshes: [MeshBatch], lines: MTLBuffer?, lineCount: Int, lineRanges: [LineRange]) {
        self.meshes = meshes
        self.lines = lines
        self.lineCount = lineCount
        self.lineRanges = lineRanges
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
    /// 线的半宽再加多少像素（高亮光晕用）。
    var lineBoost: Float
    /// 线的颜色往 `tint.rgb` 偏多少（`tint.a`）。
    var tint: SIMD4<Float>
    /// 线的不透明度乘数。
    var alphaScale: Float
}

struct MeshStyle3D {
    var color: SIMD4<Float>
    /// 1 = 选中：往高亮色偏。
    var highlight: Float
    /// 1 = 颜色由顶点的 scalar 查色带，`color` 只提供不透明度。
    var colorMode: Float
}

struct LineInstance3D {
    var a: SIMD3<Float>
    var b: SIMD3<Float>
    var color: SIMD4<Float>
    var halfWidth: Float
}
