import AppKit

/// 欢迎窗口里可点的一块（大按钮、最近文档的一行）：悬停时底色加深，单击执行 `onClick`。
/// 子视图（图标、文字）一律不接鼠标，整块都是点击区；也不跟着「拖背景移动窗口」走。
class WelcomeCardView: NSView {
    var onClick: (() -> Void)?

    /// 平时 / 悬停 / 按下时的底色浓度（`labelColor` 的不透明度，深浅色外观下都成立）。
    var restingAlpha: CGFloat = 0
    var hoverAlpha: CGFloat = 0.07
    var pressedAlpha: CGFloat = 0.12
    var cornerRadius: CGFloat = 8

    private var isHovering = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WelcomeCardView is created in code only")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha = isPressed ? pressedAlpha : (isHovering ? hoverAlpha : restingAlpha)
        guard alpha > 0 else { return }
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
}

/// 左边的大按钮：强调色图标 + 标题 + 一行说明。
final class WelcomeActionView: WelcomeCardView {
    init(symbol: String, title: String, detail: String) {
        super.init(frame: .zero)
        restingAlpha = 0.05
        hoverAlpha = 0.1
        pressedAlpha = 0.15
        cornerRadius = 9
        setAccessibilityLabel(title)
        setAccessibilityHelp(detail)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .regular))
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(text)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }
}

/// 最近文档的一行：缩略图、名称、所在文件夹、修改时间。单击打开，右键有「在访达中显示」「移除」等。
final class RecentGraphRow: WelcomeCardView {
    let url: URL
    var onRemove: (() -> Void)?
    var onClearAll: (() -> Void)?
    private let thumbnail = ThumbnailView()

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        toolTip = url.path
        setAccessibilityLabel(url.deletingPathExtension().lastPathComponent)

        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        thumbnail.placeholder = NSWorkspace.shared.icon(forFile: url.path)

        let name = NSTextField(labelWithString: url.deletingPathExtension().lastPathComponent)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        let folder = NSTextField(labelWithString:
            (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        folder.font = .systemFont(ofSize: 11)
        folder.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingMiddle
        for label in [name, folder] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let text = NSStackView(views: [name, folder])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.translatesAutoresizingMaskIntoConstraints = false

        let date = NSTextField(labelWithString: modified.map { RecentGraphs.relativeDate($0) } ?? "")
        date.font = .systemFont(ofSize: 11)
        date.textColor = .tertiaryLabelColor
        date.translatesAutoresizingMaskIntoConstraints = false
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        date.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(thumbnail)
        addSubview(text)
        addSubview(date)
        let size = RecentGraphs.thumbnailSize
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            thumbnail.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            thumbnail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            thumbnail.widthAnchor.constraint(equalToConstant: size.width),
            thumbnail.heightAnchor.constraint(equalToConstant: size.height),
            text.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: date.leadingAnchor, constant: -8),
            date.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            date.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        RecentGraphs.thumbnail(for: url, modified: modified) { [weak self] image in
            self?.thumbnail.image = image
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [
            (L("Open"), #selector(openItem(_:))),
            (L("Show in Finder"), #selector(showInFinder(_:))),
            (nil, nil),
            (L("Remove from Recent Graphs"), #selector(removeItem(_:))),
            (L("Clear Recent Graphs"), #selector(clearAll(_:))),
        ] as [(String?, Selector?)] {
            guard let title else {
                menu.addItem(.separator())
                continue
            }
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    @objc private func openItem(_ sender: Any?) { onClick?() }
    @objc private func showInFinder(_ sender: Any?) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    @objc private func removeItem(_ sender: Any?) { onRemove?() }
    @objc private func clearAll(_ sender: Any?) { onClearAll?() }
}

/// 圆角缩略图，带一圈细描边。没有缩略图时居中画文件图标。描边与底色在 `draw` 里取动态颜色，
/// 切换深浅色外观时自动跟上。
final class ThumbnailView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var placeholder: NSImage? { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ThumbnailView is created in code only")
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        if let image {
            // 铺满、多出的裁掉。
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                  width: size.width, height: size.height))
        } else if let placeholder {
            let side = bounds.height - 12
            placeholder.draw(in: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side))
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

/// 右边那一栏的底色：比左边略深一点（同 FreeMind）。
final class TintedPaneView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.03).setFill()
        bounds.fill()
    }
}
