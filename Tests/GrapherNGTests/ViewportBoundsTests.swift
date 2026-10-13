import XCTest
@testable import GrapherKit

/// 软边界是「不许滚进虚空」这条体验约束的唯一实现处，用数值把它钉死。
final class ViewportBoundsTests: XCTestCase {

    private func viewport(scale: Double = 100, width: Double = 200, height: Double = 200) -> Viewport2D {
        Viewport2D(centerX: 0, centerY: 0, scale: scale, widthPixels: width, heightPixels: height)
    }

    func testCentreInsideTheContentIsLeftAlone() {
        let vp = viewport()
        let content = DataBounds(minX: -1, maxX: 1, minY: -1, maxY: 1)
        let clamped = ViewportBounds.clamp(vp, content: content)
        XCTAssertEqual(clamped.centerX, 0)
        XCTAssertEqual(clamped.centerY, 0)
    }

    /// 视口半宽 = 1（200px / 100 px-per-unit / 2）。reach = half × (1 + 2×1.5) = 4×half，
    /// 所以中心最远能到内容边缘外 4 个半视口。
    func testCentreIsPulledBackToFourHalfViewportsPastTheContent() {
        let content = DataBounds(minX: -1, maxX: 1, minY: -1, maxY: 1)
        let far = Viewport2D(centerX: 500, centerY: -500, scale: 100, widthPixels: 200, heightPixels: 200)
        let clamped = ViewportBounds.clamp(far, content: content)

        XCTAssertEqual(clamped.centerX, 1 + 4, accuracy: 1e-9)
        XCTAssertEqual(clamped.centerY, -1 - 4, accuracy: 1e-9)
        // 缩放与尺寸不受影响。
        XCTAssertEqual(clamped.scale, far.scale)
        XCTAssertEqual(clamped.widthPixels, far.widthPixels)
    }

    func testEmptyDocumentStaysNearTheOrigin() {
        let far = Viewport2D(centerX: 100, centerY: 100, scale: 100, widthPixels: 200, heightPixels: 200)
        let clamped = ViewportBounds.clamp(far, content: nil)
        // 空内容退化成围着原点的一块：半宽 1 → 最远 ±4。
        XCTAssertEqual(clamped.centerX, 4, accuracy: 1e-9)
        XCTAssertEqual(clamped.centerY, 4, accuracy: 1e-9)
    }

    func testZoomingOutWidensTheAllowedRange() {
        let content = DataBounds(minX: -1, maxX: 1, minY: -1, maxY: 1)
        // 缩到 10 px/单位：视口半宽变成 10，允许中心最远到内容边缘外 40。
        let vp = Viewport2D(centerX: 100, centerY: 0, scale: 10, widthPixels: 200, heightPixels: 200)
        let clamped = ViewportBounds.clamp(vp, content: content)
        XCTAssertEqual(clamped.centerX, 41, accuracy: 1e-9)

        // 同样这个位置在 100 px/单位（半宽只有 1）下是越界的。
        let tight = Viewport2D(centerX: 100, centerY: 0, scale: 100, widthPixels: 200, heightPixels: 200)
        XCTAssertEqual(ViewportBounds.clamp(tight, content: content).centerX, 5, accuracy: 1e-9)

        let range = ViewportBounds.allowedCenterRange(content: content, viewport: vp)
        XCTAssertEqual(range.maxX, 1 + 40, accuracy: 1e-9)
    }

    func testAlreadyLegalViewportIsReturnedUnchanged() {
        let content = DataBounds(minX: -10, maxX: 10, minY: -10, maxY: 10)
        let vp = Viewport2D(centerX: 3, centerY: -4, scale: 37, widthPixels: 640, heightPixels: 480)
        XCTAssertEqual(ViewportBounds.clamp(vp, content: content), vp)
    }

    // MARK: - 包围盒

    func testEnclosingCollectsEveryFinitePoint() {
        let segments: [[SIMD2<Double>]] = [
            [SIMD2(-1, 2), SIMD2(3, 2)],
            [SIMD2(0.5, -4)],
        ]
        let bounds = DataBounds.enclosing(segments)
        XCTAssertEqual(bounds?.minX, -1)
        XCTAssertEqual(bounds?.maxX, 3)
        XCTAssertEqual(bounds?.minY, -4)
        XCTAssertEqual(bounds?.maxY, 2)
    }

    func testEnclosingIgnoresNonFinitePoints() {
        let segments: [[SIMD2<Double>]] = [[SIMD2(.nan, 0), SIMD2(0, 1), SIMD2(1, .infinity)]]
        let bounds = DataBounds.enclosing(segments)
        XCTAssertEqual(bounds?.minX, 0)
        XCTAssertEqual(bounds?.maxX, 0)
        XCTAssertEqual(bounds?.minY, 1)
        XCTAssertEqual(bounds?.maxY, 1)
    }

    func testEnclosingReturnsNilWhenThereIsNothing() {
        XCTAssertNil(DataBounds.enclosing([]))
        XCTAssertNil(DataBounds.enclosing([[]]))
    }
}
