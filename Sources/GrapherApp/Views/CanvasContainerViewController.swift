import AppKit
import GrapherKit

/// 分栏中间那一格：平面图显示 2D 画布，立体图显示 3D 画布。同一扇窗口里打开另一种文档时当场换。
/// 两种画布各自量遮挡宽度（毛玻璃侧栏、工具栏），容器只负责铺满。
final class CanvasContainerViewController: NSViewController {

    private let state: AppState
    private lazy var planeCanvas = ViewportViewController(state: state)
    private lazy var spaceCanvas = Viewport3DViewController(state: state)
    private var shown: DocumentDimension?
    private var observerID: UUID?

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
        observerID = state.observe([.document]) { [weak self] _ in self?.showCanvas() }
    }

    private func showCanvas() {
        let dimension = state.document.dimension
        guard dimension != shown else { return }
        shown = dimension
        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        let canvas: NSViewController = dimension == .space ? spaceCanvas : planeCanvas
        addChild(canvas)
        canvas.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas.view)
        NSLayoutConstraint.activate([
            canvas.view.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.window?.makeFirstResponder(canvas.view)
    }
}
