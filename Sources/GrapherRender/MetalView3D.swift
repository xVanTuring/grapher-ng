import Foundation
import GrapherKit
import Metal
import MetalKit
import QuartzCore

/// 3D 画布。结构与 `MetalView2D` 一致：
///
/// - 两层几何：盒子的棱线与盒壁网格（`chrome`，按当前盒子归一化，不裁剪），曲面与曲线（`setContent`，
///   按它自己采样时的盒子归一化，画的时候换到当前盒子并按盒子裁剪）。
/// - 旋转只改 `viewport`（投影矩阵），平移缩放时旧几何经盒子变换摆到新位置，不等后台重采。
/// - 重绘跟屏幕刷新走（显示链接），每次刷新最多一帧；`presentsWithTransaction` 让这一帧与叠加层的
///   刻度文字同一个事务上屏。
/// - 4× MSAA + 深度缓冲（曲面边缘靠 MSAA，线靠解析覆盖率）。
public final class MetalView3D: MTKView, MTKViewDelegate {
    public var background: RGBAColor = .white {
        didSet { if background != oldValue { requestFrame() } }
    }

    /// 当前视图（相机与盒子）。
    public var viewport = View3D.standard {
        didSet { if viewport != oldValue { requestFrame() } }
    }

    /// 盒子棱线与盒壁网格，按 `viewport` 的盒子归一化。
    public var chrome: Scene3D? {
        didSet {
            preparedChrome = chrome.flatMap { renderer?.prepare($0) }
            requestFrame()
        }
    }

    /// 每帧绘制之前在主线程调用：调用方在这里把 `viewport`、`chrome` 和叠加层更新到最新。
    public var onFrame: (() -> Void)?

    private let context: MetalContext
    private let renderer: Renderer3D?
    private var preparedChrome: PreparedScene3D?
    private var preparedContent: (scene: PreparedScene3D, view: View3D)?
    private var contentGeneration = 0
    private let prepareQueue = DispatchQueue(label: "tech.xvanturing.GrapherNG.prepare3d", qos: .userInitiated)
    private var frameLink: CADisplayLink?
    private var needsFrame = false

    public init?(frame: CGRect, context: MetalContext) {
        self.context = context
        self.renderer = Renderer3D(context: context)
        super.init(frame: frame, device: context.device)
        guard renderer != nil else { return nil }

        colorPixelFormat = MetalContext.colorFormat
        depthStencilPixelFormat = Renderer3D.depthFormat
        sampleCount = Renderer3D.sampleCount
        clearDepth = 1
        isPaused = true
        enableSetNeedsDisplay = false
        presentsWithTransaction = true
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("MetalView3D does not support decoding")
    }

    /// 换上一份新算好的几何（后台上传显存，好了下一帧换上；在那之前继续画旧的）。
    public func setContent(_ scene: Scene3D?, view source: View3D) {
        contentGeneration += 1
        let generation = contentGeneration
        guard let scene, let renderer else {
            preparedContent = nil
            requestFrame()
            return
        }
        prepareQueue.async { [weak self] in
            let prepared = renderer.prepare(scene)
            DispatchQueue.main.async {
                guard let self, generation == self.contentGeneration else { return }
                self.preparedContent = (prepared, source)
                self.requestFrame()
            }
        }
    }

    public func requestFrame() {
        needsFrame = true
        if let frameLink {
            frameLink.isPaused = false
        } else if window != nil {
            installFrameLink()
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        frameLink?.invalidate()
        frameLink = nil
        if window != nil {
            installFrameLink()
            needsFrame = true
        }
    }

    private func installFrameLink() {
        let link = displayLink(target: self, selector: #selector(frameTick(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = !needsFrame
        frameLink = link
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        guard needsFrame else {
            link.isPaused = true
            return
        }
        onFrame?()
        needsFrame = false
        draw()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        requestFrame()
    }

    public func draw(in view: MTKView) {
        guard let renderer,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = context.queue.makeCommandBuffer()
        else { return }

        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: background.r, green: background.g, blue: background.b, alpha: background.a)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        var passes: [Renderer3D.Pass] = []
        if let preparedChrome {
            passes.append(Renderer3D.Pass(scene: preparedChrome, source: viewport, clipToBox: false))
        }
        if let preparedContent {
            passes.append(Renderer3D.Pass(scene: preparedContent.scene, source: preparedContent.view, clipToBox: true))
        }
        renderer.encode(
            passes,
            view: viewport,
            encoder: encoder,
            viewportSize: SIMD2(Double(drawable.texture.width), Double(drawable.texture.height))
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
        drawable.present()
    }
}
