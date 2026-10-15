import AppKit
import GrapherKit

/// 讲解卡片：浮在画布底部，写着这一步的标题和讲解（公式按 TeX 排好），带翻页、步骤菜单、编辑与结束按钮。
/// 卡片占的高度经 `AppState.reservedBottomInset` 告诉画布，图形摆在卡片上方没被盖住的那块里。
///
/// 编辑模式：改标题与讲解原文（`$…$` 行内公式、`$$…$$` 单独一行），把眼前的视角与参数记进这一步，
/// 加一步、挪位置、删掉。这一步显示哪些图层由图层列表里的眼睛决定（讲解中眼睛改的是这一步）。
final class LessonCardViewController: NSViewController {

    private let state: AppState
    private var observerID: UUID?

    private let effect = NSVisualEffectView()
    private let stepMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let titleView = LessonTextView()
    private let bodyView = LessonTextView()
    private let bodyScroll = NSScrollView()
    private var bodyHeight: NSLayoutConstraint?

    private lazy var previousButton = button("chevron.left", L("Previous Step (←)"), #selector(previousTapped(_:)))
    private lazy var nextButton = button("chevron.right", L("Next Step (→ or Space)"), #selector(nextTapped(_:)))
    private lazy var editButton = button("pencil", L("Edit This Step"), #selector(editTapped(_:)))
    private lazy var closeButton = button("xmark", L("End Lesson (Esc)"), #selector(closeTapped(_:)))

    private let editStack = NSStackView()
    private let titleField = NSTextField()
    private var textEditor: NSTextView?

    /// 编辑结束：编辑框藏起来了，键盘焦点要交回画布（否则落到图层列表的按钮上，← → 翻不了页）。
    var onFinishEditing: (() -> Void)?

    /// 讲解文字最多占画布高度的这么多，再长就在卡片里滚动。
    var maxBodyHeight: CGFloat = 220 {
        didSet { if maxBodyHeight != oldValue { view.needsLayout = true } }
    }

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LessonCardViewController is created in code only")
    }

    deinit {
        if let observerID { MainActor.assumeIsolated { state.removeObserver(observerID) } }
    }

    // MARK: - 视图

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 14
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            return shadow
        }()

        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(effect)

        stepMenu.controlSize = .small
        stepMenu.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        stepMenu.isBordered = false
        stepMenu.toolTip = L("Jump to a step")
        stepMenu.setContentHuggingPriority(.required, for: .horizontal)
        stepMenu.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleView.fontSize = 15
        titleView.bold = true
        titleView.translatesAutoresizingMaskIntoConstraints = false
        titleView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttons = ControlFactory.stack([previousButton, nextButton, editButton, closeButton],
                                           orientation: .horizontal, spacing: 10, alignment: .centerY)
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        let header = ControlFactory.stack([stepMenu, titleView, buttons], orientation: .horizontal, spacing: 10,
                                          alignment: .top)

        bodyView.fontSize = 14
        bodyView.translatesAutoresizingMaskIntoConstraints = true
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        bodyScroll.drawsBackground = false
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.documentView = bodyView
        let height = bodyScroll.heightAnchor.constraint(equalToConstant: 40)
        bodyHeight = height

        buildEditor()

        let content = ControlFactory.stack([header, bodyScroll, editStack], spacing: 8, alignment: .width)
        effect.addSubview(content)

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: root.topAnchor),
            effect.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            effect.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -12),
            height,
            titleView.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
        view = root
    }

    private func buildEditor() {
        titleField.placeholderString = L("Step title")
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        if let editor = scroll.documentView as? NSTextView {
            editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            editor.isRichText = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.allowsUndo = true
            textEditor = editor
        }
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        let hint = ControlFactory.caption(
            L("Inline formula: $…$; a formula on its own line: $$…$$; **bold**. The eye buttons in the layer list choose which layers this step shows."))

        let record = ControlFactory.pushButton(L("Record View and Parameters"), target: self, action: #selector(recordTapped(_:)))
        record.toolTip = L("Store the current camera and every parameter value in this step")
        let add = ControlFactory.pushButton(L("Add Step After"), target: self, action: #selector(addTapped(_:)))
        let earlier = button("arrow.up", L("Move Step Earlier"), #selector(earlierTapped(_:)))
        let later = button("arrow.down", L("Move Step Later"), #selector(laterTapped(_:)))
        let delete = ControlFactory.pushButton(L("Delete Step"), target: self, action: #selector(deleteTapped(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let done = ControlFactory.pushButton(L("Done"), target: self, action: #selector(doneTapped(_:)))
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = [.command]
        let actions = ControlFactory.stack([record, add, earlier, later, delete, spacer, done],
                                           orientation: .horizontal, spacing: 6, alignment: .centerY)

        editStack.orientation = .vertical
        editStack.alignment = .width
        editStack.spacing = 6
        editStack.translatesAutoresizingMaskIntoConstraints = false
        for view in [titleField, scroll, hint, actions] { editStack.addArrangedSubview(view) }
    }

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = ControlFactory.symbolButton(symbol: symbol, target: self, action: action, tooltip: tip, accessibility: tip)
        button.controlSize = .regular
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observerID = state.observe([.lesson, .document]) { [weak self] _ in self?.reload() }
        reload()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 讲解文字按卡片的宽度排，超过上限就在卡片里滚动。
        let width = bodyScroll.contentSize.width
        guard width > 1 else { return }
        let height = bodyView.height(forWidth: width)
        if abs(bodyView.frame.width - width) > 0.5 || abs(bodyView.frame.height - height) > 0.5 {
            bodyView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
        let visible = min(height, maxBodyHeight)
        if let bodyHeight, abs(bodyHeight.constant - visible) > 0.5 {
            bodyHeight.constant = visible
        }
    }

    // MARK: - 内容

    private func reload() {
        guard let index = state.lessonStep, let step = state.currentLessonStep else { return }
        let count = state.document.lessonSteps.count
        rebuildStepMenu(current: index, count: count)
        titleView.text = step.title.isEmpty ? String(format: L("Step %ld"), index + 1) : step.title
        bodyView.text = step.text
        bodyScroll.isHidden = state.lessonEditing || step.text.isEmpty
        editStack.isHidden = !state.lessonEditing
        previousButton.isEnabled = index > 0
        nextButton.isEnabled = index + 1 < count
        editButton.contentTintColor = state.lessonEditing ? .controlAccentColor : nil
        if state.lessonEditing {
            titleField.stringValue = step.title
            if textEditor?.string != step.text { textEditor?.string = step.text }
        }
        bodyScroll.contentView.scroll(to: .zero)
        view.needsLayout = true
    }

    private func rebuildStepMenu(current: Int, count: Int) {
        let menu = NSMenu()
        // 下拉按钮的第一项是按钮上显示的字。
        menu.addItem(withTitle: String(format: L("%ld / %ld"), current + 1, count), action: nil, keyEquivalent: "")
        for (index, step) in state.document.lessonSteps.enumerated() {
            let title = step.title.isEmpty ? String(format: L("Step %ld"), index + 1) : step.title
            let item = NSMenuItem(title: "\(index + 1). \(title)", action: #selector(stepChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == current ? .on : .off
            menu.addItem(item)
        }
        stepMenu.menu = menu
    }

    /// 编辑中翻页 / 结束之前，先把输入框里的字存进这一步。
    private func commitEdits() {
        guard state.lessonEditing, let step = state.currentLessonStep else { return }
        let title = titleField.stringValue
        let text = textEditor?.string ?? step.text
        if title != step.title || text != step.text {
            state.updateLessonStep(title: title, text: text)
        }
    }

    // MARK: - 按钮

    @objc private func previousTapped(_ sender: Any?) {
        commitEdits()
        state.previousStep()
    }

    @objc private func nextTapped(_ sender: Any?) {
        commitEdits()
        state.nextStep()
    }

    @objc private func stepChosen(_ sender: NSMenuItem) {
        commitEdits()
        state.goToStep(sender.tag)
    }

    @objc private func editTapped(_ sender: Any?) {
        if state.lessonEditing { commitEdits() }
        state.setLessonEditing(!state.lessonEditing)
        if state.lessonEditing {
            view.window?.makeFirstResponder(textEditor)
        } else {
            onFinishEditing?()
        }
    }

    @objc private func closeTapped(_ sender: Any?) {
        commitEdits()
        state.endLesson()
        onFinishEditing?()
    }

    @objc private func doneTapped(_ sender: Any?) {
        commitEdits()
        state.setLessonEditing(false)
        onFinishEditing?()
    }

    @objc private func recordTapped(_ sender: Any?) {
        commitEdits()
        state.recordViewIntoStep()
    }

    @objc private func addTapped(_ sender: Any?) {
        commitEdits()
        state.addLessonStep()
        view.window?.makeFirstResponder(titleField)
    }

    @objc private func earlierTapped(_ sender: Any?) {
        commitEdits()
        state.moveLessonStep(by: -1)
    }

    @objc private func laterTapped(_ sender: Any?) {
        commitEdits()
        state.moveLessonStep(by: 1)
    }

    @objc private func deleteTapped(_ sender: Any?) {
        state.deleteLessonStep()
    }
}
