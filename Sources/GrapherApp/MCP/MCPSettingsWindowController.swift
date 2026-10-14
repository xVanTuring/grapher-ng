import AppKit

/// 设置窗口（Grapher NG ▸ 设置…，⌘,）：目前只有 AI 接入（MCP）一页。
/// 版式仿系统设置：分组卡片、一行一项、开关靠右。开关立即生效，不用重启；端口改了会自动重启监听。
@MainActor
final class MCPSettingsWindowController: NSWindowController, NSTextFieldDelegate {

    static let shared = MCPSettingsWindowController()

    /// 由 `AppDelegate` 在启动时设置。
    weak var server: MCPServer?

    private enum Metric {
        static let width: CGFloat = 540
        static let margin: CGFloat = 24
        static let rowInset = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        static var cardInnerWidth: CGFloat { width - margin * 2 - rowInset.left - rowInset.right }
    }

    private let enableSwitch = NSSwitch()
    private let writeSwitch = NSSwitch()
    private let statusLabel = NSTextField(labelWithString: "")
    private let portField = NSTextField()
    private let tokenLabel = NSTextField(labelWithString: "")
    private let revealButton = NSButton()
    private let copyTokenButton = NSButton()
    private let snippetPicker = NSSegmentedControl()
    private let snippetLabel = NSTextField(wrappingLabelWithString: "")
    private let copySnippetButton = NSButton()
    private var rootStack = NSStackView()

    private var revealsToken = false
    private var observer: NSObjectProtocol?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metric.width, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = L("Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent(in: window)
        observer = NotificationCenter.default.addObserver(
            forName: MCPServer.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func show() {
        let controller = shared
        controller.refresh()
        if controller.window?.isVisible != true { controller.window?.center() }
        controller.showWindow(nil)
        NSApp.activate()
    }

    // MARK: - Layout

    private func buildContent(in window: NSWindow) {
        enableSwitch.target = self
        enableSwitch.action = #selector(toggleEnabled(_:))
        writeSwitch.target = self
        writeSwitch.action = #selector(toggleWrite(_:))

        statusLabel.font = .systemFont(ofSize: 11)

        portField.alignment = .right
        portField.delegate = self
        portField.controlSize = .small
        portField.widthAnchor.constraint(equalToConstant: 72).isActive = true

        tokenLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tokenLabel.lineBreakMode = .byTruncatingMiddle
        tokenLabel.isSelectable = true
        tokenLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configure(revealButton, title: L("Show"), action: #selector(toggleReveal(_:)))
        configure(copyTokenButton, title: L("Copy"), action: #selector(copyToken(_:)))
        let regenerate = NSButton()
        configure(regenerate, title: L("Regenerate Token"), action: #selector(regenerateToken(_:)))
        let tokenButtons = NSStackView(views: [revealButton, copyTokenButton, regenerate])
        tokenButtons.spacing = 6

        snippetPicker.segmentCount = 2
        snippetPicker.setLabel(L("Claude Code"), forSegment: 0)
        snippetPicker.setLabel(L("JSON"), forSegment: 1)
        snippetPicker.selectedSegment = 0
        snippetPicker.segmentStyle = .rounded
        snippetPicker.trackingMode = .selectOne
        snippetPicker.target = self
        snippetPicker.action = #selector(snippetChanged(_:))
        configure(copySnippetButton, title: L("Copy"), action: #selector(copySnippet(_:)))
        let pickerRow = NSStackView(views: [snippetPicker, NSView(), copySnippetButton])
        pickerRow.distribution = .fill

        snippetLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        snippetLabel.isSelectable = true
        snippetLabel.lineBreakMode = .byCharWrapping
        snippetLabel.maximumNumberOfLines = 0
        snippetLabel.preferredMaxLayoutWidth = Metric.cardInnerWidth

        let accessCard = card([
            row(title: L("Enable MCP server"), detail: statusLabel, trailing: enableSwitch),
            row(title: L("Port"), trailing: portField),
            row(
                title: L("Allow AI to modify graphs"),
                detail: caption(L("When off, the AI can only read documents and render images. Changes it makes can be undone with ⌘Z.")),
                trailing: writeSwitch
            ),
        ])
        let tokenCard = card([
            row(content: tokenLabel, trailing: tokenButtons),
        ])
        let snippetCard = card([padded(snippetLabel)])

        rootStack = NSStackView(views: [
            sectionHeader(L("AI Access")),
            accessCard,
            note(L("Lets an AI assistant such as Claude Code draw graphs in your documents. Only this Mac can connect.")),
            sectionHeader(L("Access Token")),
            tokenCard,
            note(L("Every request must carry this token. Regenerating it disconnects clients that use the old one.")),
            sectionHeader(L("Connect a Client")),
            pickerRow,
            snippetCard,
        ])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 6
        rootStack.setCustomSpacing(18, after: rootStack.views[2])
        rootStack.setCustomSpacing(18, after: rootStack.views[5])
        rootStack.setCustomSpacing(8, after: rootStack.views[6])
        rootStack.edgeInsets = NSEdgeInsets(top: 20, left: Metric.margin, bottom: 24, right: Metric.margin)
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        // 卡片、分段控件那一行都撑满整行宽。
        for view in [accessCard, tokenCard, snippetCard, pickerRow] {
            view.widthAnchor.constraint(equalToConstant: Metric.width - Metric.margin * 2).isActive = true
        }

        let content = NSView()
        content.addSubview(rootStack)
        window.contentView = content
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: content.topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: Metric.width),
        ])
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = action
    }

    private func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Metric.cardInnerWidth - 80
        return label
    }

    /// 卡片外的说明文字：左右各缩进一点，和卡片里的文字对齐。
    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Metric.width - Metric.margin * 2
        return label
    }

    /// 一行：左边标题（可带一行说明），右边是控件。
    private func row(title: String, detail: NSView? = nil, trailing: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13)
        var leading: [NSView] = [titleLabel]
        if let detail { leading.append(detail) }
        let text = NSStackView(views: leading)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        return row(content: text, trailing: trailing)
    }

    private func row(content: NSView, trailing: NSView) -> NSView {
        content.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 标题靠左、控件靠右：分别放进左 / 右两个 gravity 区，中间的空隙留给窗口宽度。
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.distribution = .gravityAreas
        stack.setViews([content], in: .leading)
        stack.setViews([trailing], in: .trailing)
        return padded(stack)
    }

    private func padded(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: Metric.rowInset.top),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Metric.rowInset.bottom),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metric.rowInset.left),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Metric.rowInset.right),
        ])
        return container
    }

    /// 圆角卡片，行与行之间一条细分隔线。
    private func card(_ rows: [NSView]) -> NSView {
        var views: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                views.append(line)
            }
            views.append(row)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.titlePosition = .noTitle
        box.contentViewMargins = .zero
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        box.contentView = content
        return box
    }

    // MARK: - State

    private var endpoint: String { "http://127.0.0.1:\(MCPSettings.port)/mcp" }

    /// 令牌遮住时，十六进制字符换成圆点、只留最后四位：屏幕上和截图里都不会泄露。
    private var displayedToken: String {
        let token = MCPSettings.token
        guard !revealsToken else { return token }
        let visible = token.suffix(4)
        let hidden = token.dropLast(4).map { $0.isHexDigit ? "•" : String($0) }.joined()
        return hidden + visible
    }

    private func cliSnippet(token: String) -> String {
        "claude mcp add --transport http grapher-ng \(endpoint) --header \"Authorization: Bearer \(token)\""
    }

    private func jsonSnippet(token: String) -> String {
        """
        {
          "mcpServers": {
            "grapher-ng": {
              "type": "http",
              "url": "\(endpoint)",
              "headers": {
                "Authorization": "Bearer \(token)"
              }
            }
          }
        }
        """
    }

    private func snippet(token: String) -> String {
        snippetPicker.selectedSegment == 0 ? cliSnippet(token: token) : jsonSnippet(token: token)
    }

    private func refresh() {
        enableSwitch.state = MCPSettings.isEnabled ? .on : .off
        writeSwitch.state = MCPSettings.allowsWrite ? .on : .off
        if !(window?.firstResponder is NSTextView) { portField.stringValue = "\(MCPSettings.port)" }
        tokenLabel.stringValue = displayedToken
        revealButton.title = revealsToken ? L("Hide") : L("Show")
        snippetLabel.stringValue = snippet(token: displayedToken)
        refreshStatus()
        fitWindowToContent()
    }

    private func refreshStatus() {
        let dotColor: NSColor
        let text: String
        if let error = server?.lastError, server?.isRunning != true {
            text = String(format: L("Not running: %@"), error)
            dotColor = .systemOrange
        } else if server?.isRunning == true, let port = server?.listeningPort {
            text = String(format: L("Running on 127.0.0.1:%ld"), port)
            dotColor = .systemGreen
        } else {
            text = L("Stopped")
            dotColor = .tertiaryLabelColor
        }
        let attributed = NSMutableAttributedString(
            string: "● ", attributes: [.foregroundColor: dotColor, .font: NSFont.systemFont(ofSize: 11)]
        )
        attributed.append(NSAttributedString(
            string: text,
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]
        ))
        statusLabel.attributedStringValue = attributed
    }

    /// 内容高度会随连接片段（命令 3 行 / JSON 9 行）和状态文字变化：窗口跟着长高变矮，左上角不动。
    private func fitWindowToContent() {
        guard let window else { return }
        rootStack.layoutSubtreeIfNeeded()
        let height = rootStack.fittingSize.height
        let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Metric.width, height: height))
        guard abs(target.height - window.frame.height) > 0.5 else { return }
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size.height = target.height
        window.setFrame(frame, display: window.isVisible, animate: window.isVisible)
    }

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: NSSwitch) {
        MCPSettings.isEnabled = sender.state == .on
        if MCPSettings.isEnabled { server?.start() } else { server?.stop() }
        refresh()
    }

    @objc private func toggleWrite(_ sender: NSSwitch) {
        MCPSettings.allowsWrite = sender.state == .on
    }

    /// 端口输入框回车或失焦时生效：范围外的值退回当前端口。端口改了要重启监听才生效。
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let value = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)),
              (1024...65535).contains(value)
        else {
            portField.stringValue = "\(MCPSettings.port)"
            return
        }
        guard value != MCPSettings.port else { return }
        MCPSettings.port = value
        if MCPSettings.isEnabled { server?.restart() }
        refresh()
    }

    @objc private func toggleReveal(_ sender: Any?) {
        revealsToken.toggle()
        refresh()
    }

    @objc private func snippetChanged(_ sender: Any?) {
        refresh()
    }

    /// 复制的永远是真实令牌，不管屏幕上有没有遮住。
    @objc private func copyToken(_ sender: NSButton) { copy(MCPSettings.token, from: sender) }
    @objc private func copySnippet(_ sender: NSButton) { copy(snippet(token: MCPSettings.token), from: sender) }

    @objc private func regenerateToken(_ sender: Any?) {
        MCPSettings.regenerateToken()
        refresh()
    }

    private func copy(_ text: String, from button: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let original = L("Copy")
        button.title = L("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak button] in
            button?.title = original
        }
    }
}
