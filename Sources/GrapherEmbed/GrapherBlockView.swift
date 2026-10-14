import AppKit
import GrapherKit
import GrapherRender

/// 给别的 App 放进文字里的一块图形（UniReader 的 Markdown 笔记里的 ```grapher 代码块）：
/// 一段文字描述（`GrapherText`）画出来，能点一下进入操作状态，拖动旋转 / 平移、滚轮缩放、改参数，
/// 再把眼前的视角和参数写回文字。
///
/// - **平时**是一张图，不吃事件（滚轮、拖动还是归笔记自己滚动）；**点一下**进入操作状态（描一圈边框、出按钮与滑块），
///   点到块外或按 Esc 退出。
/// - 画法与 App、Quick Look 预览是同一套（`MetalView2D` / `MetalView3D`，刻度文字 `PlaneLabels` / `Chrome3D`），
///   手感是同一份 `CanvasInput`：拖动转 / 平移，⇧+拖动平移，滚轮 / 捏合缩放，⌥ 放大盒子，双击回到文字里写的取景。
/// - 文字是唯一的真源：块自己不存任何东西。「保存视角」按钮把当前视角与参数值用 `GrapherText.patch` 改进文字，
///   经 `onSourceChange` 交给宿主存回笔记。
@MainActor
public final class GrapherBlockView: NSView {

    /// 用户点了「保存视角」：宿主把这段新文字存回笔记。
    public var onSourceChange: ((String) -> Void)?
    /// 进入 / 退出操作状态（宿主可以据此让笔记别抢滚轮）。
    public var onActivationChange: ((Bool) -> Void)?
    /// 用户点了「编辑文字」：宿主把光标放进这段文字让它露出来。不设就没有这个按钮。
    public var onEditSource: (() -> Void)? {
        didSet { editButton.isHidden = onEditSource == nil }
    }
    /// 宿主指定的主题（笔记的深浅色）。nil = 文字里写了 `theme:` 就听文字的，否则跟系统外观。
    public var themeOverride: Theme? {
        didSet { applyTheme() }
    }

    public private(set) var source: String
    public private(set) var parseResult: GrapherText.Result
    public private(set) var isActive = false

    /// 宽 / 高：宿主按它定块的高度。
    public var aspect: Double { parseResult.aspect }
    public var errors: [GrapherText.Diagnostic] { parseResult.errors }

    /// 宽度给定时块该多高。
    public func height(forWidth width: CGFloat) -> CGFloat {
        (width / CGFloat(aspect)).rounded()
    }

    private(set) var session: GrapherBlockSession
    private var canvas: NSView?
    private var metal2D: MetalView2D?
    private var metal3D: MetalView3D?
    private let overlay = BlockLabelOverlay()
    private let toolbar = NSStackView()
    private let resetButton = NSButton()
    private let saveButton = NSButton()
    private let openButton = NSButton()
    private let editButton = NSButton()
    private let parameterBar = NSVisualEffectView()
    private let parameterStack = NSStackView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var parameterRows: [ParameterRow] = []

    private var lastDragLocation: NSPoint?
    private var dragPans = false
    private var chrome2D: (viewport: Viewport2D, scale: Double, scene: Scene2D, layout: ChromeLayout)?
    private var chrome3D: (view: View3D, scale: Double, result: Chrome3D.Result)?

    private var playing: [String: Double] = [:]   // 参数名 → 方向
    private var playbackTimer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var outsideClickMonitor: Any?
    /// 上一次存进文字的样子：和现在的取景、参数比，决定「保存」按钮亮不亮。
    private var baselineSource: String

    private struct ParameterRow {
        var name: String
        var slider: NSSlider
        var value: NSTextField
        var play: NSButton
    }

    // MARK: - 创建

    /// Metal 不可用时返回 nil，宿主退回显示原文。
    public init?(source: String) {
        guard MetalContext.shared != nil else { return nil }
        self.source = source
        baselineSource = source
        let result = GrapherText.parse(source)
        parseResult = result
        session = GrapherBlockSession(document: result.document)
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        guard installCanvas() else { return nil }
        buildControls()
        rebuildParameterRows()
        refreshChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GrapherBlockView is created in code only")
    }

    deinit {
        MainActor.assumeIsolated {
            playbackTimer?.invalidate()
            if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        }
    }

    // MARK: - 换文字

    /// 文字被改了（笔记里编辑了代码块）：重新读，取景、参数回到文字里写的。
    public func setSource(_ text: String) {
        guard text != source else { return }
        source = text
        baselineSource = text
        let result = GrapherText.parse(text)
        let dimensionChanged = result.document.dimension != parseResult.document.dimension
        parseResult = result
        stopPlayback()
        session = GrapherBlockSession(document: result.document)
        if dimensionChanged || canvas == nil { _ = installCanvas() } else { wireSession(); pushContent() }
        rebuildParameterRows()
        applyTheme()
        refreshChrome()
        chrome2D = nil
        chrome3D = nil
        needsLayout = true
        requestFrame()
    }

    @discardableResult
    private func installCanvas() -> Bool {
        canvas?.removeFromSuperview()
        metal2D = nil
        metal3D = nil
        guard let context = MetalContext.shared else { return false }
        let made: NSView?
        if session.isSpace {
            metal3D = MetalView3D(frame: bounds, context: context)
            made = metal3D
        } else {
            metal2D = MetalView2D(frame: bounds, context: context)
            made = metal2D
        }
        guard let made else { return false }
        made.frame = bounds
        made.autoresizingMask = [.width, .height]
        addSubview(made, positioned: .below, relativeTo: nil)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        if overlay.superview == nil { addSubview(overlay, positioned: .above, relativeTo: made) }
        canvas = made
        metal2D?.onFrame = { [weak self] in self?.frameWillDraw() }
        metal3D?.onFrame = { [weak self] in self?.frameWillDraw() }
        wireSession()
        applyTheme()
        return true
    }

    private func wireSession() {
        session.onViewChange = { [weak self] in
            self?.requestFrame()
            self?.refreshChrome()
        }
        session.onSceneChange = { [weak self] in self?.pushContent() }
    }

    // MARK: - 主题

    private var resolvedTheme: Theme {
        if let themeOverride { return themeOverride }
        switch parseResult.themeName {
        case "dark": return .dark
        case "light": return .light
        default:
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? .dark : .light
        }
    }

    private func applyTheme() {
        session.setTheme(resolvedTheme)
        chrome2D = nil
        chrome3D = nil
        overlay.labels.reset()
        requestFrame()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    // MARK: - 尺寸

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { isActive }
    public override var mouseDownCanMoveWindow: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var backingScale: Double { Double(window?.backingScaleFactor ?? 2) }

    public override func layout() {
        super.layout()
        syncCanvasSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        overlay.labels.reset()
        syncCanvasSize()
    }

    /// 布局里不直接改状态，延后一拍（同 Quick Look 预览）。
    private func syncCanvasSize() {
        let size = bounds.size
        let scale = backingScale
        DispatchQueue.main.async { [weak self] in
            self?.session.setCanvasSize(pixelWidth: (size.width * scale).rounded(),
                                        pixelHeight: (size.height * scale).rounded(), backingScale: scale)
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setActive(false) }
    }

    // MARK: - 出帧

    private func requestFrame() {
        metal2D?.requestFrame()
        metal3D?.requestFrame()
    }

    private func pushContent() {
        if let metal2D, let built = session.built {
            metal2D.setContent(built.scene, viewport: built.viewport)
        }
        if let metal3D, let built = session.built3D {
            metal3D.setContent(built.scene, view: built.view)
        }
    }

    private static func color(_ c: RGBAColor) -> NSColor {
        NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    /// 每次屏幕刷新、Metal 画这一帧之前：网格 / 坐标盒按当前视口现画，曲线层换视口，刻度与标注文字挪到位。
    private func frameWillDraw() {
        let document = session.document
        let scale = session.backingScale
        let labelColor = Self.color(document.theme.label)
        overlay.begin(scale: scale, appearance: effectiveAppearance)
        defer { overlay.end() }

        if let metal2D {
            let viewport = session.viewport
            if chrome2D?.viewport != viewport || chrome2D?.scale != scale {
                let made = SceneBuilder2D.chromeScene(document: document, viewport: viewport, backingScale: scale)
                chrome2D = (viewport, scale, made.scene, made.layout)
            }
            guard let chrome = chrome2D else { return }
            metal2D.background = document.theme.background
            if metal2D.chrome != chrome.scene { metal2D.chrome = chrome.scene }
            metal2D.viewport = viewport

            let tickFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            let originFont = NSFont.systemFont(ofSize: 10.5, weight: .bold)
            let axisNameFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
            for label in PlaneLabels.make(chrome: chrome.layout, viewport: viewport,
                                          showTickLabels: document.showTickLabels,
                                          width: bounds.width, height: bounds.height, pointScale: scale) {
                let font: NSFont
                switch label.role {
                case .tick: font = tickFont
                case .origin: font = originFont
                case .axisName: font = axisNameFont
                }
                overlay.labels.place(label.key, label.text, font: font, color: labelColor,
                                     at: CGPoint(x: label.point.x, y: label.point.y), anchor: label.anchor)
            }
            // 自由文字：文字左边缘对着数据坐标 (x, y)。
            for (index, annotation) in TextAnnotations.all(in: document, compiled: session.compiled).enumerated() {
                let screen = viewport.toScreen(x: annotation.position.x, y: annotation.position.y)
                let point = CGPoint(x: screen.x / scale, y: screen.y / scale)
                guard point.x > -400, point.x < bounds.width + 40, point.y > -40, point.y < bounds.height + 40 else { continue }
                overlay.labels.place("a\(index)", annotation.text, font: .systemFont(ofSize: annotation.fontSize),
                                     color: Self.color(annotation.color), at: point, anchor: .leading)
            }
        }

        if let metal3D {
            let view = session.view3D
            if chrome3D?.view != view || chrome3D?.scale != scale {
                chrome3D = (view, scale, Chrome3D.make(view: view, document: document, backingScale: scale))
            }
            guard let chrome = chrome3D?.result else { return }
            metal3D.background = document.theme.background
            if metal3D.chrome != chrome.scene { metal3D.chrome = chrome.scene }
            metal3D.viewport = view

            let tickFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            let nameFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
            for label in chrome.labels {
                guard let screen = view.project(label.position) else { continue }
                let point = CGPoint(x: screen.x / scale, y: screen.y / scale)
                guard point.x > 8, point.x < bounds.width - 8, point.y > 8, point.y < bounds.height - 8 else { continue }
                switch label.kind {
                case .tick(let value, let decimals):
                    overlay.labels.place("t\(label.axis)", AxisLabelFormat.tick(value, decimals: decimals),
                                         font: tickFont, color: labelColor, at: point, anchor: .center)
                case .axisName(let name):
                    overlay.labels.place("n", name, font: nameFont, color: labelColor, at: point, anchor: .center)
                }
            }
            if document.layers.contains(where: { $0.kind == .point && $0.isVisible && $0.showsLabel }) {
                let pointFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
                for (index, label) in SpaceGeometry.pointLabels(in: session.compiled, view: view).enumerated() {
                    guard let screen = view.project(view.normalized(label.position)) else { continue }
                    let point = CGPoint(x: screen.x / scale + 9, y: screen.y / scale - 9)
                    guard point.x > 0, point.x < bounds.width - 8, point.y > 8, point.y < bounds.height else { continue }
                    overlay.labels.place("p\(index)", label.name, font: pointFont,
                                         color: Self.color(label.color), at: point, anchor: .leading)
                }
            }
            for (index, annotation) in TextAnnotations.all(in: document, compiled: session.compiled).enumerated() {
                guard let screen = view.project(view.normalized(annotation.position)) else { continue }
                let point = CGPoint(x: screen.x / scale, y: screen.y / scale)
                guard point.x > -200, point.x < bounds.width, point.y > 0, point.y < bounds.height else { continue }
                overlay.labels.place("a\(index)", annotation.text, font: .systemFont(ofSize: annotation.fontSize),
                                     color: Self.color(annotation.color), at: point, anchor: .leading)
            }
        }
    }

    // MARK: - 操作状态

    public func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        layer?.borderWidth = on ? 2 : 0
        toolbar.isHidden = !on
        parameterBar.isHidden = !on || parameterRows.isEmpty
        if on {
            window?.makeFirstResponder(self)
            installOutsideClickMonitor()
        } else {
            stopPlayback()
            lastDragLocation = nil
            if let outsideClickMonitor {
                NSEvent.removeMonitor(outsideClickMonitor)
                self.outsideClickMonitor = nil
            }
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
        refreshChrome()
        onActivationChange?(on)
    }

    private func installOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                guard self.isActive, event.window === self.window else { return }
                let point = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(point) { self.setActive(false) }
            }
            return event
        }
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, isActive {   // Esc
            setActive(false)
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - 手势（规则在 CanvasInput，与 App、预览相同）

    private func anchor(of event: NSEvent) -> SIMD2<Double> {
        let local = convert(event.locationInWindow, from: nil)
        return SIMD2(Double(local.x), Double(local.y)) * backingScale
    }

    public override func mouseDown(with event: NSEvent) {
        guard isActive else {
            setActive(true)
            return
        }
        if event.clickCount == 2 {
            lastDragLocation = nil
            session.resetView()
            return
        }
        lastDragLocation = convert(event.locationInWindow, from: nil)
        dragPans = event.modifierFlags.contains(.shift)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isActive, let last = lastDragLocation else { return }
        let current = convert(event.locationInWindow, from: nil)
        lastDragLocation = current
        let delta = SIMD2(Double(current.x - last.x), Double(current.y - last.y))
        session.apply(CanvasInput.drag(delta, modifiers: CanvasInput.Modifiers(event.modifierFlags),
                                       space: session.isSpace, pansFromStart: dragPans, pointScale: backingScale),
                      anchor: anchor(of: event))
    }

    public override func mouseUp(with event: NSEvent) {
        lastDragLocation = nil
        dragPans = false
    }

    public override func scrollWheel(with event: NSEvent) {
        guard isActive else {
            // 没进入操作状态：滚轮还是笔记自己的。
            nextResponder?.scrollWheel(with: event)
            return
        }
        session.apply(CanvasInput.scroll(CanvasInput.Scroll(event), space: session.isSpace, pointScale: backingScale),
                      anchor: anchor(of: event))
    }

    public override func magnify(with event: NSEvent) {
        guard isActive else {
            nextResponder?.magnify(with: event)
            return
        }
        session.apply(CanvasInput.pinch(magnification: Double(event.magnification),
                                        modifiers: CanvasInput.Modifiers(event.modifierFlags), space: session.isSpace),
                      anchor: anchor(of: event))
    }

    // MARK: - 按钮与滑块

    private func buildControls() {
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.drawsBackground = true
        errorLabel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85)
        errorLabel.maximumNumberOfLines = 4
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true
        addSubview(errorLabel)

        configure(resetButton, symbol: "arrow.counterclockwise", tip: L("Reset view"), action: #selector(resetViewTapped))
        configure(saveButton, symbol: "square.and.arrow.down", tip: L("Save view and parameters to the note"), action: #selector(saveTapped))
        configure(openButton, symbol: "arrow.up.forward.app", tip: L("Open in Grapher NG"), action: #selector(openTapped))
        toolbar.orientation = .horizontal
        toolbar.spacing = 2
        toolbar.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        configure(editButton, symbol: "chevron.left.forwardslash.chevron.right", tip: L("Edit the text"), action: #selector(editTapped))
        editButton.isHidden = onEditSource == nil
        toolbar.setViews([editButton, resetButton, saveButton, openButton], in: .leading)
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.88).cgColor
        toolbar.layer?.cornerRadius = 6
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.isHidden = true
        addSubview(toolbar)

        parameterBar.material = .hudWindow
        parameterBar.blendingMode = .withinWindow
        parameterBar.state = .active
        parameterBar.translatesAutoresizingMaskIntoConstraints = false
        parameterBar.isHidden = true
        parameterStack.orientation = .vertical
        parameterStack.alignment = .leading
        parameterStack.spacing = 2
        parameterStack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        parameterStack.translatesAutoresizingMaskIntoConstraints = false
        parameterBar.addSubview(parameterStack)
        addSubview(parameterBar)

        NSLayoutConstraint.activate([
            errorLabel.topAnchor.constraint(equalTo: topAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            parameterBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            parameterBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            parameterBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            parameterStack.topAnchor.constraint(equalTo: parameterBar.topAnchor),
            parameterStack.bottomAnchor.constraint(equalTo: parameterBar.bottomAnchor),
            parameterStack.leadingAnchor.constraint(equalTo: parameterBar.leadingAnchor),
            parameterStack.trailingAnchor.constraint(equalTo: parameterBar.trailingAnchor),
        ])
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = tip
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func rebuildParameterRows() {
        for view in parameterStack.arrangedSubviews { view.removeFromSuperview() }
        parameterRows.removeAll()
        for parameter in session.document.parameters where parameter.isNameValid {
            let name = NSTextField(labelWithString: parameter.name)
            name.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            name.setContentHuggingPriority(.required, for: .horizontal)
            name.widthAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true

            let slider = NSSlider(value: parameter.value, minValue: parameter.lowerBound, maxValue: parameter.upperBound,
                                  target: self, action: #selector(sliderMoved(_:)))
            slider.isContinuous = true
            slider.controlSize = .small
            slider.identifier = NSUserInterfaceItemIdentifier(parameter.name)

            let value = NSTextField(labelWithString: GrapherText.number(parameter.value))
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            value.alignment = .right
            value.widthAnchor.constraint(equalToConstant: 46).isActive = true

            let play = NSButton()
            configure(play, symbol: "play.fill", tip: L("Play"), action: #selector(playTapped(_:)))
            play.identifier = NSUserInterfaceItemIdentifier(parameter.name)

            let row = NSStackView(views: [name, slider, value, play])
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false
            parameterStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: parameterStack.widthAnchor, constant: -16).isActive = true
            parameterRows.append(ParameterRow(name: parameter.name, slider: slider, value: value, play: play))
        }
        parameterBar.isHidden = !isActive || parameterRows.isEmpty
    }

    /// 错误条、保存按钮是否可点。
    private func refreshChrome() {
        let patched = GrapherText.patch(source: baselineSource, view: session.currentViewValues,
                                        parameters: session.currentParameterValues)
        saveButton.isEnabled = patched != baselineSource
        if parseResult.errors.isEmpty {
            errorLabel.isHidden = true
        } else {
            errorLabel.isHidden = false
            let lines = parseResult.errors.prefix(3).map { String(format: L("Line %ld: %@"), $0.line, $0.message) }
            let more = parseResult.errors.count > 3 ? "\n…" : ""
            errorLabel.stringValue = lines.joined(separator: "\n") + more
            errorLabel.preferredMaxLayoutWidth = max(bounds.width - 12, 100)
        }
    }

    @objc private func editTapped() {
        onEditSource?()
    }

    @objc private func resetViewTapped() {
        session.resetView()
    }

    @objc func saveTapped() {
        let patched = GrapherText.patch(source: baselineSource, view: session.currentViewValues,
                                        parameters: session.currentParameterValues)
        guard patched != baselineSource else { return }
        source = patched
        baselineSource = patched
        refreshChrome()
        onSourceChange?(patched)
    }

    @objc private func openTapped() {
        let document = session.currentDocument
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GrapherBlocks", isDirectory: true)
        let url = directory.appendingPathComponent("block-\(UUID().uuidString.prefix(8)).grapher")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try DocumentStore.save(document, to: url)
        } catch {
            NSSound.beep()
            return
        }
        let workspace = NSWorkspace.shared
        guard let app = workspace.urlForApplication(withBundleIdentifier: "tech.xvanturing.GrapherNG") else {
            let alert = NSAlert()
            alert.messageText = L("Grapher NG is not installed.")
            alert.runModal()
            return
        }
        workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        guard let name = sender.identifier?.rawValue else { return }
        // 手动拖动时这个参数不再自动播放。
        if playing[name] != nil { togglePlay(name) }
        setParameter(name, sender.doubleValue)
    }

    func setParameter(_ name: String, _ value: Double) {
        session.setParameter(name, value)
        if let row = parameterRows.first(where: { $0.name == name }), let current = session.parameterValue(name) {
            row.value.stringValue = GrapherText.number(current)
            if row.slider.doubleValue != current { row.slider.doubleValue = current }
        }
        refreshChrome()
    }

    // MARK: - 参数播放

    @objc private func playTapped(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        togglePlay(name)
    }

    func togglePlay(_ name: String) {
        if playing[name] != nil {
            playing[name] = nil
        } else {
            playing[name] = 1
        }
        for row in parameterRows {
            let on = playing[row.name] != nil
            row.play.image = NSImage(systemSymbolName: on ? "pause.fill" : "play.fill", accessibilityDescription: on ? L("Pause") : L("Play"))
            row.play.toolTip = on ? L("Pause") : L("Play")
        }
        if playing.isEmpty {
            playbackTimer?.invalidate()
            playbackTimer = nil
        } else if playbackTimer == nil {
            lastTick = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.playbackTick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            playbackTimer = timer
        }
    }

    private func stopPlayback() {
        playing.removeAll()
        playbackTimer?.invalidate()
        playbackTimer = nil
        for row in parameterRows {
            row.play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: L("Play"))
            row.play.toolTip = L("Play")
        }
    }

    private func playbackTick() {
        let now = CACurrentMediaTime()
        let seconds = min(now - lastTick, 0.2)
        lastTick = now
        for (name, direction) in playing {
            guard let definition = session.document.parameters.first(where: { $0.name == name }) else { continue }
            let next = ParameterPlayback.advance(
                value: definition.value, direction: direction, lower: definition.lowerBound, upper: definition.upperBound,
                seconds: seconds, sweepSeconds: 5, mode: .pingPong)
            playing[name] = next.direction
            setParameter(name, next.value)
        }
    }
}

/// 刻度文字层：每串字一个小图层，只挪不重画（`TextLayerPool`）。不接鼠标，事件归底下的画布。
@MainActor
final class BlockLabelOverlay: NSView {
    let labels = TextLayerPool()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 图层托管：这个视图的图层完全由我们自己定，AppKit 不碰它的几何，所以「左上角原点、y 朝下」是确定的，
        // 不会因为宿主视图树（文字视图、滚动视图、SwiftUI 托管）里图层翻转与否不同而上下颠倒。
        let host = CALayer()
        host.isGeometryFlipped = true
        layer = host
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        labels.root.isGeometryFlipped = false
        host.addSublayer(labels.root)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BlockLabelOverlay is created in code only")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labels.root.frame = bounds
        CATransaction.commit()
    }

    /// 一帧的文字改动包在一个关掉隐式动画的事务里，与 Metal 那一帧一起上屏。
    func begin(scale: Double, appearance: NSAppearance) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labels.scale = scale
        labels.appearance = appearance
        labels.begin()
    }

    func end() {
        labels.end()
        CATransaction.commit()
    }
}

private final class EmbedBundleToken {}

/// 本 framework 自己的界面文字（按钮提示、错误条），放在它自己的 `Localizable.strings` 里。
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: Bundle(for: EmbedBundleToken.self), comment: "")
}
