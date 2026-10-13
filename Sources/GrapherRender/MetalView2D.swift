import Foundation
import GrapherKit
import Metal
import MetalKit
import QuartzCore

/// Interactive view. Geometry is prepared off the main thread and then handed
/// over; the view re-renders on demand rather than continuously.
///
/// 两层：底下是网格与坐标轴（`chrome`，几何就是当前屏幕像素，每帧由调用方按当前视口现画），
/// 上面是曲线（`setContent` 交来的几何，属于它自己的那个视口，画的时候按 `viewport` 与它之差
/// 换算到当前屏幕）。拖动、缩放时只改 `viewport` 和 `chrome`，不等后台重新采样。
///
/// **重绘跟屏幕刷新走，不跟事件走**：改了什么只调 `requestFrame()`，真正的绘制在显示链接
/// 回调里做，每次刷新最多一帧、用的是那一刻最新的状态。早先每个鼠标事件都画一帧，事件比
/// 屏幕刷新快时（120Hz 鼠标配 60Hz 外接屏）多出来的帧在显示队列里排队，画面落后光标两三帧。
/// 同理用 `presentsWithTransaction`：Metal 这一帧和调用方在 `onFrame` 里挪的叠加层图层
/// （刻度文字）同一个事务上屏，数字与网格线不会错开一帧。
public final class MetalView2D: MTKView, MTKViewDelegate {
    /// 清屏色（主题底色）。
    public var background: RGBAColor = .white {
        didSet { if background != oldValue { requestFrame() } }
    }

    /// 网格与坐标轴，几何是当前屏幕像素。
    public var chrome: Scene2D? {
        didSet {
            preparedChrome = chrome.flatMap { renderer?.prepare($0) }
            requestFrame()
        }
    }

    /// 当前视口：曲线层按它与曲线几何所属视口之差摆到屏幕上。
    public var viewport = Viewport2D() {
        didSet { if viewport != oldValue { requestFrame() } }
    }

    /// 每帧绘制之前在主线程调用：调用方在这里把 `chrome`、`viewport` 和叠加层更新到最新。
    public var onFrame: (() -> Void)?

    private let context: MetalContext
    private let renderer: Renderer2D?
    private var preparedChrome: PreparedScene2D?
    private var preparedContent: (scene: PreparedScene2D, viewport: Viewport2D)?
    private var contentGeneration = 0
    private let prepareQueue = DispatchQueue(label: "tech.xvanturing.GrapherNG.prepare", qos: .userInitiated)
    private var frameLink: CADisplayLink?
    private var needsFrame = false

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
        // 既不连续跑也不跟 `needsDisplay`：只在显示链接回调里按需 `draw()`。
        isPaused = true
        enableSetNeedsDisplay = false
        presentsWithTransaction = true
        clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("MetalView2D does not support decoding")
    }

    /// 换上一份新算好的曲线几何。`viewport` 是它所在的像素空间（`BuiltScene.viewport`），
    /// 落在这个范围之外的几何上传时就丢掉。上传在后台做，好了再在下一帧换上——在那之前
    /// 继续画旧的那份（它带着自己的视口，照样摆得对）。
    public func setContent(_ scene: Scene2D?, viewport source: Viewport2D) {
        contentGeneration += 1
        let generation = contentGeneration
        guard let scene, let renderer else {
            preparedContent = nil
            requestFrame()
            return
        }
        let size = SIMD2(source.widthPixels, source.heightPixels)
        prepareQueue.async { [weak self] in
            let prepared = renderer.prepare(scene, cullSize: size)
            DispatchQueue.main.async {
                guard let self, generation == self.contentGeneration else { return }
                self.preparedContent = (prepared, source)
                self.requestFrame()
            }
        }
    }

    /// 要求在下一次屏幕刷新时画一帧。一帧之内调多少次都只画一次。
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
        // `.common` 才能在窗口缩放、菜单展开这类跟踪循环里照常出帧。
        link.add(to: .main, forMode: .common)
        link.isPaused = !needsFrame
        frameLink = link
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        guard needsFrame else {
            link.isPaused = true
            return
        }
        // 先让调用方更新，再清标记：`onFrame` 里给 `viewport`、`chrome` 赋值会顺手
        // 再要一帧，那是这一帧本来就要画的东西，不该多画一次。
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
            red: background.r,
            green: background.g,
            blue: background.b,
            alpha: background.a
        )

        var passes: [Renderer2D.Pass] = []
        if let preparedChrome { passes.append(Renderer2D.Pass(scene: preparedChrome)) }
        if let preparedContent {
            passes.append(Renderer2D.Pass(
                scene: preparedContent.scene,
                transform: viewport.screenTransform(from: preparedContent.viewport)
            ))
        }

        renderer.encode(
            passes,
            commandBuffer: commandBuffer,
            descriptor: descriptor,
            viewportSize: SIMD2(
                Double(drawable.texture.width),
                Double(drawable.texture.height)
            )
        )
        // `presentsWithTransaction`：等命令排上 GPU，再在当前事务里上屏。
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
        drawable.present()
    }
}
