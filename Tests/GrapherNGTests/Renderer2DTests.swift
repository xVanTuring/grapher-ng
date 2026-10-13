import CoreGraphics
import Foundation
import GrapherKit
import GrapherRender
import Metal
import XCTest

final class Renderer2DTests: XCTestCase {

    // MARK: 1. Analytic anti-aliasing

    func testLineAntialiasingProducesIntermediateGray() throws {
        let scene = TestHarness.horizontalLine(from: 20, to: 180, y: 100.5, width: 2)
        let raster = try TestHarness.raster(scene, width: 200, height: 200)

        // The stroke covers y in [99.5, 101.5]. The coverage ramp is one pixel
        // wide and centred on the geometric edge, so the rows straddling that
        // edge are half covered rather than fully on or fully off.
        let above = raster.pixel(x: 100, y: 99)
        let centre = raster.pixel(x: 100, y: 100)
        let below = raster.pixel(x: 100, y: 101)
        let beyond = raster.pixel(x: 100, y: 102)
        let clear = raster.pixel(x: 100, y: 95)
        let offLine = raster.pixel(x: 10, y: 100)

        assertGray(above, isNear: 128, "row above the stroke should be half covered")
        assertGray(below, isNear: 128, "row below the stroke should be half covered")
        XCTAssertTrue((1...254).contains(above.gray), "must be a blend, not on/off: \(above)")
        XCTAssertTrue((1...254).contains(below.gray), "must be a blend, not on/off: \(below)")
        assertGray(centre, isNear: 0, "stroke centre should be solid black")
        assertGray(beyond, isNear: 255, "one pixel further out must be untouched")
        assertGray(clear, isNear: 255, "five pixels away must be pure background")
        assertGray(offLine, isNear: 255, "to the left of the segment start must be background")

        // Without a ramp these exact pixel centres would land on 0 or 255 only.
        XCTAssertGreaterThan(above.gray, 0)
    }

    // MARK: 2. Width stability across scale

    func testStrokeWidthIsStableWhenTheViewportScales() throws {
        let base = TestHarness.horizontalLine(from: 20, to: 180, y: 100.5, width: 2)
        let doubled = TestHarness.horizontalLine(from: 40, to: 360, y: 201, width: 2)

        let small = try TestHarness.raster(base, width: 200, height: 200)
        let large = try TestHarness.raster(doubled, width: 400, height: 400)

        let smallMass = small.inkMass(x: 100, rows: 90..<112)
        let largeMass = large.inkMass(x: 200, rows: 190..<212)

        XCTAssertEqual(smallMass, 2.0, accuracy: 0.05, "stroke covers 2 pixels of height")
        XCTAssertEqual(largeMass, 2.0, accuracy: 0.05, "stroke covers 2 pixels of height")
        XCTAssertEqual(smallMass, largeMass, accuracy: 0.1, "same width at double the viewport")

        let smallRows = small.inkedRows(x: 100, rows: 90..<112)
        let largeRows = large.inkedRows(x: 200, rows: 190..<212)
        XCTAssertEqual(smallRows.count, 3, "rows touched: \(smallRows)")
        XCTAssertEqual(largeRows.count, 2, "rows touched: \(largeRows)")
        XCTAssertLessThanOrEqual(abs(smallRows.count - largeRows.count), 1)
    }

    // MARK: 3. Rect coverage

    func testRectCoverageIsTakenAsGiven() throws {
        let half = Scene2D(background: .white, commands: [
            .rects(RectPrimitiveBatch(
                geometry: [SIMD4(10, 11, 10, 11)],
                coverage: [0.5],
                color: .black
            )),
        ])
        let raster = try TestHarness.raster(half, width: 100, height: 100)
        assertGray(raster.pixel(x: 10, y: 10), isNear: 128, tolerance: 8, "half coverage over white")
        assertGray(raster.pixel(x: 11, y: 10), isNear: 255, "neighbouring column untouched")
        assertGray(raster.pixel(x: 10, y: 11), isNear: 255, "neighbouring row untouched")

        let full = Scene2D(background: .white, commands: [
            .rects(RectPrimitiveBatch(
                geometry: [SIMD4(10, 11, 10, 11)],
                coverage: [1.0],
                color: .black
            )),
        ])
        let solid = try TestHarness.raster(full, width: 100, height: 100)
        assertGray(solid.pixel(x: 10, y: 10), isNear: 0, "full coverage is solid")
        assertGray(solid.pixel(x: 11, y: 10), isNear: 255)
    }

    // MARK: 4. Layer order

    func testLaterCommandsPaintOnTop() throws {
        let red = RGBAColor(1, 0, 0)
        let blue = RGBAColor(0, 0, 1)

        func scene(redFirst: Bool) -> Scene2D {
            let horizontal = Draw2D.polyline(PolylinePrimitive(
                points: [SIMD2(10.0, 50.5), SIMD2(90.0, 50.5)],
                color: red,
                width: 12
            ))
            let vertical = Draw2D.polyline(PolylinePrimitive(
                points: [SIMD2(50.5, 10.0), SIMD2(50.5, 90.0)],
                color: blue,
                width: 12
            ))
            return Scene2D(background: .white, commands: redFirst ? [horizontal, vertical] : [vertical, horizontal])
        }

        let blueOnTop = try TestHarness.raster(scene(redFirst: true), width: 100, height: 100)
        let overlap = blueOnTop.pixel(x: 50, y: 50)
        XCTAssertEqual(overlap, Pixel(r: 0, g: 0, b: 255), "blue drawn last wins the crossing")
        XCTAssertEqual(blueOnTop.pixel(x: 20, y: 50), Pixel(r: 255, g: 0, b: 0), "red survives away from the crossing")

        let redOnTop = try TestHarness.raster(scene(redFirst: false), width: 100, height: 100)
        XCTAssertEqual(redOnTop.pixel(x: 50, y: 50), Pixel(r: 255, g: 0, b: 0), "red drawn last wins the crossing")
        XCTAssertEqual(redOnTop.pixel(x: 50, y: 20), Pixel(r: 0, g: 0, b: 255), "blue survives away from the crossing")
    }

    // MARK: 5. Colour round trip

    func testChannelOrderSurvivesTheExport() throws {
        let cases: [(RGBAColor, Pixel)] = [
            (RGBAColor(1, 0, 0), Pixel(r: 255, g: 0, b: 0)),
            (RGBAColor(0, 1, 0), Pixel(r: 0, g: 255, b: 0)),
            (RGBAColor(0, 0, 1), Pixel(r: 0, g: 0, b: 255)),
        ]
        let context = try TestHarness.context()

        for (color, expected) in cases {
            let scene = Scene2D(background: .white, commands: [
                .rects(RectPrimitiveBatch(geometry: [SIMD4(0, 32, 0, 32)], coverage: [1], color: color)),
            ])
            let raster = try TestHarness.raster(scene, width: 32, height: 32)
            XCTAssertEqual(raster.pixel(x: 16, y: 16), expected, "fill came back in the wrong channel order")

            // And again through an actual PNG, which is what an export consumer sees.
            guard let renderer = OffscreenRenderer2D(context: context, pixelWidth: 32, pixelHeight: 32, supersample: 1) else {
                return XCTFail("offscreen renderer unavailable")
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("grapher-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: url) }
            try renderer.writePNG(scene, to: url)
            let reloaded = try XCTUnwrap(Raster.load(contentsOf: url), "PNG could not be read back")
            XCTAssertEqual(reloaded.pixel(x: 16, y: 16), expected, "PNG came back in the wrong channel order")
        }
    }

    // MARK: 6. Round caps

    func testStrokeEndIsRound() throws {
        let scene = TestHarness.horizontalLine(from: 50.5, to: 150.5, y: 50.5, width: 20)
        let raster = try TestHarness.raster(scene, width: 200, height: 200)

        // The cap is a disc of radius 10 around the endpoint, so the pixel one
        // unit past the tip is half covered while the next one is empty.
        assertGray(raster.pixel(x: 40, y: 50), isNear: 128, tolerance: 3, "cap tip at one radius out")
        assertGray(raster.pixel(x: 39, y: 50), isNear: 255, "beyond the cap tip")
        assertGray(raster.pixel(x: 41, y: 50), isNear: 0, "inside the cap")
        assertGray(raster.pixel(x: 45, y: 45), isNear: 0, "inside the capsule body")

        // A square cap would paint this corner; a round one leaves it clear.
        assertGray(raster.pixel(x: 41, y: 41), isNear: 255, "corner outside the disc")

        assertGray(raster.pixel(x: 160, y: 50), isNear: 128, tolerance: 3, "far cap is round too")
        assertGray(raster.pixel(x: 161, y: 50), isNear: 255)
    }

    func testMarkerIsADisc() throws {
        let scene = Scene2D(background: .white, commands: [
            .markers(MarkerPrimitiveBatch(positions: [SIMD2(60.0, 60.0)], radius: 5, color: .black)),
        ])
        let raster = try TestHarness.raster(scene, width: 120, height: 120)
        assertGray(raster.pixel(x: 59, y: 59), isNear: 0, "disc interior")
        assertGray(raster.pixel(x: 63, y: 59), isNear: 0, "disc interior near the rim")
        assertGray(raster.pixel(x: 65, y: 59), isNear: 255, "one pixel past the rim")
        assertGray(raster.pixel(x: 59, y: 54), isNear: 255, "clearly outside")
    }

    // MARK: 7. Degenerate input

    func testDegenerateInputDoesNotCrash() throws {
        let empty = Scene2D(background: .white, commands: [])
        assertGray(try TestHarness.raster(empty, width: 64, height: 64).pixel(x: 32, y: 32), isNear: 255, "empty scene is pure background")

        let noPoints = Scene2D(background: .white, commands: [
            .polyline(PolylinePrimitive(points: [], color: .black, width: 4)),
        ])
        assertGray(try TestHarness.raster(noPoints, width: 64, height: 64).pixel(x: 32, y: 32), isNear: 255)

        let onePoint = Scene2D(background: .white, commands: [
            .polyline(PolylinePrimitive(points: [SIMD2(32.0, 32.0)], color: .black, width: 4)),
        ])
        assertGray(try TestHarness.raster(onePoint, width: 64, height: 64).pixel(x: 32, y: 32), isNear: 255)

        // A single point repeated: no tangent exists, so it has to fall back to
        // a round dot instead of producing a NaN quad.
        let zeroLength = Scene2D(background: .white, commands: [
            .polyline(PolylinePrimitive(points: [SIMD2(60.0, 60.0), SIMD2(60.0, 60.0)], color: .black, width: 10)),
        ])
        let dot = try TestHarness.raster(zeroLength, width: 120, height: 120)
        assertGray(dot.pixel(x: 59, y: 59), isNear: 0, "zero length segment becomes a dot")
        assertGray(dot.pixel(x: 60, y: 60), isNear: 0)
        assertGray(dot.pixel(x: 63, y: 59), isNear: 0, "dot interior near the rim")
        assertGray(dot.pixel(x: 65, y: 59), isNear: 255, "one pixel past the dot")

        let closed = Scene2D(background: .white, commands: [
            .polyline(PolylinePrimitive(points: [SIMD2(40.0, 40.0), SIMD2(40.0, 40.0)], color: .black, width: 6, isClosed: true)),
        ])
        assertGray(try TestHarness.raster(closed, width: 80, height: 80).pixel(x: 39, y: 39), isNear: 0)

        let offScreen = Scene2D(background: .white, commands: [
            .polyline(PolylinePrimitive(points: [SIMD2(-500.0, -500.0), SIMD2(-400.0, -400.0)], color: .black, width: 8)),
            .markers(MarkerPrimitiveBatch(positions: [SIMD2(-30.0, -30.0)], radius: 10, color: .black)),
        ])
        assertGray(try TestHarness.raster(offScreen, width: 64, height: 64).pixel(x: 32, y: 32), isNear: 255, "nothing is visible")

        let zeroRadius = Scene2D(background: .white, commands: [
            .markers(MarkerPrimitiveBatch(positions: [SIMD2(20.0, 20.0)], radius: 0, color: .black)),
        ])
        assertGray(try TestHarness.raster(zeroRadius, width: 64, height: 64).pixel(x: 20, y: 20), isNear: 255, "zero radius paints nothing")

        let mismatched = Scene2D(background: .white, commands: [
            .rects(RectPrimitiveBatch(geometry: [SIMD4(0, 8, 0, 8)], coverage: [], color: .black)),
        ])
        assertGray(try TestHarness.raster(mismatched, width: 16, height: 16).pixel(x: 4, y: 4), isNear: 255, "coverage array shorter than geometry")
    }

    // MARK: Direct encode path

    func testRenderSynchronouslyFillsTheTexture() throws {
        let context = try TestHarness.context()
        XCTAssertEqual(MetalContext.sampleCount, 1, "MSAA would double up the analytic coverage")
        XCTAssertEqual(MetalContext.colorFormat, .bgra8Unorm)

        let renderer = try XCTUnwrap(Renderer2D(context: context))
        let side = 32
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalContext.colorFormat,
            width: side,
            height: side,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = try XCTUnwrap(context.device.makeTexture(descriptor: descriptor))

        let bytesPerRow = 256
        let readback = try XCTUnwrap(context.device.makeBuffer(
            length: bytesPerRow * side,
            options: .storageModeShared
        ))

        let scene = Scene2D(background: .white, commands: [
            .rects(RectPrimitiveBatch(
                geometry: [SIMD4(0, 32, 0, 32)],
                coverage: [1],
                color: RGBAColor(1, 0, 0)
            )),
        ])
        let commandBuffer = try XCTUnwrap(context.queue.makeCommandBuffer())
        XCTAssertTrue(renderer.renderSynchronously(scene: scene, to: texture, commandBuffer: commandBuffer))
        XCTAssertEqual(commandBuffer.status, .completed)

        let blitBuffer = try XCTUnwrap(context.queue.makeCommandBuffer())
        let blit = try XCTUnwrap(blitBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: side, height: side, depth: 1),
            to: readback,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * side
        )
        blit.endEncoding()
        blitBuffer.commit()
        blitBuffer.waitUntilCompleted()

        let bytes = readback.contents().assumingMemoryBound(to: UInt8.self)
        let offset = 16 * bytesPerRow + 16 * 4
        XCTAssertEqual(Int(bytes[offset + 0]), 0, "blue channel")
        XCTAssertEqual(Int(bytes[offset + 1]), 0, "green channel")
        XCTAssertEqual(Int(bytes[offset + 2]), 255, "red channel")
        XCTAssertEqual(Int(bytes[offset + 3]), 255, "alpha channel")
    }

    // MARK: Supersampling

    func testSupersamplingKeepsTheImageAligned() throws {
        let scene = Scene2D(background: .white, commands: [
            .polyline(PolylinePrimitive(points: [SIMD2(20.0, 40.5), SIMD2(80.0, 40.5)], color: .black, width: 3)),
            .rects(RectPrimitiveBatch(geometry: [SIMD4(0, 10, 0, 10)], coverage: [1], color: RGBAColor(1, 0, 0))),
        ])
        let raster = try TestHarness.raster(scene, width: 100, height: 100, supersample: 4)
        XCTAssertEqual(raster.width, 100)
        XCTAssertEqual(raster.height, 100)
        XCTAssertEqual(raster.pixel(x: 5, y: 5), Pixel(r: 255, g: 0, b: 0), "geometry must not shrink to the corner")
        assertGray(raster.pixel(x: 50, y: 41), isNear: 0, "stroke centre lands in the same place")
        assertGray(raster.pixel(x: 50, y: 20), isNear: 255, "and stays a thin line")
    }

    // MARK: Helpers

    private func assertGray(
        _ pixel: Pixel,
        isNear expected: Int,
        tolerance: Int = 2,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            abs(pixel.gray - expected),
            tolerance,
            "\(message) — expected ~\(expected), got \(pixel)",
            file: file,
            line: line
        )
    }
}
