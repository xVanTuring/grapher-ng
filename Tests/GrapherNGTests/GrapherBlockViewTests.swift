import AppKit
import XCTest
@testable import GrapherEmbed
@testable import GrapherKit

/// 笔记里的图形块：点一下进入操作状态，拖动转视角，改参数，存回文字。
@MainActor
final class GrapherBlockViewTests: XCTestCase {

    private let space = """
    space
    param a = 1.5 [0, 3]
    surface S: a*sin(x)*cos(y)
    """

    private func makeView(_ text: String) throws -> (GrapherBlockView, NSWindow) {
        let view = try XCTUnwrap(GrapherBlockView(source: text))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        // 画布尺寸是延后一拍同步的。
        let settled = expectation(description: "canvas size")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        return (view, window)
    }

    private func mouse(_ type: NSEvent.EventType, in window: NSWindow, at point: NSPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                           clickCount: clicks, pressure: 1)!
    }

    func testClickActivatesAndDragOrbitsThenSavesTheView() throws {
        let (view, window) = try makeView(space)
        var saved: String?
        view.onSourceChange = { saved = $0 }
        var activation: [Bool] = []
        view.onActivationChange = { activation.append($0) }

        XCTAssertFalse(view.isActive, "平时不吃事件")
        view.mouseDown(with: mouse(.leftMouseDown, in: window, at: NSPoint(x: 200, y: 160)))
        XCTAssertTrue(view.isActive, "点一下进入操作状态")
        XCTAssertEqual(activation, [true])

        let before = view.session.view3D.azimuth
        view.mouseDown(with: mouse(.leftMouseDown, in: window, at: NSPoint(x: 200, y: 160)))
        view.mouseDragged(with: mouse(.leftMouseDragged, in: window, at: NSPoint(x: 260, y: 160)))
        view.mouseUp(with: mouse(.leftMouseUp, in: window, at: NSPoint(x: 260, y: 160)))
        XCTAssertNotEqual(view.session.view3D.azimuth, before, "拖动转了视角")

        view.saveTapped()
        let text = try XCTUnwrap(saved)
        XCTAssertTrue(text.contains("view: azimuth="), text)
        XCTAssertEqual(GrapherText.parse(text).document.view3D.azimuth, view.session.view3D.azimuth, accuracy: 1e-3,
                       "存回文字的视角读回来是同一个")
        XCTAssertTrue(text.contains("surface S: a*sin(x)*cos(y)"), "别的文字一个字不动")

        view.setActive(false)
        XCTAssertFalse(view.isActive)
        XCTAssertEqual(activation, [true, false])
    }

    func testDoubleClickGoesBackToTheWrittenView() throws {
        let (view, window) = try makeView(space + "\nview: azimuth=20 elevation=10")
        view.setActive(true)
        view.mouseDown(with: mouse(.leftMouseDown, in: window, at: NSPoint(x: 200, y: 160)))
        view.mouseDragged(with: mouse(.leftMouseDragged, in: window, at: NSPoint(x: 300, y: 200)))
        view.mouseUp(with: mouse(.leftMouseUp, in: window, at: NSPoint(x: 300, y: 200)))
        XCTAssertNotEqual(view.session.view3D.azimuth, 20 * .pi / 180, accuracy: 1e-6)
        view.mouseDown(with: mouse(.leftMouseDown, in: window, at: NSPoint(x: 200, y: 160), clicks: 2))
        XCTAssertEqual(view.session.view3D.azimuth, 20 * .pi / 180, accuracy: 1e-6)
    }

    func testParameterChangeIsSavedIntoTheParamLine() throws {
        let (view, _) = try makeView(space)
        var saved: String?
        view.onSourceChange = { saved = $0 }
        view.setParameter("a", 2.25)
        XCTAssertEqual(view.session.parameterValue("a"), 2.25)
        view.saveTapped()
        let text = try XCTUnwrap(saved)
        XCTAssertTrue(text.contains("param a = 2.25 [0, 3]"), text)
        // 超出范围的值夹回范围。
        view.setParameter("a", 99)
        XCTAssertEqual(view.session.parameterValue("a"), 3)
    }

    func testPlaybackMovesTheParameterAndStopsWhenDeactivated() throws {
        let (view, _) = try makeView(space)
        view.setActive(true)
        let start = try XCTUnwrap(view.session.parameterValue("a"))
        view.togglePlay("a")
        let moved = expectation(description: "playing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { moved.fulfill() }
        wait(for: [moved], timeout: 2)
        XCTAssertNotEqual(view.session.parameterValue("a"), start, "播放把参数推走了")
        view.setActive(false)
        let stopped = try XCTUnwrap(view.session.parameterValue("a"))
        let still = expectation(description: "stopped")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { still.fulfill() }
        wait(for: [still], timeout: 2)
        XCTAssertEqual(view.session.parameterValue("a"), stopped, "退出操作状态就停止播放")
    }

    func testEditingTheSourceReloadsAndSwitchesDimension() throws {
        let (view, _) = try makeView("explicit: sin(x)")
        XCTAssertFalse(view.session.isSpace)
        view.setSource(space)
        XCTAssertTrue(view.session.isSpace)
        XCTAssertEqual(view.session.parameterValue("a"), 1.5)
        view.setSource("explicit: x\nbanana: 1")
        XCTAssertEqual(view.errors.count, 1)
        XCTAssertEqual(view.errors.first?.line, 2)
    }

    func testPlaneViewIsSavedAsCentreAndWidth() throws {
        let (view, window) = try makeView("view: center=0,0 width=10\nexplicit: sin(x)")
        var saved: String?
        view.onSourceChange = { saved = $0 }
        view.setActive(true)
        view.mouseDown(with: mouse(.leftMouseDown, in: window, at: NSPoint(x: 200, y: 160)))
        view.mouseDragged(with: mouse(.leftMouseDragged, in: window, at: NSPoint(x: 260, y: 160)))
        view.mouseUp(with: mouse(.leftMouseUp, in: window, at: NSPoint(x: 260, y: 160)))
        view.saveTapped()
        let result = GrapherText.parse(try XCTUnwrap(saved))
        XCTAssertNotEqual(result.planeFrame.centerX, 0, "平面图拖动是平移")
        XCTAssertEqual(result.planeFrame.width, 10, accuracy: 0.01, "平移不改宽度")
    }
}
