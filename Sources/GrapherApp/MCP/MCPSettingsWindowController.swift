import AppKit

/// 设置窗口（Grapher NG ▸ 设置…，⌘,）：目前只有 AI 接入（MCP）一页。
/// 开关立即生效，不用重启；端口改了会自动重启监听。
@MainActor
final class MCPSettingsWindowController: NSWindowController, NSTextFieldDelegate {

    static let shared = MCPSettingsWindowController()

    /// 由 `AppDelegate` 在启动时设置。
    weak var server: MCPServer?

    private let enableCheckbox = NSButton(checkboxWithTitle: L("Enable MCP server"), target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let portField = NSTextField()
    private let writeCheckbox = NSButton(checkboxWithTitle: L("Allow AI to modify graphs"), target: nil, action: nil)
    private let tokenLabel = NSTextField(labelWithString: "")
    private let cliText = NSTextField(wrappingLabelWithString: "")
    private let jsonText = NSTextField(wrappingLabelWithString: "")
    private let copiedLabel = NSTextField(labelWithString: "")
    private var observer: NSObjectProtocol?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
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
        enableCheckbox.target = self
        enableCheckbox.action = #selector(toggleEnabled(_:))
        writeCheckbox.target = self
        writeCheckbox.action = #selector(toggleWrite(_:))

        statusLabel.font = .systemFont(ofSize: 11)
        portField.alignment = .right
        portField.delegate = self
        portField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let portRow = NSStackView(views: [NSTextField(labelWithString: L("Port")), portField])
        portRow.spacing = 8

        tokenLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tokenLabel.isSelectable = true
        tokenLabel.lineBreakMode = .byTruncatingMiddle
        let copyToken = NSButton(title: L("Copy Token"), target: self, action: #selector(copyToken(_:)))
        let regenerate = NSButton(title: L("Regenerate Token"), target: self, action: #selector(regenerateToken(_:)))
        let tokenButtons = NSStackView(views: [copyToken, regenerate])
        tokenButtons.spacing = 8

        for field in [cliText, jsonText] {
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.isSelectable = true
            field.maximumNumberOfLines = 0
        }
        let copyCLI = NSButton(title: L("Copy Command"), target: self, action: #selector(copyCLI(_:)))
        let copyJSON = NSButton(title: L("Copy JSON"), target: self, action: #selector(copyJSON(_:)))

        copiedLabel.font = .systemFont(ofSize: 11)
        copiedLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            enableCheckbox,
            statusLabel,
            ControlFactory.caption(L("Lets an AI assistant such as Claude Code draw graphs in your documents. Only this Mac can connect.")),
            portRow,
            writeCheckbox,
            ControlFactory.caption(L("When off, the AI can only read documents and render images. Changes it makes can be undone with ⌘Z.")),
            ControlFactory.sectionLabel(L("Access Token")),
            tokenLabel,
            tokenButtons,
            ControlFactory.caption(L("Every request must carry this token. Regenerating it disconnects clients that use the old one.")),
            ControlFactory.sectionLabel(L("Claude Code")),
            cliText,
            copyCLI,
            ControlFactory.sectionLabel(L("Other clients (JSON)")),
            jsonText,
            copyJSON,
            copiedLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: statusLabel)
        stack.setCustomSpacing(16, after: portRow)
        stack.setCustomSpacing(16, after: writeCheckbox)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 560),
        ])
        for field in [cliText, jsonText] {
            field.preferredMaxLayoutWidth = 520
        }
    }

    // MARK: - State

    private var endpoint: String { "http://127.0.0.1:\(MCPSettings.port)/mcp" }

    private var cliSnippet: String {
        "claude mcp add --transport http grapher-ng \(endpoint) --header \"Authorization: Bearer \(MCPSettings.token)\""
    }

    private var jsonSnippet: String {
        """
        {
          "mcpServers": {
            "grapher-ng": {
              "type": "http",
              "url": "\(endpoint)",
              "headers": { "Authorization": "Bearer \(MCPSettings.token)" }
            }
          }
        }
        """
    }

    private func refresh() {
        enableCheckbox.state = MCPSettings.isEnabled ? .on : .off
        writeCheckbox.state = MCPSettings.allowsWrite ? .on : .off
        if !(window?.firstResponder is NSTextView) { portField.stringValue = "\(MCPSettings.port)" }
        tokenLabel.stringValue = MCPSettings.token
        cliText.stringValue = cliSnippet
        jsonText.stringValue = jsonSnippet

        if let error = server?.lastError, server?.isRunning != true {
            statusLabel.stringValue = String(format: L("Not running: %@"), error)
            statusLabel.textColor = .systemOrange
        } else if server?.isRunning == true, let port = server?.listeningPort {
            statusLabel.stringValue = String(format: L("Running on 127.0.0.1:%ld"), port)
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.stringValue = L("Stopped")
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: NSButton) {
        MCPSettings.isEnabled = sender.state == .on
        if MCPSettings.isEnabled { server?.start() } else { server?.stop() }
        refresh()
    }

    @objc private func toggleWrite(_ sender: NSButton) {
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

    @objc private func copyToken(_ sender: Any?) { copy(MCPSettings.token) }
    @objc private func copyCLI(_ sender: Any?) { copy(cliSnippet) }
    @objc private func copyJSON(_ sender: Any?) { copy(jsonSnippet) }

    @objc private func regenerateToken(_ sender: Any?) {
        MCPSettings.regenerateToken()
        refresh()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedLabel.stringValue = L("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copiedLabel.stringValue = ""
        }
    }
}
