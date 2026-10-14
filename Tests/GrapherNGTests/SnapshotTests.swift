import CoreGraphics
import XCTest
@testable import GrapherKit
@testable import GrapherRender

/// Finder 缩略图、欢迎窗口与空格预览初始取景的画法（`GraphSnapshot`），以及平面图坐标轴文字的摆放（`PlaneLabels`）。
final class SnapshotTests: XCTestCase {

    /// 平面图取景：存下时没被侧栏盖住的那块，换到新尺寸后看到的数据范围不变（比例相同时）。
    func testPlaneFramingKeepsTheSavedRegion() {
        var document = GrapherDocument.sample()
        document.viewport.widthPixels = 1600
        document.viewport.heightPixels = 1000
        document.viewport.insetLeft = 400
        let saved = document.viewport.unobscured
        let framed = GraphSnapshot.planeViewport(of: document, pixelWidth: 600, pixelHeight: 500)
        XCTAssertEqual(framed.xRange.lowerBound, saved.xRange.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(framed.xRange.upperBound, saved.xRange.upperBound, accuracy: 1e-9)
        XCTAssertEqual(framed.yRange.lowerBound, saved.yRange.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(framed.yRange.upperBound, saved.yRange.upperBound, accuracy: 1e-9)
    }

    /// 缩略图按要的像素出图，平面图、立体图都行。
    func testThumbnailsComeOutAtTheRequestedSize() throws {
        for document in [GrapherDocument.sample(), GrapherDocument.sample3D()] {
            let image = try XCTUnwrap(GraphSnapshot.image(of: document, pixelWidth: 256, pixelHeight: 160,
                                                          pointScale: 1.6, labels: false))
            XCTAssertEqual(image.width, 256)
            XCTAssertEqual(image.height, 160)
        }
    }

    /// 两条轴都在画面里：原点标「O」，0 那个刻度不再重复标；x、y 轴名各一个。
    func testPlaneLabelsMarkTheOriginAndSkipTheZeroTick() {
        let viewport = Viewport2D(centerX: 0, centerY: 0, scale: 64, widthPixels: 1200, heightPixels: 800)
        let labels = PlaneLabels.make(chrome: ChromeLayout.make(viewport: viewport), viewport: viewport,
                                      showTickLabels: true, width: 600, height: 400, pointScale: 2)
        XCTAssertEqual(labels.filter { $0.role == .origin }.count, 1)
        XCTAssertEqual(labels.filter { $0.role == .axisName }.map(\.text).sorted(), ["x", "y"])
        XCTAssertFalse(labels.contains { $0.role == .tick && $0.text == "0" })
        XCTAssertTrue(labels.contains { $0.role == .tick && $0.key == "x" })
        XCTAssertTrue(labels.contains { $0.role == .tick && $0.key == "y" })
    }

    /// 被侧栏盖住的那一边不放字。
    func testPlaneLabelsStayOutOfTheObscuredStrip() {
        var viewport = Viewport2D(centerX: 0, centerY: 0, scale: 64, widthPixels: 1200, heightPixels: 800)
        viewport.insetLeft = 400
        let labels = PlaneLabels.make(chrome: ChromeLayout.make(viewport: viewport), viewport: viewport,
                                      showTickLabels: true, width: 600, height: 400, pointScale: 2)
        XCTAssertFalse(labels.isEmpty)
        XCTAssertTrue(labels.allSatisfy { $0.point.x > 200 }, "左边 200 点被盖住")
    }

    func testTickLabelsCanBeTurnedOff() {
        let viewport = Viewport2D(centerX: 0, centerY: 0, scale: 64, widthPixels: 1200, heightPixels: 800)
        let labels = PlaneLabels.make(chrome: ChromeLayout.make(viewport: viewport), viewport: viewport,
                                      showTickLabels: false, width: 600, height: 400, pointScale: 2)
        XCTAssertFalse(labels.contains { $0.role == .tick })
    }
}
