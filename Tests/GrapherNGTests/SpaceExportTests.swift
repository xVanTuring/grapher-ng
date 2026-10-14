import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GrapherKit
@testable import GrapherNG

/// 立体图导出 PNG：尺寸是眼前没被遮住的那块乘倍率，图里有曲面也有刻度文字。
@MainActor
final class SpaceExportTests: XCTestCase {

    func testSpaceDocumentExportsAtTheRequestedSize() throws {
        let state = AppState(document: .sample3D())
        state.setViewportMetrics(pixelWidth: 900, pixelHeight: 600,
                                 insets: NSEdgeInsets(top: 0, left: 50, bottom: 0, right: 0), backingScale: 2)
        let image = try XCTUnwrap(Exporter.renderImage3D(state: state, scale: 2))
        // 左边 50 点 = 100 像素被侧栏盖住，不进导出；再乘 2 倍。
        XCTAssertEqual(image.width, 1600)
        XCTAssertEqual(image.height, 1200)

        let raster = try XCTUnwrap(Raster(image))
        let centre = raster.pixel(x: 800, y: 600)
        let background = state.document.theme.background
        let backgroundGray = Int(background.r * 255)
        XCTAssertGreaterThan(abs(centre.r - backgroundGray) + abs(centre.g - backgroundGray), 40, "盒心附近有曲面：\(centre)")

        // 留一份给人看。
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grapher-space-export.png")
        if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            print("SPACE-EXPORT \(url.path)")
        }
    }
}
