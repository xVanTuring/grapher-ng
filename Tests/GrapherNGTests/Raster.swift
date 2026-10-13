import CoreGraphics
import Foundation
import GrapherKit
import GrapherRender
import ImageIO
import XCTest

struct Pixel: Equatable, CustomStringConvertible {
    let r: Int
    let g: Int
    let b: Int

    var description: String { "(r: \(r), g: \(g), b: \(b))" }

    /// Every colour used here is neutral grey, so one channel stands for all three.
    var gray: Int { r }
}

/// Pixel access on top of the image the renderer actually produced.
final class Raster {
    let image: CGImage
    let width: Int
    let height: Int

    init?(_ image: CGImage?) {
        guard let image else { return nil }
        self.image = image
        self.width = image.width
        self.height = image.height
    }

    static func load(contentsOf url: URL) -> Raster? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return Raster(image)
    }

    /// Samples one pixel through a 1x1 RGBA context. A one-pixel destination
    /// cannot be flipped and the context normalises whatever channel order the
    /// image was declared with, so the reading is unambiguous either way.
    func pixel(x: Int, y: Int) -> Pixel {
        let none = Pixel(r: -1, g: -1, b: -1)
        guard x >= 0, y >= 0, x < width, y < height,
              let one = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))
        else { return none }
        let space = CGColorSpaceCreateDeviceRGB()

        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Pixel(r: Int(bytes[0]), g: Int(bytes[1]), b: Int(bytes[2]))
    }

    /// Total covered height of a vertical slice, in pixels. Independent of where
    /// the stroke lands between pixel centres, which is what makes it usable as
    /// a scale-invariance check.
    func inkMass(x: Int, rows: Range<Int>) -> Double {
        rows.reduce(into: 0.0) { total, y in
            total += Double(255 - pixel(x: x, y: y).gray) / 255.0
        }
    }

    func inkedRows(x: Int, rows: Range<Int>, darkerThan threshold: Int = 250) -> [Int] {
        rows.filter { pixel(x: x, y: $0).gray < threshold }
    }
}

enum TestHarness {
    static func context() throws -> MetalContext {
        guard let context = MetalContext.shared else {
            throw XCTSkip("Metal is unavailable on this machine")
        }
        return context
    }

    static func raster(
        _ scene: Scene2D,
        width: Int,
        height: Int,
        supersample: Int = 1
    ) throws -> Raster {
        let context = try context()
        guard let renderer = OffscreenRenderer2D(
            context: context,
            pixelWidth: width,
            pixelHeight: height,
            supersample: supersample
        ), let image = renderer.makeImage(scene) else {
            throw TestFailure.renderFailed
        }
        guard let raster = Raster(image) else { throw TestFailure.renderFailed }
        XCTAssertEqual(raster.width, width)
        XCTAssertEqual(raster.height, height)
        return raster
    }

    static func horizontalLine(
        from x0: Double,
        to x1: Double,
        y: Double,
        width: Double,
        color: RGBAColor = .black
    ) -> Scene2D {
        Scene2D(background: .white, commands: [
            .polyline(PolylinePrimitive(
                points: [SIMD2(x0, y), SIMD2(x1, y)],
                color: color,
                width: width
            )),
        ])
    }

    enum TestFailure: Error {
        case renderFailed
    }
}
