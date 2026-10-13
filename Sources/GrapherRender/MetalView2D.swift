import Foundation
import GrapherKit
import Metal
import MetalKit

/// Interactive view. Geometry is prepared off the main thread and then handed
/// over; the view re-renders on demand rather than on a display link.
///
/// 两层：底下是网格与坐标轴（`chrome`，几何就是当前屏幕像素，每次视口变化由调用方现画），
/// 上面是曲线（`content`，后台按某个视口算好的几何，经 `contentTransform` 摆到当前屏幕）。
/// 拖动、缩放时只改 `contentTransform` 和 `chrome`，一帧之内就跟上，不等后台重新采样；
/// 两层都只在换几何时上传一次显存，重画只花一份 uniforms。
public final class MetalView2D: MTKView, MTKViewDelegate {
    /// 清屏色（主题底色）。
    public var background: RGBAColor = .white {
        didSet { if background != oldValue { needsDisplay = true } }
    }

    /// 网格与坐标轴，几何是当前屏幕像素。
    public var chrome: Scene2D? {
        didSet {
            preparedChrome = chrome.flatMap { renderer?.prepare($0) }
            needsDisplay = true
        }
    }

    /// 曲线层几何所在像素空间到当前屏幕的变换。
    public var contentTransform: ScreenTransform2D = .identity {
        didSet { if contentTransform != oldValue { needsDisplay = true } }
    }

    private let context: MetalContext
    private let renderer: Renderer2D?
    private var preparedChrome: PreparedScene2D?
    private var preparedContent: PreparedScene2D?

    public init?(frame: CGRect, context: MetalContext) {
        self.context = context
        self.renderer = Renderer2D(context: context)
        super.init(frame: frame, device: context.device)
        guard renderer != nil else { return nil }

        colorPixelFormat = MetalContext.colorFormat
        // MTKView defaults to a 4-sample drawable; the coverage maths already
        // anti-aliases, and MSAA on top of it would only blur the edges.
        sampleCount = MetalContext.sampleCount
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("MetalView2D does not support decoding")
    }

    /// 换上一份新算好的曲线几何。`size` 是它所在像素空间的尺寸（`BuiltScene.viewport`），
    /// 落在这个范围之外的几何上传时就丢掉。
    public func setContent(_ scene: Scene2D?, size: SIMD2<Double>, transform: ScreenTransform2D) {
        preparedContent = scene.flatMap { renderer?.prepare($0, cullSize: size) }
        contentTransform = transform
        needsDisplay = true
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsDisplay = true
    }

    public func draw(in view: MTKView) {
        guard let renderer,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = context.queue.makeCommandBuffer()
        else { return }

        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: background.r,
            green: background.g,
            blue: background.b,
            alpha: background.a
        )

        var passes: [Renderer2D.Pass] = []
        if let preparedChrome { passes.append(Renderer2D.Pass(scene: preparedChrome)) }
        if let preparedContent { passes.append(Renderer2D.Pass(scene: preparedContent, transform: contentTransform)) }

        renderer.encode(
            passes,
            commandBuffer: commandBuffer,
            descriptor: descriptor,
            viewportSize: SIMD2(
                Double(drawable.texture.width),
                Double(drawable.texture.height)
            )
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
