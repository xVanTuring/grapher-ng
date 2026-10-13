import AppKit
import GrapherKit

/// A titled formula entry. While the compiler rejects the formula, the raw
/// text, a caret line pointing at the offending column and the message are
/// shown underneath the field.
final class FormulaFieldView: NSView, NSTextFieldDelegate {

    var onLiveChange: ((String) -> Void)?
    var onCommit: ((String) -> Void)?

    var text: String {
        get { field.stringValue }
        set {
            // Never take the text away from the user mid-keystroke.
            guard field.currentEditor() == nil else { return }
            isApplyingText = true
            field.stringValue = newValue
            isApplyingText = false
        }
    }

    var error: ExpressionError? {
        didSet { updateDiagnostics() }
    }

    private let field = ControlFactory.textField(monospaced: true)
    private let sourceLabel = ControlFactory.monospacedLabel("")
    private let caretLabel = ControlFactory.monospacedLabel("")
    private let messageLabel = ControlFactory.monospacedLabel("")
    private var isApplyingText = false

    init(title: String, placeholder: String) {
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = placeholder
        field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.lineBreakMode = .byTruncatingTail
        caretLabel.textColor = ControlFactory.Palette.error
        messageLabel.textColor = ControlFactory.Palette.error
        messageLabel.lineBreakMode = .byTruncatingTail

        let stack = ControlFactory.stack(
            [ControlFactory.sectionLabel(title), field, sourceLabel, caretLabel, messageLabel],
            spacing: 4
        )
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            field.heightAnchor.constraint(equalToConstant: ControlFactory.Metric.fieldHeight),
        ])

        updateDiagnostics()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FormulaFieldView is created in code only")
    }

    // MARK: - Editing

    func controlTextDidChange(_ notification: Notification) {
        guard !isApplyingText else { return }
        onLiveChange?(field.stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        onCommit?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        onCommit?(field.stringValue)
        return true
    }

    private func updateDiagnostics() {
        guard let error else {
            sourceLabel.isHidden = true
            caretLabel.isHidden = true
            messageLabel.isHidden = true
            return
        }
        sourceLabel.stringValue = field.stringValue
        caretLabel.stringValue = String(repeating: " ", count: max(0, error.column))
            + String(repeating: "^", count: max(1, error.length))
        messageLabel.stringValue = error.description
        sourceLabel.isHidden = false
        caretLabel.isHidden = false
        messageLabel.isHidden = false
    }
}
