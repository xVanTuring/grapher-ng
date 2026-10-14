import AppKit
import GrapherKit

/// The right column: the editor for the selected layer, then the view settings.
/// Both live in one scroll view because the editor's height changes with the
/// plot kind.
final class InspectorViewController: NSViewController {

    let state: AppState

    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private let layerEditor: LayerEditorViewController
    private let viewSettings: ViewSettingsViewController
    private let relationPane: RelationPaneViewController
    private var observerID: UUID?

    init(state: AppState) {
        self.state = state
        self.layerEditor = LayerEditorViewController(state: state)
        self.viewSettings = ViewSettingsViewController(state: state)
        self.relationPane = RelationPaneViewController(state: state)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("InspectorViewController is created in code only")
    }

    deinit {
        if let observerID { MainActor.assumeIsolated { state.removeObserver(observerID) } }
    }

    override func loadView() {
        let root = FlippedView()
        root.translatesAutoresizingMaskIntoConstraints = false

        addChild(layerEditor)
        addChild(viewSettings)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = ControlFactory.Metric.sectionSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(layerEditor.view)
        // 点线面关系只在立体图里有（面板自己在平面图里藏起来，连同上面那条分隔线）。
        addChild(relationPane)
        contentStack.addArrangedSubview(relationPane.view)
        contentStack.addArrangedSubview(ControlFactory.separator())
        contentStack.addArrangedSubview(viewSettings.view)

        let scroll = ControlFactory.scrolling(contentStack)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        // Same split as the sidebar: the pane reaches the top of the window,
        // the form inside it starts below the floating toolbar.
        let safeArea = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: safeArea.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 286),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observerID = state.observe([.selection, .layers, .document, .errors]) { [weak self] _ in
            self?.layerEditor.reload()
        }
    }
}
