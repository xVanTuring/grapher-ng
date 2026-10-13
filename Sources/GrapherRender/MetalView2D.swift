import Foundation
import GrapherKit
import Metal
import MetalKit

/// Interactive view. Geometry is prepared off the main thread and then handed
/// over; the view re-renders on demand rather than on a display link.
public final class MetalView2D: MTKView, MTKViewDelegate {
    /// Data prepared elsewhere; assigning it schedules a redraw.
    public var scene: Scene2D? {
        didSet { needsDisplay = true }
    }

    /// When true the pass clears to `scene.background` instead of `clearColor`.
    public var useSceneBackground: Bool = true

    private let context: MetalContext
    private let renderer: Renderer2D?

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

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsDisplay = true
    }

    public func draw(in view: MTKView) {
        guard let renderer,
              let scene,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = context.queue.makeCommandBuffer()
        else { return }

        if useSceneBackground {
            descriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: scene.background.r,
                green: scene.background.g,
                blue: scene.background.b,
                alpha: scene.background.a
            )
        }

        renderer.encode(
            scene: scene,
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
