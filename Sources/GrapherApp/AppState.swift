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

    private var generation = 0
    private var buildTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var liveEditSnapshot: GrapherDocument?

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

    func setViewportMetrics(pixelWidth: Double, pixelHeight: Double, backingScale scale: Double) {
        guard pixelWidth > 1, pixelHeight > 1, scale > 0 else { return }
        backingScale = scale
        guard document.viewport.widthPixels != pixelWidth
            || document.viewport.heightPixels != pixelHeight
        else { return }
        document.viewport.widthPixels = pixelWidth
        document.viewport.heightPixels = pixelHeight
        requestRebuild(interactive: false)
    }

    // MARK: - Rebuilding

    func requestRebuild(interactive: Bool) {
        generation += 1
        let currentGeneration = generation
        let compiled = compiler.compile(document)

        var errors: [UUID: ExpressionError] = [:]
        for layer in compiled {
            if let error = layer.primaryError { errors[layer.layer.id] = error }
        }
        expressionErrors = errors
        notify(.errors)

        let request = SceneBuildRequest(
            document: document,
            compiled: compiled,
            viewport: document.viewport,
            quality: interactive ? .interactive : .full,
            backingScale: backingScale
        )

        isBuilding = true
        notify(.status)
        buildTask?.cancel()
        buildTask = Task.detached(priority: .userInitiated) {
            let results = SceneBuilder2D.build(request)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, currentGeneration == self.generation else { return }
                self.built = results
                self.isBuilding = false
                self.notify(.scene)
                self.notify(.status)
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
        var viewport = document.viewport
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
                target.document = previous
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
                target.document = snapshot
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
        created.usesExplicitDomain = kind == .parametric || kind == .polar
        let id = created.id
        mutate("新建\(kind.shortName)") { $0.layers.append(created) }
        selection = id
    }

    func removeLayer(id: UUID) {
        mutate("删除图层") { document in
            document.layers.removeAll { $0.id == id }
        }
        repairSelection()
    }

    func moveLayers(from source: IndexSet, to destination: Int) {
        mutate("调整顺序") { $0.layers.moveElements(fromOffsets: source, toOffset: destination) }
    }

    func duplicateLayer(id: UUID) {
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
        var copy = document.layers[index]
        copy.id = UUID()
        copy.name += " 副本"
        let newID = copy.id
        mutate("复制图层") { $0.layers.insert(copy, at: index + 1) }
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
        mutate("新建参数") { $0.parameters.append(parameter) }
    }

    func removeParameter(id: UUID) {
        mutate("删除参数") { document in
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
        guard let bounds = built?.contentBounds else {
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
                anchorPixel: SIMD2(viewport.widthPixels / 2, viewport.heightPixels / 2)
            )
        }
        requestRebuild(interactive: false)
    }

    // MARK: - Files

    func newDocument() {
        var fresh = GrapherDocument()
        fresh.viewport.widthPixels = document.viewport.widthPixels
        fresh.viewport.heightPixels = document.viewport.heightPixels
        document = fresh
        selection = nil
        documentURL = nil
        markSaved()
        statusMessage = "已新建空白文档"
        requestRebuild(interactive: false)
        notify(.document)
        notify(.layers)
        notify(.parameters)
    }

    func open(url: URL) {
        do {
            var loaded = try DocumentStore.load(from: url)
            loaded.viewport.widthPixels = document.viewport.widthPixels
            loaded.viewport.heightPixels = document.viewport.heightPixels
            document = loaded
            selection = loaded.layers.first?.id
            documentURL = url
            markSaved()
            statusMessage = "已打开 \(url.lastPathComponent)"
            requestRebuild(interactive: false)
            notify(.document)
            notify(.layers)
            notify(.parameters)
        } catch {
            presentError("打开失败", error.localizedDescription)
        }
    }

    func save(to url: URL?) {
        guard let url else { return }
        do {
            try DocumentStore.save(document, to: url)
            documentURL = url
            markSaved()
            statusMessage = "已保存到 \(url.lastPathComponent)"
        } catch {
            presentError("保存失败", error.localizedDescription)
        }
    }

    func presentError(_ title: String, _ message: String) {
        statusMessage = "\(title)：\(message)"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
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
