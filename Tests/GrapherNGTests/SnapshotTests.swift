import CoreGraphics
import XCTest
@testable import GrapherKit
@testable import GrapherRender

/// Quick Look 预览、Finder 缩略图的画法（`GraphSnapshot`）与平面图坐标轴文字的摆放（`PlaneLabels`）。
final class SnapshotTests: XCTestCase {

    /// 平面图预览是矢量 PDF，页面尺寸是存下时没被盖住那块的一半（Retina 像素换成点），不超过上限。
    func testPlanePreviewIsAVectorPDFOfTheSavedView() throws {
        var document = GrapherDocument.sample()
        document.viewport.widthPixels = 1600
        document.viewport.heightPixels = 1000
        document.viewport.insetLeft = 400
        let (preview, size) = try GraphSnapshot.preview(of: document)
        XCTAssertEqual(size, CGSize(width: 600, height: 500))
        guard case .pdf(let data) = preview else { return XCTFail("平面图应出 PDF") }
        XCTAssertEqual(data.prefix(4), Data("%PDF".utf8))

        let pdf = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        XCTAssertEqual(pdf.numberOfPages, 1)
        XCTAssertEqual(pdf.page(at: 1)?.getBoxRect(.mediaBox).size, size)
    }

    func testOversizedViewsShrinkToTheLimit() throws {
        var document = GrapherDocument.sample()
        document.viewport.widthPixels = 4000
        document.viewport.heightPixels = 2000
        let (_, size) = try GraphSnapshot.preview(of: document, maxPointSize: CGSize(width: 960, height: 640))
        XCTAssertEqual(size, CGSize(width: 960, height: 480))
    }

    /// 立体图预览是 PNG，像素是点的两倍；盒心附近有曲面，不是一片底色。
    func testSpacePreviewIsAPNGWithTheSurface() throws {
        var document = GrapherDocument.sample3D()
        document.viewport.widthPixels = 1200
        document.viewport.heightPixels = 800
        let (preview, size) = try GraphSnapshot.preview(of: document)
        XCTAssertEqual(size, CGSize(width: 600, height: 400))
        guard case .png(let data) = preview else { return XCTFail("立体图应出 PNG") }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1200)
        XCTAssertEqual(image.height, 800)

        let raster = try XCTUnwrap(Raster(image))
        let centre = raster.pixel(x: 600, y: 400)
        let background = Int(document.theme.background.r * 255)
        XCTAssertGreaterThan(abs(centre.r - background) + abs(centre.g - background), 40, "盒心附近有曲面：\(centre)")
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
