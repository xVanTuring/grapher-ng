import AppKit
import Foundation
import GrapherKit

/// Owns the document, schedules sampling off the main thread, and tells the
/// view controllers when something they display has changed.
///
/// The change notifications are deliberately coarse — a controller subscribes
/// to the handful of categories it shows and refreshes wholesale. That keeps
/// the wiring obvious and avoids a dependency on a binding framework.
@MainActor
final class AppState {

    enum Change: Hashable {
        /// The document was replaced or its layer list changed structurally.
        case document
        /// A layer's contents changed (formula, style, visibility, order).
        case layers
        case selection
        /// Fresh geometry is available.
        case scene
        case probe
        case status
        /// The set of expression errors changed.
        case errors
        /// Parameters were added, removed or renamed.
        case parameters
        /// Viewport framing changed.
        case viewport
    }

    private struct Observer {
        let id: UUID
        let changes: Set<Change>?
        let handler: (Change) -> Void
    }

    private var observers: [Observer] = []

    /// Subscribing with `changes == nil` delivers every change.
    @discardableResult
    func observe(_ changes: Set<Change>? = nil, _ handler: @escaping (Change) -> Void) -> UUID {
        let observer = Observer(id: UUID(), changes: changes, handler: handler)
        observers.append(observer)
        return observer.id
    }

    func removeObserver(_ id: UUID) {
        observers.removeAll { $0.id == id }
    }

    private func notify(_ change: Change) {
        for observer in observers where observer.changes?.contains(change) ?? true {
            observer.handler(change)
        }
    }

    // MARK: - State

    private(set) var document: GrapherDocument
    private(set) var built: BuiltScene?
    private(set) var expressionErrors: [UUID: ExpressionError] = [:]
    private(set) var isBuilding = false
    private(set) var backingScale: Double = 2

    /// Drives the dot in the close button and the title bar's edited state.
    private(set) var isDocumentEdited = false

    var selection: UUID? {
        didSet {
            guard selection != oldValue else { return }
            notify(.selection)
        }
    }

    var probe: ProbeHit? {
        didSet { notify(.probe) }
    }

    var statusMessage: String = "" {
        didSet { notify(.status) }
    }

    var documentURL: URL?

    let compiler = LayerCompiler()
    var undoManager: UndoManager?

    /// 交互画布在视口四周各多采这么一圈（按视口宽 / 高的比例）：拖动、缩小时露出来的边上
    /// 已经有图，等下一份采样回来再补精。
    nonisolated static let overscan = 0.25

    /// 同一时刻只跑一份后台采样；跑着的时候来的请求只记下「还要再算一次、什么画质」，
    /// 跑完立刻按**那一刻**的文档和视口再起一份。早先每个鼠标事件都取消上一份、只收最新一代，
    /// 而一次采样比两次事件的间隔还长，结果是拖动全程一份都收不到，曲线只在停手后才跳过去；
    /// 被「取消」的任务也照样算完，白白占满 CPU。
    private var buildInFlight = false
    private var pendingQuality: SampleQuality?
    private var settleTask: Task<Void, Never>?
    private var liveEditSnapshot: GrapherDocument?
    private var chromeCache: (key: ChromeKey, scene: Scene2D, layout: ChromeLayout)?

    init(document: GrapherDocument? = nil) {
        if let document {
            self.document = document
        } else {
            var sample = GrapherDocument.sample()
            // First impressions matter: follow whatever appearance the machine
            // is in rather than assuming a white sheet.
            if UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" {
                sample.theme = .dark
            }
            self.document = sample
        }
        self.selection = self.document.layers.first?.id
    }

    // MARK: - Coordinates

    var viewport: Viewport2D { document.viewport }

    /// 画布尺寸与被浮层盖住的四边（都是像素）。画布铺满整个窗格、伸到毛玻璃侧栏与工具栏底下，
    /// `insets` 是被盖住的那一圈：视口中心落在没被盖住那块的中心，侧栏一开内容就被推开。
    /// 侧栏开合动画里每一帧都会走到这里，所以走交互画质，停下来再补精。
    func setViewportMetrics(
        pixelWidth: Double,
        pixelHeight: Double,
        insets: NSEdgeInsets,
        backingScale scale: Double
    ) {
        guard pixelWidth > 1, pixelHeight > 1, scale > 0 else { return }
        let scaleChanged = backingScale != scale
        backingScale = scale
        var viewport = document.viewport
        viewport.widthPixels = pixelWidth
        viewport.heightPixels = pixelHeight
        viewport.insetLeft = Double(insets.left) * scale
        viewport.insetTop = Double(insets.top) * scale
        viewport.insetRight = Double(insets.right) * scale
        viewport.insetBottom = Double(insets.bottom) * scale
        guard viewport != document.viewport || scaleChanged else { return }
        document.viewport = viewport
        notify(.viewport)
        requestInteractiveRebuild()
    }

    /// 换文档 / 撤销时沿用当前画布的尺寸与遮挡：那是窗口的状态，不是文档的。
    private func adoptCanvasMetrics(_ viewport: inout Viewport2D) {
        let current = document.viewport
        viewport.widthPixels = current.widthPixels
        viewport.heightPixels = current.heightPixels
        viewport.insetLeft = current.insetLeft
        viewport.insetTop = current.insetTop
        viewport.insetRight = current.insetRight
        viewport.insetBottom = current.insetBottom
    }

    private func restore(_ snapshot: GrapherDocument) {
        var restored = snapshot
        adoptCanvasMetrics(&restored.viewport)
        document = restored
    }

    // MARK: - Chrome

    private struct ChromeKey: Equatable {
        var viewport: Viewport2D
        var theme: Theme
        var showGrid: Bool
        var showMinorGrid: Bool
        var showAxes: Bool
        var backingScale: Double
    }

    /// 网格与坐标轴（Metal 画线）和刻度位置（叠加层写数字），都按**当前**视口现算，不走后台：
    /// 几十条线、微秒级，拖动时每一帧算一次，刻度数字与网格线就永远对得上。
    func chrome() -> (scene: Scene2D, layout: ChromeLayout) {
        let key = ChromeKey(
            viewport: document.viewport,
            theme: document.theme,
            showGrid: document.showGrid,
            showMinorGrid: document.showMinorGrid,
            showAxes: document.showAxes,
            backingScale: backingScale
        )
        if let cached = chromeCache, cached.key == key { return (cached.scene, cached.layout) }
        let made = SceneBuilder2D.chromeScene(document: document, viewport: document.viewport, backingScale: backingScale)
        chromeCache = (key, made.scene, made.layout)
        return made
    }

    // MARK: - Rebuilding

    func requestRebuild(interactive: Bool) {
        // 公式错误当场报，不等排队的采样。
        _ = compileDocument()
        pendingQuality = interactive ? .interactive : .full
        startNextBuild()
    }

    private func compileDocument() -> [LayerCompiler.CompiledLayer] {
        let compiled = compiler.compile(document)
        var errors: [UUID: ExpressionError] = [:]
        for layer in compiled {
            if let error = layer.primaryError { errors[layer.layer.id] = error }
        }
        // 只在真变了时广播：图层列表与检查器收到 `.errors` 会整个刷新，拖动时每个事件都发一次
        // 就是白白的主线程开销。
        if errors != expressionErrors {
            expressionErrors = errors
            notify(.errors)
        }
        return compiled
    }

    private func startNextBuild() {
        guard !buildInFlight, let quality = pendingQuality else { return }
        pendingQuality = nil
        buildInFlight = true

        let request = SceneBuildRequest(
            document: document,
            compiled: compileDocument(),
            viewport: document.viewport,
            quality: quality,
            backingScale: backingScale,
            overscan: Self.overscan,
            includesChrome: false
        )
        if !isBuilding {
            isBuilding = true
            notify(.status)
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = SceneBuilder2D.build(request)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.buildInFlight = false
                // 这份是按开工那一刻的视口算的，视口此后又动过也照收：画布会按两者的差把它
                // 摆到当前位置，总比继续显示更旧的那份强。
                self.built = result
                self.notify(.scene)
                self.startNextBuild()
                if !self.buildInFlight {
                    self.isBuilding = false
                    self.notify(.status)
                }
            }
        }
    }

    /// Gestures ask for a fast rebuild now and a precise one once they settle.
    func requestInteractiveRebuild() {
        requestRebuild(interactive: true)
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.requestRebuild(interactive: false)
            }
        }
    }

    /// Re-samples the whole document at a different resolution. Exporting this
    /// way (rather than upscaling screen geometry) means a 4x image really does
    /// contain 4x the detail in the curves.
    func buildForExport(scale: Double, quality: SampleQuality = .high) -> BuiltScene {
        // 导出用户眼前没被侧栏 / 工具栏盖住的那块，构图与屏幕上看到的一致。
        var viewport = exportViewport
        viewport.widthPixels *= scale
        viewport.heightPixels *= scale
        viewport.scale *= scale
        let compiled = compiler.compile(document)
        let request = SceneBuildRequest(
            document: document,
            compiled: compiled,
            viewport: viewport,
            quality: quality,
            backingScale: backingScale * scale
        )
        return SceneBuilder2D.build(request)
    }

    var exportViewport: Viewport2D { document.viewport.unobscured }

    // MARK: - Document mutation

    /// Applies a change and records one undo step for it.
    func mutate(_ actionName: String, _ body: (inout GrapherDocument) -> Void) {
        mutate(actionName, notifyChange: .document, body)
    }

    func mutateLayers(_ actionName: String, _ body: (inout GrapherDocument) -> Void) {
        mutate(actionName, notifyChange: .layers, body)
    }

    private func mutate(
        _ actionName: String,
        notifyChange: Change,
        _ body: (inout GrapherDocument) -> Void
    ) {
        let previous = document
        body(&document)
        guard document != previous else { return }
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                target.restore(previous)
                target.repairSelection()
                target.requestRebuild(interactive: false)
                target.notify(.document)
                target.notify(.layers)
                target.notify(.parameters)
            }
        }
        undoManager?.setActionName(actionName)
        markEdited()
        requestRebuild(interactive: false)
        notify(notifyChange)
        notify(.parameters)
    }

    /// Viewport gestures: many small writes, so the caller drives the rebuilds.
    /// 所有改视口的路径（拖动、滚轮、捏合、工具栏按钮、F/R）都收敛到这里，软边界只写一遍。
    func mutateViewport(_ body: (inout Viewport2D) -> Void) {
        var viewport = document.viewport
        body(&viewport)
        document.viewport = ViewportBounds.clamp(viewport, content: built?.contentBounds)
        notify(.viewport)
    }

    private func markEdited() {
        guard !isDocumentEdited else { return }
        isDocumentEdited = true
        notify(.status)
    }

    private func markSaved() {
        guard isDocumentEdited else { return }
        isDocumentEdited = false
        notify(.status)
    }

    /// Starts a run of live edits (typing in a formula field, dragging a
    /// slider). The document updates immediately so the picture follows along,
    /// but only one undo entry is recorded when the run ends.
    func beginLiveEdit() {
        if liveEditSnapshot == nil { liveEditSnapshot = document }
    }

    func commitLiveEdit(_ actionName: String) {
        guard let snapshot = liveEditSnapshot else { return }
        liveEditSnapshot = nil
        guard snapshot != document else { return }
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                target.restore(snapshot)
                target.repairSelection()
                target.requestRebuild(interactive: false)
                target.notify(.document)
                target.notify(.layers)
            }
        }
        undoManager?.setActionName(actionName)
    }

    // MARK: - Layers

    func layer(with id: UUID?) -> Layer? {
        guard let id else { return nil }
        return document.layers.first { $0.id == id }
    }

    var selectedLayer: Layer? { layer(with: selection) }

    func addLayer(_ kind: PlotKind) {
        var created = Layer.makeDefault(kind: kind, index: document.layers.count)
        // 参数方程、极坐标、空间曲线、参数曲面的参数范围总是生效。
        created.usesExplicitDomain = kind.usesDomain && kind != .explicit
        let id = created.id
        mutate(String(format: L("New %@"), kind.shortName)) { $0.layers.append(created) }
        selection = id
    }

    func removeLayer(id: UUID) {
        mutate(L("Delete Layer")) { document in
            document.layers.removeAll { $0.id == id }
        }
        repairSelection()
    }

    func moveLayers(from source: IndexSet, to destination: Int) {
        mutate(L("Reorder Layers")) { $0.layers.moveElements(fromOffsets: source, toOffset: destination) }
    }

    func duplicateLayer(id: UUID) {
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
        var copy = document.layers[index]
        copy.id = UUID()
        copy.name = String(format: L("%@ Copy"), copy.name)
        let newID = copy.id
        mutate(L("Duplicate Layer")) { $0.layers.insert(copy, at: index + 1) }
        selection = newID
    }

    /// Applies an edit and schedules a precise rebuild.
    func updateLayer(id: UUID, _ body: (inout Layer) -> Void) {
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
        body(&document.layers[index])
        markEdited()
        requestRebuild(interactive: false)
        notify(.layers)
    }

    /// Applies an edit during a gesture; the picture follows at coarse quality.
    func updateLayerLive(id: UUID, _ body: (inout Layer) -> Void) {
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
        body(&document.layers[index])
        markEdited()
        requestInteractiveRebuild()
        notify(.layers)
    }

    private func repairSelection() {
        if let selection, document.layers.contains(where: { $0.id == selection }) { return }
        self.selection = document.layers.first?.id
    }

    // MARK: - Parameters

    func updateParameter(id: UUID, value: Double) {
        guard let index = document.parameters.firstIndex(where: { $0.id == id }) else { return }
        document.parameters[index].value = value
        markEdited()
        requestInteractiveRebuild()
    }

    func addParameter() {
        var name = "a"
        var suffix = 0
        let taken = Set(document.parameters.map(\.name))
        while taken.contains(name) {
            suffix += 1
            name = "a\(suffix)"
        }
        var parameter = ParameterDefinition(name: name)
        parameter.lowerBound = -5
        parameter.upperBound = 5
        mutate(L("New Parameter")) { $0.parameters.append(parameter) }
    }

    func removeParameter(id: UUID) {
        mutate(L("Delete Parameter")) { document in
            document.parameters.removeAll { $0.id == id }
        }
    }

    func renameParameter(id: UUID, to name: String) {
        guard let index = document.parameters.firstIndex(where: { $0.id == id }) else { return }
        document.parameters[index].name = name
        markEdited()
        requestRebuild(interactive: false)
        notify(.parameters)
    }

    // MARK: - View helpers

    /// 「适应内容」：把所有曲线的包围盒装进视口；内容为空则回原点。和 UniReader 的
    /// `ScratchBounds.fit` 是同一条规则。
    func fitToContent() {
        guard let bounds = built?.fitBounds else {
            resetView()
            return
        }
        mutateViewport { viewport in
            viewport.fit(minX: bounds.minX, maxX: bounds.maxX, minY: bounds.minY, maxY: bounds.maxY)
        }
        requestRebuild(interactive: false)
    }

    /// 「回原点」：中心归零、回到默认倍率。
    func resetView() {
        mutateViewport { viewport in
            viewport.centerX = 0
            viewport.centerY = 0
            viewport.scale = 64
        }
        requestRebuild(interactive: false)
    }

    /// 以视口中心为锚缩放：工具栏按钮与 ⌘= / ⌘- 都走这条。锚点代数只写在 `Viewport2D.zoom`
    /// 一处，别在这里再抄一遍（UniReader 那边 ⌘0 / 1:1 / 捏合 / ⌘滚轮四个入口共用一个
    /// `applyZoom`，就是这个道理）。
    func zoom(by factor: Double) {
        mutateViewport { viewport in
            viewport.zoom(
                by: factor,
                anchorPixel: SIMD2(viewport.focusX, viewport.focusY)
            )
        }
        requestRebuild(interactive: false)
    }

    // MARK: - Files

    func newDocument() {
        var fresh = GrapherDocument()
        adoptCanvasMetrics(&fresh.viewport)
        document = fresh
        selection = nil
        documentURL = nil
        markSaved()
        statusMessage = L("Created a blank document")
        requestRebuild(interactive: false)
        notify(.document)
        notify(.layers)
        notify(.parameters)
    }

    func open(url: URL) {
        do {
            var loaded = try DocumentStore.load(from: url)
            adoptCanvasMetrics(&loaded.viewport)
            document = loaded
            selection = loaded.layers.first?.id
            documentURL = url
            markSaved()
            statusMessage = String(format: L("Opened %@"), url.lastPathComponent)
            requestRebuild(interactive: false)
            notify(.document)
            notify(.layers)
            notify(.parameters)
        } catch {
            presentError(L("Could not open the file"), error.localizedDescription)
        }
    }

    func save(to url: URL?) {
        guard let url else { return }
        do {
            try DocumentStore.save(document, to: url)
            documentURL = url
            markSaved()
            statusMessage = String(format: L("Saved to %@"), url.lastPathComponent)
        } catch {
            presentError(L("Could not save the file"), error.localizedDescription)
        }
    }

    func presentError(_ title: String, _ message: String) {
        statusMessage = String(format: L("%@: %@"), title, message)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }
}

extension Array {
    /// SwiftUI declares `move(fromOffsets:toOffset:)` on MutableCollection.
    /// The app does not import SwiftUI any more, so the reorder is spelled out
    /// here instead of relying on that extension.
    mutating func moveElements(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moving = offsets.compactMap { $0 < count ? self[$0] : nil }
        guard !moving.isEmpty else { return }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        for index in offsets.sorted(by: >) where index < count {
            remove(at: index)
        }
        let target = Swift.min(Swift.max(destination - removedBeforeDestination, 0), count)
        insert(contentsOf: moving, at: target)
    }
}
