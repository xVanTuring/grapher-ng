import AppKit
import GrapherKit

/// A container that lays its subviews out from the top down, which is what an
/// `NSStackView` needs when it is the document view of a scroll view.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One place where the chrome's metrics and control styling live, so the
/// sidebar, the inspector and the toolbar all end up looking like one app.
enum ControlFactory {
    enum Metric {
        static let gutter: CGFloat = 12
        static let rowSpacing: CGFloat = 6
        static let sectionSpacing: CGFloat = 14
        static let labelWidth: CGFloat = 62
        static let fieldHeight: CGFloat = 22
        static let layerRowHeight: CGFloat = 44
    }

    enum Palette {
        static let section = NSColor.secondaryLabelColor
        static let caption = NSColor.tertiaryLabelColor
        static let error = NSColor.systemRed
    }

    // MARK: - Text

    static func sectionLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = Palette.section
        return field
    }

    static func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        return field
    }

    static func caption(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = Palette.caption
        return field
    }

    static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.alignment = .right
        return field
    }

    static func monospacedLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.textColor = Palette.caption
        return field
    }

    // MARK: - Controls

    static func textField(
        _ text: String = "",
        placeholder: String = "",
        monospaced: Bool = false,
        target: AnyObject? = nil,
        action: Selector? = nil
    ) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.font = monospaced
            ? .monospacedSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12)
        field.controlSize = .small
        field.usesSingleLineMode = true
        if let action {
            field.target = target
            field.action = action
        }
        return field
    }

    static func numberField(
        _ value: Double,
        target: AnyObject?,
        action: Selector?
    ) -> NSTextField {
        let field = NSTextField(string: format(value))
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.controlSize = .small
        field.alignment = .right
        field.target = target
        field.action = action
        return field
    }

    static func pushButton(
        _ title: String,
        target: AnyObject?,
        action: Selector,
        bezel: NSButton.BezelStyle = .rounded
    ) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = bezel
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        return button
    }

    static func symbolButton(
        symbol: String,
        target: AnyObject?,
        action: Selector,
        tooltip: String,
        accessibility: String
    ) -> NSButton {
        let button = NSButton(image: .init(), target: target, action: action)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility) {
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.title = accessibility
            button.imagePosition = .noImage
        }
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.isBordered = false
        button.toolTip = tooltip
        return button
    }

    static func checkbox(
        _ title: String,
        target: AnyObject?,
        action: Selector
    ) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: target, action: action)
        button.font = .systemFont(ofSize: 12)
        return button
    }

    static func popUp(
        items: [String],
        target: AnyObject?,
        action: Selector
    ) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: items)
        button.target = target
        button.action = action
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        return button
    }

    static func slider(
        value: Double,
        range: ClosedRange<Double>,
        target: AnyObject?,
        action: Selector
    ) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: target,
            action: action
        )
        slider.isContinuous = true
        slider.controlSize = .small
        return slider
    }

    static func colorWell(
        _ color: NSColor,
        target: AnyObject?,
        action: Selector
    ) -> NSColorWell {
        let well = NSColorWell()
        well.color = color
        well.target = target
        well.action = action
        well.controlSize = .small
        return well
    }

    // MARK: - Layout

    static func stack(
        _ views: [NSView],
        orientation: NSUserInterfaceLayoutOrientation = .vertical,
        spacing: CGFloat = Metric.rowSpacing,
        alignment: NSLayoutConstraint.Attribute = .leading
    ) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.spacing = spacing
        stack.alignment = alignment
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    /// A label/control pair laid out so the labels line up in a column.
    static func formRow(_ label: String, _ control: NSView) -> NSStackView {
        let title = self.label(label)
        title.setContentHuggingPriority(.required, for: .horizontal)
        title.widthAnchor.constraint(equalToConstant: Metric.labelWidth).isActive = true
        let row = stack([title, control], orientation: .horizontal, spacing: 8)
        row.alignment = .firstBaseline
        return row
    }

    /// Wraps a stack in a scroll view that grows downwards.
    static func scrolling(_ content: NSView, spacing: CGFloat = Metric.sectionSpacing) -> NSScrollView {
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.documentView = document

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: spacing),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Metric.gutter),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -Metric.gutter),
            content.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -spacing),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    // MARK: - Conversion

    static func nsColor(_ color: RGBAColor) -> NSColor {
        NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a)
    }

    static func rgbaColor(_ color: NSColor) -> RGBAColor {
        let converted = color.usingColorSpace(.sRGB) ?? .black
        return RGBAColor(
            Double(converted.redComponent),
            Double(converted.greenComponent),
            Double(converted.blueComponent),
            Double(converted.alphaComponent)
        )
    }

    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value == value.rounded() && abs(value) < 1e9 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.6g", value)
    }

    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let value = Double(trimmed) { return value }
        // Accept the same constants the formula language does, so a domain can
        // be typed as "-pi" or "2*pi".
        if let expression = try? CompiledExpression(
            source: trimmed,
            context: ExpressionContext(variables: [])
        ) {
            let value = expression.evaluate([])
            return value.isFinite ? value : nil
        }
        return nil
    }
}
