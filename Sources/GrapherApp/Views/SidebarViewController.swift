import AppKit
import GrapherKit

/// The left column: the layer list on top, the parameter sliders below it.
final class SidebarViewController: NSViewController {

    let state: AppState

    private let layerList: LayerListViewController
    private let parameterPanel: ParameterPanelViewController
    private let divider = NSSplitView()

    init(state: AppState) {
        self.state = state
        self.layerList = LayerListViewController(state: state)
        self.parameterPanel = ParameterPanelViewController(state: state)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarViewController is created in code only")
    }

    override func loadView() {
        let root = FlippedView()
        root.translatesAutoresizingMaskIntoConstraints = false

        divider.isVertical = false
        divider.dividerStyle = .thin
        divider.translatesAutoresizingMaskIntoConstraints = false

        addChild(layerList)
        addChild(parameterPanel)

        divider.addArrangedSubview(layerList.view)
        divider.addArrangedSubview(parameterPanel.view)

        layerList.view.translatesAutoresizingMaskIntoConstraints = false
        parameterPanel.view.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(divider)
        // The sidebar's *material* runs to the very top of the window, but its
        // content must clear the floating toolbar — otherwise the first row
        // lands underneath the traffic lights. Pinning to the safe area is what
        // splits those two apart.
        let safeArea = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: safeArea.topAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
        divider.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Give the layer list about two thirds of the height on first show.
        let height = divider.bounds.height
        if height > 0, divider.subviews.first?.frame.height ?? 0 < 40 {
            divider.setPosition(height * 0.62, ofDividerAt: 0)
        }
    }
}
