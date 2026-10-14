import XCTest
@testable import GrapherKit

/// 画布手感（`CanvasInput`）：App 画布与 Quick Look 预览共用，按键习惯不能变。
final class CanvasInputTests: XCTestCase {

    private func scroll(_ dx: Double, _ dy: Double, precise: Bool = true, momentum: Bool = false,
                        _ modifiers: CanvasInput.Modifiers = []) -> CanvasInput.Scroll {
        CanvasInput.Scroll(dx: dx, dy: dy, isPrecise: precise, isMomentum: momentum, modifiers: modifiers)
    }

    /// 双指滚动永远是平移，平面图、立体图都不当缩放。
    func testTwoFingerScrollAlwaysPans() {
        XCTAssertEqual(CanvasInput.scroll(scroll(3, -4), space: false, pointScale: 2), .pan(SIMD2(3, -4)))
        XCTAssertEqual(CanvasInput.scroll(scroll(3, -4), space: true, pointScale: 2), .pan(SIMD2(6, -8)))
        // 平面图里 ⌥ 不改变这一点。
        XCTAssertEqual(CanvasInput.scroll(scroll(0, 5, [.option]), space: false, pointScale: 2), .pan(SIMD2(0, 5)))
    }

    func testCommandScrollZoomsAndIgnoresMomentum() {
        guard case .zoom(let factor) = CanvasInput.scroll(scroll(0, -10, [.command]), space: false, pointScale: 2) else {
            return XCTFail("⌘+滚动应缩放")
        }
        XCTAssertGreaterThan(factor, 1, "往上滚放大")
        XCTAssertEqual(CanvasInput.scroll(scroll(0, -10, momentum: true, [.command]), space: false, pointScale: 2), .none,
                       "惯性阶段不缩放，否则一甩连放好几档")
    }

    func testOptionScrollZoomsTheBoxOnlyInSpace() {
        guard case .zoomBox = CanvasInput.scroll(scroll(0, 10, [.option]), space: true, pointScale: 2) else {
            return XCTFail("立体图 ⌥+滚动应放大盒子")
        }
        guard case .zoomBox = CanvasInput.scroll(scroll(0, 10, [.option, .command]), space: true, pointScale: 2) else {
            return XCTFail("⌥ 与 ⌘ 同按时以 ⌥ 为准")
        }
    }

    /// 有级滚轮一格只有 1 左右，放大十倍。
    func testNotchedWheelIsAmplified() {
        XCTAssertEqual(CanvasInput.scroll(scroll(0, 1, precise: false), space: false, pointScale: 2), .pan(SIMD2(0, 10)))
    }

    func testPinchZoomsAndOptionPinchZoomsTheBox() {
        XCTAssertEqual(CanvasInput.pinch(magnification: 0.1, modifiers: [], space: false), .zoom(1.1))
        XCTAssertEqual(CanvasInput.pinch(magnification: 0.1, modifiers: [.option], space: false), .zoom(1.1))
        XCTAssertEqual(CanvasInput.pinch(magnification: 0.1, modifiers: [.option], space: true), .zoomBox(1.1))
        XCTAssertEqual(CanvasInput.pinch(magnification: -1, modifiers: [], space: false), .none)
    }

    func testDragPansInPlaneAndOrbitsInSpace() {
        XCTAssertEqual(CanvasInput.drag(SIMD2(2, 3), modifiers: [], space: false, pansFromStart: false, pointScale: 2),
                       .pan(SIMD2(4, 6)))
        XCTAssertEqual(CanvasInput.drag(SIMD2(2, 3), modifiers: [], space: true, pansFromStart: false, pointScale: 2),
                       .orbit(SIMD2(2, 3)))
        XCTAssertEqual(CanvasInput.drag(SIMD2(2, 3), modifiers: [.shift], space: true, pansFromStart: false, pointScale: 2),
                       .pan(SIMD2(4, 6)))
        // 按下时按着 ⇧，中途松开也还是平移。
        XCTAssertEqual(CanvasInput.drag(SIMD2(2, 3), modifiers: [], space: true, pansFromStart: true, pointScale: 2),
                       .pan(SIMD2(4, 6)))
    }
}
