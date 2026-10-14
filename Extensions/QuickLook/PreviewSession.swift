import Foundation
import GrapherKit
import GrapherRender

/// 预览里的一份只读文档：当前视口 / 视角，以及后台采样出来的几何。只能看、不能改。
///
/// 采样的节奏照搬 App（`AppState`）：同一时刻只跑一份，跑着时来的请求只记「还要再算、什么画质」，
/// 跑完按那一刻的视口再起一份；拖动、缩放时先出交互画质，停手 200ms 再补精细的。
@MainActor
final class PreviewSession {
    let document: GrapherDocument
    var isSpace: Bool { document.dimension == .space }

    /// 平面图的当前视口（像素口径，没有遮挡）。
    private(set) var viewport: Viewport2D
    /// 立体图的当前视角。
    private(set) var view3D: View3D
    private(set) var built: BuiltScene?
    private(set) var built3D: BuiltScene3D?
    private(set) var backingScale: Double = 2

    /// 视口、视角变了：画布在下一次屏幕刷新时跟上。
    var onViewChange: (() -> Void)?
    /// 新几何算好了：画布换上。
    var onSceneChange: (() -> Void)?

    private let compiled: [LayerCompiler.CompiledLayer]
    private var hasSize = false
    private var buildInFlight = false
    private var pendingQuality: SampleQuality?
    private var settleTask: Task<Void, Never>?

    init(document: GrapherDocument) {
        self.document = document
        // 文档在预览里不会变，公式只编译一次。
        compiled = LayerCompiler().compile(document)
        viewport = document.viewport
        view3D = document.view3D
    }

    // MARK: - 画布尺寸

    /// 画布尺寸（像素）变了。第一次按文档存下时的取景（`GraphSnapshot`），之后只改尺寸、不动中心与倍率。
    func setCanvasSize(pixelWidth: Double, pixelHeight: Double, backingScale scale: Double) {
        guard pixelWidth > 1, pixelHeight > 1, scale > 0 else { return }
        let scaleChanged = scale != backingScale
        backingScale = scale
        if !hasSize {
            hasSize = true
            resetView(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            return
        }
        guard pixelWidth != viewport.widthPixels || pixelHeight != viewport.heightPixels || scaleChanged else { return }
        viewport.widthPixels = pixelWidth
        viewport.heightPixels = pixelHeight
        view3D.widthPixels = pixelWidth
        view3D.heightPixels = pixelHeight
        onViewChange?()
        // 立体图换画布尺寸只改投影，坐标盒没变，不用重采（线宽随倍率变时才要）。
        if !isSpace || scaleChanged { requestInteractiveBuild() }
    }

    /// 回到文档存下时的取景（双击）。
    func resetView() {
        resetView(pixelWidth: viewport.widthPixels, pixelHeight: viewport.heightPixels)
    }

    private func resetView(pixelWidth: Double, pixelHeight: Double) {
        viewport = GraphSnapshot.planeViewport(of: document, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        view3D = GraphSnapshot.spaceView(of: document, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        onViewChange?()
        requestBuild(quality: .full)
    }

    // MARK: - 手势

    /// `anchor` 是指针位置（像素，左上角原点，同 `Viewport2D.zoom(by:anchorPixel:)`），平面图缩放用。
    func apply(_ action: CanvasInput.Action, anchor: SIMD2<Double>) {
        switch action {
        case .none:
            return
        case .pan(let delta):
            if isSpace { view3D.pan(byPixels: delta) } else { mutateViewport { $0.pan(byPixels: delta) } }
        case .zoom(let factor):
            if isSpace { view3D.zoom(by: factor) } else { mutateViewport { $0.zoom(by: factor, anchorPixel: anchor) } }
        case .zoomBox(let factor):
            // 只换投影，坐标盒没变，不用重采。
            view3D.zoomCamera(by: factor)
            onViewChange?()
            return
        case .orbit(let delta):
            view3D.orbit(byPoints: delta)
            onViewChange?()
            return
        }
        onViewChange?()
        requestInteractiveBuild()
    }

    /// 同 `AppState.mutateViewport`：可见区要和内容包围盒外扩一圈相交，越界拉回（软边界）。
    private func mutateViewport(_ body: (inout Viewport2D) -> Void) {
        var next = viewport
        body(&next)
        viewport = ViewportBounds.clamp(next, content: built?.contentBounds)
    }

    // MARK: - 后台采样

    private func requestInteractiveBuild() {
        requestBuild(quality: .interactive)
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.requestBuild(quality: .full)
        }
    }

    private func requestBuild(quality: SampleQuality) {
        guard hasSize else { return }
        pendingQuality = quality
        startNextBuild()
    }

    private func startNextBuild() {
        guard !buildInFlight, let quality = pendingQuality else { return }
        pendingQuality = nil
        buildInFlight = true
        if isSpace {
            let request = SceneBuild3DRequest(document: document, compiled: compiled, view: view3D,
                                              quality: quality, backingScale: backingScale)
            Task.detached(priority: .userInitiated) { [weak self] in
                let result = SceneBuilder3D.build(request)
                await MainActor.run { [weak self] in
                    self?.built3D = result
                    self?.finishBuild()
                }
            }
        } else {
            // 四周多采一圈（同 App 的 `AppState.overscan`），拖动、缩小时露出来的边上已经有图。
            let request = SceneBuildRequest(document: document, compiled: compiled, viewport: viewport,
                                            quality: quality, backingScale: backingScale, overscan: 0.25,
                                            includesChrome: false)
            Task.detached(priority: .userInitiated) { [weak self] in
                let result = SceneBuilder2D.build(request)
                await MainActor.run { [weak self] in
                    self?.built = result
                    self?.finishBuild()
                }
            }
        }
    }

    private func finishBuild() {
        buildInFlight = false
        onSceneChange?()
        startNextBuild()
    }
}
