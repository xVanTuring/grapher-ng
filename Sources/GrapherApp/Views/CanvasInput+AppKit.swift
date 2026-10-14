import AppKit
import GrapherKit

/// 把 `NSEvent` 换成 `CanvasInput` 的参数。App 和 Quick Look 预览扩展都编译这个文件（见 project.yml）。
extension CanvasInput.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: CanvasInput.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }
}

extension CanvasInput.Scroll {
    init(_ event: NSEvent) {
        self.init(
            dx: Double(event.scrollingDeltaX),
            dy: Double(event.scrollingDeltaY),
            isPrecise: event.hasPreciseScrollingDeltas,
            isMomentum: event.momentumPhase != [],
            modifiers: CanvasInput.Modifiers(event.modifierFlags)
        )
    }
}
