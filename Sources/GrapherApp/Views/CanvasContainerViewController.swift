import AppKit
import GrapherKit

/// 分栏中间那一格：平面图显示 2D 画布，立体图显示 3D 画布。同一扇窗口里打开另一种文档时当场换。
/// 两种画布各自量遮挡宽度（毛玻璃侧栏、工具栏），容器只负责铺满。
/// 讲解中底部浮着讲解卡片（`LessonCardViewController`），卡片占的高度报给 `AppState.reservedBottomInset`。
final class CanvasContainerViewController: NSViewController {

    private let state: AppState
    private lazy var planeCanvas = ViewportViewController(state: state)
    private lazy var spaceCanvas = Viewport3DViewController(state: state)
    private lazy var lessonCard = LessonCardViewController(state: state)
    private var shown: DocumentDimension?
    private var observerID: UUID?
    private var insetSyncScheduled = false

    /// 画布底部状态条的高度（两种画布一样）。
    private static let statusBarHeight: CGFloat = 24
    private static let cardMargin: CGFloat = 12

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CanvasContainerViewController is created in code only")
    }

    deinit {
        if let observerID { MainActor.assumeIsolated { state.removeObserver(observerID) } }
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        showCanvas()
        installLessonCard()
        observerID = state.observe([.document, .lesson]) { [weak self] change in
            if change == .document { self?.showCanvas() }
            self?.syncLessonCard()
        }
        syncLessonCard()
    }

    private func showCanvas() {
        let dimension = state.document.dimension
        guard dimension != shown else { return }
        shown = dimension
        for child in children where child !== lessonCard {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        let canvas: NSViewController = dimension == .space ? spaceCanvas : planeCanvas
        addChild(canvas)
        canvas.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas.view, positioned: .below, relativeTo: lessonCard.isViewLoaded ? lessonCard.view : nil)
        NSLayoutConstraint.activate([
            canvas.view.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.window?.makeFirstResponder(canvas.view)
    }

    /// 卡片贴着画布底部（状态条上方），左右让开毛玻璃侧栏，最宽 860 点、居中。
    private func installLessonCard() {
        addChild(lessonCard)
        lessonCard.onFinishEditing = { [weak self] in self?.focusCanvas() }
        let card = lessonCard.view
        view.addSubview(card)
        let safe = view.safeAreaLayoutGuide
        let margin = Self.cardMargin
        let preferredWidth = card.widthAnchor.constraint(equalToConstant: 860)
        preferredWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -(Self.statusBarHeight + margin)),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: margin),
            card.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -margin),
            card.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 860),
            card.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: margin),
            preferredWidth,
        ])
    }

    /// 键盘焦点交给当前画布里接收按键的那个视图（2D / 3D 的宿主视图）。
    private func focusCanvas() {
        let canvas: NSViewController = shown == .space ? spaceCanvas : planeCanvas
        func responder(in view: NSView) -> NSView? {
            if view.acceptsFirstResponder { return view }
            for subview in view.subviews {
                if let found = responder(in: subview) { return found }
            }
            return nil
        }
        if let target = responder(in: canvas.view) { view.window?.makeFirstResponder(target) }
    }

    private func syncLessonCard() {
        let visible = state.lessonStep != nil
        if lessonCard.view.isHidden == visible { lessonCard.view.isHidden = !visible }
        scheduleInsetSync()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 讲解文字最多占画布高度的三分之一左右。
        lessonCard.maxBodyHeight = max(view.bounds.height * 0.32 - 60, 60)
        scheduleInsetSync()
    }

    /// 卡片的高度是布局算出来的，而画布的遮挡宽度是被观察的状态：不能在布局过程中写，延后一拍。
    private func scheduleInsetSync() {
        guard !insetSyncScheduled else { return }
        insetSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.insetSyncScheduled = false
            let card = self.lessonCard.view
            let reserved = card.isHidden ? 0 : card.frame.height + 2 * Self.cardMargin
            self.state.setReservedBottomInset(reserved)
        }
    }
}
