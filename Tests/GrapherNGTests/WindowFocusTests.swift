import XCTest
@testable import GrapherNG

/// 设置窗口与欢迎窗口显示时，焦点不能落在某个控件上（否则总有一个按钮或输入框被框住）。
@MainActor
final class WindowFocusTests: XCTestCase {

    func testSettingsWindowDoesNotSelectAControl() throws {
        MCPSettingsWindowController.show()
        let window = try XCTUnwrap(MCPSettingsWindowController.shared.window)
        defer { window.close() }
        XCTAssertTrue(window.firstResponder is FocusAnchorView, "焦点落在 \(String(describing: window.firstResponder))")
    }

    func testWelcomeWindowDoesNotSelectAControl() throws {
        WelcomeWindowController.show()
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == L("Welcome to Grapher NG") })
        defer { WelcomeWindowController.close() }
        XCTAssertTrue(window.firstResponder is FocusAnchorView, "焦点落在 \(String(describing: window.firstResponder))")
    }
}
