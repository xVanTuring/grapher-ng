import CoreGraphics
import Foundation
import ImageIO
import XCTest
import UniformTypeIdentifiers
@testable import GrapherKit
@testable import GrapherRender

/// 文字描述画成的图：每个写法示例都能读、画得出东西；深浅色可以由宿主指定。
final class GrapherTextRenderTests: XCTestCase {

    private func write(_ image: CGImage, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["GRAPHER_DEMO_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            folder.appendingPathComponent("\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    func testEveryExampleParsesAndRenders() throws {
        XCTAssertGreaterThanOrEqual(GrapherText.examples.count, 8)
        for example in GrapherText.examples {
            let rendering = GraphSnapshot.image(text: example.text, pixelWidth: 720, pointScale: 1, quality: .full)
            XCTAssertTrue(rendering.errors.isEmpty, "\(example.id): \(rendering.errors.map { "L\($0.line) \($0.message)" })")
            let image = try XCTUnwrap(rendering.image, example.id)
            XCTAssertEqual(Double(image.width) / Double(image.height), rendering.aspect, accuracy: 0.01)
            XCTAssertGreaterThan(inkFraction(of: image), 0.004, "\(example.id) 画面几乎是空的")
            write(image, name: "text-\(example.id)")
        }
    }

    func testHostThemeOverridesTheText() throws {
        let text = "theme: light\nexplicit: sin(x)"
        let light = try XCTUnwrap(GraphSnapshot.image(text: text, pixelWidth: 200, pointScale: 1, quality: .full).image)
        let dark = try XCTUnwrap(GraphSnapshot.image(text: text, pixelWidth: 200, theme: .dark, pointScale: 1, quality: .full).image)
        func corner(_ image: CGImage) -> Int {
            var bytes = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Int(bytes[0])
        }
        XCTAssertGreaterThan(corner(light), 200)
        XCTAssertLessThan(corner(dark), 60)
    }

    func testErrorsComeBackWithTheImage() {
        let rendering = GraphSnapshot.image(text: "explicit: sin(x)\nexplicit: nope(x)", pixelWidth: 200, pointScale: 1)
        XCTAssertNotNil(rendering.image)
        XCTAssertEqual(rendering.errors.map(\.line), [2])
    }
}
