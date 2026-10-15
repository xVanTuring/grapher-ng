import AppKit
import GrapherKit

/// 两步之间的过渡：相机与参数从哪到哪，过渡完要开播的参数。
struct LessonAnimation {
    var start: CFTimeInterval
    var fromView: View3D
    var toView: View3D?
    var fromPlane: (center: SIMD2<Double>, width: Double)
    var toPlane: (center: SIMD2<Double>, width: Double)?
    var fromValues: [UUID: Double]
    var toValues: [UUID: Double]
    var plays: [UUID]
}

/// 讲解：一步一步看推导。正在看第几步是窗口状态（`lessonStep`），不进文档；每一步的图层显示只影响画出来的样子
/// （`presentedDocument`），图层自己的显示开关不动。看讲解时参数的变化不算改动文档，结束讲解时参数还原。
extension AppState {

    var currentLessonStep: LessonStep? {
        guard let lessonStep, document.lessonSteps.indices.contains(lessonStep) else { return nil }
        return document.lessonSteps[lessonStep]
    }

    // MARK: - 进出讲解、翻页

    /// 从第 `index` 步开始讲。没有步骤时什么都不做。
    func startLesson(at index: Int = 0, animated: Bool = true) {
        guard !document.lessonSteps.isEmpty else { return }
        if lessonStep == nil {
            lessonParameterSnapshot = Dictionary(uniqueKeysWithValues: document.parameters.map { ($0.id, $0.value) })
            // 选中的图层带高亮（往橙色偏），讲解时会改掉图的本色：先取消，要突出哪个由步骤的 `focus` 定。
            selection = nil
        }
        goToStep(index, animated: animated)
    }

    /// 结束讲解：图层按自己的显示开关，参数回到进讲解之前的值。
    func endLesson() {
        guard lessonStep != nil else { return }
        stopLessonMotion()
        for index in document.parameters.indices {
            if let value = lessonParameterSnapshot[document.parameters[index].id] {
                setParameterValueForLesson(at: index, value)
            }
        }
        lessonParameterSnapshot = [:]
        lessonStep = nil
        lessonEditing = false
        requestRebuild(interactive: false)
        notify(.lesson)
        notify(.playback)
        notify(.layers)
    }

    /// 换文档时丢掉讲解状态（参数不用还原，整份文档都换了）。
    func abandonLesson() {
        stopLessonMotion()
        lessonParameterSnapshot = [:]
        lessonStep = nil
        lessonEditing = false
        lessonFramePending = false
    }

    func toggleLesson() {
        if lessonStep != nil {
            endLesson()
        } else if document.lessonSteps.isEmpty {
            addLessonStep()
        } else {
            startLesson(at: 0)
        }
    }

    func nextStep() {
        guard let lessonStep, lessonStep + 1 < document.lessonSteps.count else { return }
        goToStep(lessonStep + 1, cumulative: false)
    }

    func previousStep() {
        guard let lessonStep, lessonStep > 0 else { return }
        goToStep(lessonStep - 1)
    }

    /// 换到第 `index` 步：图层显示当场换，相机与参数在 `LessonTransition.duration` 里平滑过渡过去，
    /// 过渡完再开这一步要播放的参数。
    /// - Parameter cumulative: 为真时（跳页、往回翻）相机与参数按「一路讲到这一步」的样子（`lessonState(at:)`）；
    ///   为假时（往后翻一页）只用这一步自己写的，没写相机就不动，手动转过的视角留着。
    func goToStep(_ index: Int, animated: Bool = true, cumulative: Bool = true) {
        guard document.lessonSteps.indices.contains(index) else { return }
        stopLessonMotion()
        lessonStep = index
        let step = document.lessonSteps[index]
        if let focus = step.focus, document.layers.contains(where: { $0.id == focus }) {
            selection = focus
        }

        let state: (parameters: [String: Double], camera: LessonCamera?) =
            cumulative ? document.lessonState(at: index) : (step.parameters, step.camera)
        var toValues: [UUID: Double] = [:]
        for parameter in document.parameters {
            if let value = state.parameters[parameter.name], value.isFinite { toValues[parameter.id] = value }
        }
        let plays = step.plays.compactMap { name in document.parameters.first { $0.name == name }?.id }
        let camera = state.camera
        let toView = document.dimension == .space ? camera?.space : nil
        var toPlane: (center: SIMD2<Double>, width: Double)?
        if document.dimension == .plane, let center = camera?.planeCenter, let width = camera?.planeWidth, width > 0 {
            toPlane = (center, width)
        }
        if !canvasMetricsKnown, toPlane != nil { lessonFramePending = true }

        let animation = LessonAnimation(
            start: CACurrentMediaTime(),
            fromView: document.view3D,
            toView: toView,
            fromPlane: currentPlaneFrame,
            toPlane: toPlane,
            fromValues: Dictionary(uniqueKeysWithValues: document.parameters.map { ($0.id, $0.value) }),
            toValues: toValues,
            plays: plays
        )
        requestRebuild(interactive: false)
        notify(.lesson)
        notify(.layers)

        guard animated, canvasMetricsKnown else {
            applyLessonFrame(animation, progress: 1)
            finishLessonAnimation(animation)
            return
        }
        lessonAnimation = animation
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.tickLessonAnimation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lessonTimer = timer
    }

    /// 画布刚报上尺寸：平面图按这一步「横向看到多宽」重新取景（立体图与画布尺寸无关）。
    func frameCurrentLessonStep() {
        guard document.dimension == .plane, let lessonStep, let camera = document.lessonState(at: lessonStep).camera,
              let center = camera.planeCenter, let width = camera.planeWidth, width > 0 else { return }
        setPlaneFrame(center: center, width: width)
    }

    /// 撤销之后：步骤可能少了，当前这一步要落在范围里；一步都没有了就结束讲解。
    func repairLesson() {
        guard let lessonStep else { return }
        stopLessonMotion()
        if document.lessonSteps.isEmpty {
            self.lessonStep = nil
            lessonEditing = false
            lessonParameterSnapshot = [:]
        } else if lessonStep >= document.lessonSteps.count {
            self.lessonStep = document.lessonSteps.count - 1
        }
        notify(.lesson)
    }

    // MARK: - 过渡动画

    private var currentPlaneFrame: (center: SIMD2<Double>, width: Double) {
        let viewport = document.viewport
        let usable = max(viewport.widthPixels - viewport.insetLeft - viewport.insetRight, 1)
        return (SIMD2(viewport.centerX, viewport.centerY), usable / viewport.scale)
    }

    private func setPlaneFrame(center: SIMD2<Double>, width: Double) {
        mutateViewport { viewport in
            let usable = max(viewport.widthPixels - viewport.insetLeft - viewport.insetRight, 1)
            viewport.scale = min(max(usable / width, Viewport2D.scaleRange.lowerBound), Viewport2D.scaleRange.upperBound)
            viewport.centerX = center.x
            viewport.centerY = center.y
        }
    }

    private func tickLessonAnimation() {
        guard let animation = lessonAnimation else {
            lessonTimer?.invalidate()
            lessonTimer = nil
            return
        }
        let raw = (CACurrentMediaTime() - animation.start) / LessonTransition.duration
        if raw >= 1 {
            lessonTimer?.invalidate()
            lessonTimer = nil
            lessonAnimation = nil
            applyLessonFrame(animation, progress: 1)
            finishLessonAnimation(animation)
            return
        }
        if applyLessonFrame(animation, progress: LessonTransition.ease(raw)) {
            requestInteractiveRebuild()
        }
    }

    /// 按进度摆好相机与参数。返回要不要重采（坐标盒或参数变了；只转相机不用）。
    @discardableResult
    private func applyLessonFrame(_ animation: LessonAnimation, progress t: Double) -> Bool {
        var needsSampling = false
        if let target = animation.toView {
            let view = LessonTransition.view(from: animation.fromView, to: target, progress: t)
            needsSampling = view.center != document.view3D.center || view.halfExtent != document.view3D.halfExtent
            mutateView3D { current in
                current.azimuth = view.azimuth
                current.elevation = min(max(view.elevation, -View3D.elevationLimit), View3D.elevationLimit)
                current.center = view.center
                current.halfExtent = min(max(view.halfExtent, View3D.halfExtentRange.lowerBound), View3D.halfExtentRange.upperBound)
                current.cameraZoom = min(max(view.cameraZoom, View3D.cameraZoomRange.lowerBound), View3D.cameraZoomRange.upperBound)
            }
        }
        if let target = animation.toPlane {
            let frame = LessonTransition.plane(
                fromCenter: animation.fromPlane.center, fromWidth: animation.fromPlane.width,
                toCenter: target.center, toWidth: target.width, progress: t)
            setPlaneFrame(center: frame.center, width: frame.width)
            needsSampling = true
        }
        var valuesChanged = false
        for (id, target) in animation.toValues {
            guard let index = document.parameters.firstIndex(where: { $0.id == id }) else { continue }
            let from = animation.fromValues[id] ?? target
            let value = LessonTransition.mix(from, target, t)
            if document.parameters[index].value != value {
                setParameterValueForLesson(at: index, value)
                valuesChanged = true
            }
        }
        if valuesChanged {
            needsSampling = true
            notify(.playback)
        }
        return needsSampling
    }

    private func finishLessonAnimation(_ animation: LessonAnimation) {
        requestRebuild(interactive: false)
        for id in animation.plays where !isPlaying(id) {
            togglePlayback(id: id)
            lessonPlays.insert(id)
        }
    }

    /// 停掉过渡动画与讲解开起来的播放。
    private func stopLessonMotion() {
        lessonTimer?.invalidate()
        lessonTimer = nil
        lessonAnimation = nil
        for id in lessonPlays where isPlaying(id) { togglePlayback(id: id) }
        lessonPlays = []
    }

    // MARK: - 图层显示

    /// 图层在眼前显不显示：讲解中按当前这一步。
    func isLayerShown(_ layer: Layer) -> Bool {
        guard let lessonStep else { return layer.isVisible }
        return document.isLayer(layer, visibleInStep: lessonStep)
    }

    /// 图层列表里的眼睛：讲解中改的是这一步显示哪些图层，不在讲解时改图层自己的开关。
    func toggleLayerVisibility(id: UUID) {
        guard let layer = layer(with: id) else { return }
        let visible = isLayerShown(layer)
        if let lessonStep {
            mutateLayers(visible ? L("Hide in This Step") : L("Show in This Step")) { document in
                document.setLayer(id, visible: !visible, inStep: lessonStep)
            }
            notify(.lesson)
            return
        }
        mutateLayers(visible ? L("Hide Layer") : L("Show Layer")) { document in
            guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
            document.layers[index].isVisible.toggle()
        }
    }

    // MARK: - 编辑步骤

    /// 照眼前的样子加一步（在当前这一步后面；不在讲解时加在最后并进入讲解），卡片进编辑。
    func addLessonStep() {
        let index = lessonStep.map { $0 + 1 } ?? document.lessonSteps.count
        let step = document.capturedStep(presenting: lessonStep, title: String(format: L("Step %ld"), index + 1))
        if lessonStep == nil {
            lessonParameterSnapshot = Dictionary(uniqueKeysWithValues: document.parameters.map { ($0.id, $0.value) })
        }
        stopLessonMotion()
        mutate(L("Add Step")) { $0.lessonSteps.insert(step, at: index) }
        lessonStep = index
        lessonEditing = true
        notify(.lesson)
        notify(.layers)
    }

    /// 把眼前的视角和各参数的值记进当前这一步。
    func recordViewIntoStep() {
        guard let lessonStep, document.lessonSteps.indices.contains(lessonStep) else { return }
        let camera = LessonCamera(of: document)
        var values: [String: Double] = [:]
        for parameter in document.parameters where parameter.isNameValid { values[parameter.name] = parameter.value }
        mutate(L("Record View in Step")) { document in
            document.lessonSteps[lessonStep].camera = camera
            document.lessonSteps[lessonStep].parameters = values
        }
        notify(.lesson)
    }

    func updateLessonStep(title: String, text: String) {
        guard let lessonStep, document.lessonSteps.indices.contains(lessonStep) else { return }
        mutate(L("Edit Step")) { document in
            document.lessonSteps[lessonStep].title = title
            document.lessonSteps[lessonStep].text = text
        }
        notify(.lesson)
    }

    func deleteLessonStep() {
        guard let lessonStep, document.lessonSteps.indices.contains(lessonStep) else { return }
        stopLessonMotion()
        mutate(L("Delete Step")) { $0.lessonSteps.remove(at: lessonStep) }
        if document.lessonSteps.isEmpty {
            endLesson()
        } else {
            goToStep(min(lessonStep, document.lessonSteps.count - 1))
        }
    }

    /// 当前这一步往前 / 往后挪一个位置。
    func moveLessonStep(by offset: Int) {
        guard let lessonStep else { return }
        let target = lessonStep + offset
        guard document.lessonSteps.indices.contains(lessonStep), document.lessonSteps.indices.contains(target) else { return }
        mutate(L("Move Step")) { $0.lessonSteps.swapAt(lessonStep, target) }
        self.lessonStep = target
        notify(.lesson)
    }

    func setLessonEditing(_ editing: Bool) {
        guard lessonEditing != editing else { return }
        lessonEditing = editing
        notify(.lesson)
    }

    /// 存盘用的文档：讲解中参数是讲解调出来的，存的是进讲解之前的值。
    var documentForSaving: GrapherDocument {
        guard lessonStep != nil else { return document }
        var saved = document
        for index in saved.parameters.indices {
            if let value = lessonParameterSnapshot[saved.parameters[index].id] { saved.parameters[index].value = value }
        }
        return saved
    }

    // MARK: - 键盘

    /// 讲解中画布上的按键：→ / 空格 / PageDown 下一步，← / ⇧空格 / PageUp 上一步，Esc 结束讲解。
    func handleLessonKey(_ event: NSEvent) -> Bool {
        guard lessonStep != nil, !lessonEditing else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard modifiers.isEmpty else { return false }
        switch event.specialKey {
        case .rightArrow?, .pageDown?: nextStep(); return true
        case .leftArrow?, .pageUp?: previousStep(); return true
        default: break
        }
        if event.keyCode == 53 {
            endLesson()
            return true
        }
        if event.charactersIgnoringModifiers == " " {
            if event.modifierFlags.contains(.shift) { previousStep() } else { nextStep() }
            return true
        }
        return false
    }
}
