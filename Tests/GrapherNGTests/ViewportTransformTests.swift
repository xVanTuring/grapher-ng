import Foundation
import GrapherRender
import Metal
import XCTest
@testable import GrapherKit

/// 拖动跟手靠两件事：旧几何经 `ScreenTransform2D` 摆到新视口上，与直接按新视口算的
/// 一致；以及外扩采样、遮挡区（毛玻璃侧栏）不改变「数据点 → 屏幕像素」的对应关系。
final class ViewportTransformTests: XCTestCase {

    private func assertClose(
        _ a: SIMD2<Double>,
        _ b: SIMD2<Double>,
        accuracy: Double = 1e-6,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
    }

    // MARK: - 遮挡区

    func testCentreLandsInTheMiddleOfTheUnobscuredArea() {
        var vp = Viewport2D(centerX: 3, centerY: -2, scale: 50, widthPixels: 1000, heightPixels: 600)
        vp.insetLeft = 400
        vp.insetTop = 100
        // 没被盖住的那块是 x ∈ [400, 1000]、y ∈ [100, 600]，中心 (700, 350)。
        assertClose(vp.toScreen(x: 3, y: -2), SIMD2(700, 350))
        assertClose(vp.toData(SIMD2(700, 350)), SIMD2(3, -2))
        // 画布照样铺满整块：数据范围从像素 0 算起，含侧栏底下那段。
        XCTAssertEqual(vp.xRange.lowerBound, 3 - 700.0 / 50, accuracy: 1e-9)
        XCTAssertEqual(vp.xRange.upperBound, 3 + 300.0 / 50, accuracy: 1e-9)
        XCTAssertEqual(vp.yRange.upperBound, -2 + 350.0 / 50, accuracy: 1e-9)
    }

    func testUnobscuredViewportShowsTheSameDataAtTheSameScale() {
        var vp = Viewport2D(centerX: 1, centerY: 1, scale: 20, widthPixels: 900, heightPixels: 500)
        vp.insetLeft = 300
        vp.insetTop = 50
        let clear = vp.unobscured
        XCTAssertEqual(clear.widthPixels, 600)
        XCTAssertEqual(clear.heightPixels, 450)
        XCTAssertEqual(clear.scale, vp.scale)
        XCTAssertEqual(clear.xRange.lowerBound, vp.screenToDataX(300), accuracy: 1e-9)
        XCTAssertEqual(clear.yRange.upperBound, vp.screenToDataY(50), accuracy: 1e-9)
    }

    func testFitUsesOnlyTheUnobscuredArea() {
        var vp = Viewport2D(widthPixels: 1000, heightPixels: 1000)
        vp.insetLeft = 500
        vp.fit(minX: -1, maxX: 1, minY: -1, maxY: 1, margin: 0)
        XCTAssertEqual(vp.scale, 250, accuracy: 1e-9, "2 个单位装进剩下的 500 像素宽")
        assertClose(vp.toScreen(x: 0, y: 0), SIMD2(750, 500))
    }

    func testInsetsAreWindowStateAndNeverReachTheFile() throws {
        var vp = Viewport2D(centerX: 2, centerY: 3, scale: 40, widthPixels: 800, heightPixels: 600)
        vp.insetLeft = 440
        vp.insetTop = 104
        let data = try JSONEncoder().encode(vp)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("inset"), json)
        let decoded = try JSONDecoder().decode(Viewport2D.self, from: data)
        XCTAssertEqual(decoded.insetLeft, 0)
        XCTAssertEqual(decoded.centerX, 2)
        XCTAssertEqual(decoded.widthPixels, 800)
    }

    // MARK: - 外扩采样

    func testExpandedViewportOnlyShiftsPixelsByAWholeMargin() {
        var vp = Viewport2D(centerX: -4, centerY: 7, scale: 33, widthPixels: 1201, heightPixels: 799)
        vp.insetLeft = 220
        let wide = vp.expanded(by: 0.25)
        let marginX = (1201 * 0.25).rounded()
        let marginY = (799 * 0.25).rounded()
        XCTAssertEqual(wide.widthPixels, 1201 + 2 * marginX)
        XCTAssertEqual(wide.heightPixels, 799 + 2 * marginY)
        for point in [SIMD2(-4.0, 7.0), SIMD2(10.0, -3.0), SIMD2(-40.0, 20.0)] {
            let near = vp.toScreen(x: point.x, y: point.y)
            let far = wide.toScreen(x: point.x, y: point.y)
            assertClose(far - near, SIMD2(marginX, marginY), "外扩只是整体平移一个整像素的边")
        }
        let transform = vp.screenTransform(from: wide)
        XCTAssertEqual(transform.scale, 1)
        assertClose(transform.translation, SIMD2(-marginX, -marginY))
    }

    // MARK: - 旧几何摆到新视口

    func testScreenTransformMatchesProjectingWithTheNewViewport() {
        var source = Viewport2D(centerX: 1.5, centerY: -0.5, scale: 64, widthPixels: 1600, heightPixels: 1000)
        source.insetLeft = 440
        source.insetTop = 104
        let sampled = source.expanded(by: 0.25)

        var current = source
        current.pan(byPixels: SIMD2(137, -58))
        current.zoom(by: 1.7, anchorPixel: SIMD2(900, 420))
        current.insetLeft = 0   // 侧栏收起了

        let transform = current.screenTransform(from: sampled)
        for point in [SIMD2(0.0, 0.0), SIMD2(3.25, -2.0), SIMD2(-12.0, 9.5)] {
            let old = sampled.toScreen(x: point.x, y: point.y)
            let expected = current.toScreen(x: point.x, y: point.y)
            assertClose(transform.apply(old), expected, accuracy: 1e-6)
        }
    }

    func testIdenticalViewportsGiveTheIdentityTransform() {
        let vp = Viewport2D(centerX: 9, centerY: 9, scale: 12, widthPixels: 640, heightPixels: 480)
        XCTAssertEqual(vp.screenTransform(from: vp), .identity)
    }

    // MARK: - 场景

    func testInteractiveSceneLeavesTheChromeOutAndSamplesTheMargin() {
        var document = GrapherDocument()
        document.viewport = Viewport2D(centerX: 0, centerY: 0, scale: 40, widthPixels: 400, heightPixels: 300)
        var line = Layer.makeDefault(kind: .explicit, index: 0)
        line.formula = "x"
        line.usesExplicitDomain = false
        document.layers = [line]

        let compiler = LayerCompiler()
        let request = SceneBuildRequest(
            document: document,
            compiled: compiler.compile(document),
            viewport: document.viewport,
            quality: .full,
            backingScale: 2,
            overscan: 0.25,
            includesChrome: false
        )
        let built = SceneBuilder2D.build(request)
        XCTAssertEqual(built.viewport.widthPixels, 600)
        XCTAssertEqual(built.viewport.heightPixels, 450)
        XCTAssertEqual(built.scene.commands.count, 1, "只有那条曲线，网格坐标轴不在里面")

        // 采到了视口外那一圈：x 一直采到外扩后的边上。
        let xs = built.probeCurves[0].segments.flatMap { $0 }.map(\.x)
        XCTAssertEqual(xs.min() ?? 0, built.viewport.xRange.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(xs.max() ?? 0, built.viewport.xRange.upperBound, accuracy: 1e-9)

        // 「适应内容」只认可见区里那段，否则每按一次 F 都要再缩一圈。
        let fit = try? XCTUnwrap(built.fitBounds)
        XCTAssertEqual(fit?.minX ?? 0, document.viewport.xRange.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(fit?.maxX ?? 0, document.viewport.xRange.upperBound, accuracy: 1e-9)
    }

    func testChromeSceneFollowsTheViewportItIsGiven() {
        var document = GrapherDocument()
        document.showGrid = false
        let vp = Viewport2D(centerX: 2, centerY: 1, scale: 50, widthPixels: 500, heightPixels: 400)
        let chrome = SceneBuilder2D.chromeScene(document: document, viewport: vp, backingScale: 2)
        XCTAssertEqual(chrome.scene.commands.count, 2, "只开坐标轴：横轴一条、竖轴一条")
        assertClose(chrome.layout.originPixel, vp.toScreen(x: 0, y: 0))
    }

    // MARK: - 渲染器

    /// 同一份几何：一份套变换画，一份事先把点换算好直接画，逐像素一致。线宽不随变换缩放。
    func testTransformedPassMatchesPreTransformedGeometry() throws {
        let context = try TestHarness.context()
        let renderer = try XCTUnwrap(Renderer2D(context: context))
        let transform = ScreenTransform2D(scale: 1.5, translation: SIMD2(12, -7))

        let points: [SIMD2<Double>] = [SIMD2(10, 20), SIMD2(60, 35.5), SIMD2(90, 80)]
        let rect = SIMD4<Float>(20, 40, 50, 60)
        func scene(_ map: (SIMD2<Double>) -> SIMD2<Double>, _ r: SIMD4<Float>) -> Scene2D {
            Scene2D(background: .white, commands: [
                .rects(RectPrimitiveBatch(geometry: [r], coverage: [0.5], color: RGBAColor(1, 0, 0))),
                .polyline(PolylinePrimitive(points: points.map(map), color: .black, width: 3)),
                .markers(MarkerPrimitiveBatch(positions: [map(SIMD2(30, 70))], radius: 4, color: RGBAColor(0, 0, 1))),
            ])
        }
        let moved = scene(transform.apply, SIMD4(
            Float(transform.apply(SIMD2(Double(rect.x), 0)).x),
            Float(transform.apply(SIMD2(Double(rect.y), 0)).x),
            Float(transform.apply(SIMD2(0, Double(rect.z))).y),
            Float(transform.apply(SIMD2(0, Double(rect.w))).y)
        ))

        let side = 160
        let viaTransform = try render(
            [Renderer2D.Pass(scene: renderer.prepare(scene({ $0 }, rect)), transform: transform)],
            renderer: renderer, context: context, side: side
        )
        let direct = try render(
            [Renderer2D.Pass(scene: renderer.prepare(moved))],
            renderer: renderer, context: context, side: side
        )
        var worst = 0
        for index in 0..<viaTransform.count {
            worst = max(worst, abs(Int(viaTransform[index]) - Int(direct[index])))
        }
        XCTAssertLessThanOrEqual(worst, 2, "套变换画与预先换算好再画应当一致")
        XCTAssertGreaterThan(direct.filter { $0 < 128 }.count, 100, "确实画出了东西")
    }

    private func render(
        _ passes: [Renderer2D.Pass],
        renderer: Renderer2D,
        context: MetalContext,
        side: Int
    ) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalContext.colorFormat, width: side, height: side, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = try XCTUnwrap(context.device.makeTexture(descriptor: descriptor))
        let bytesPerRow = ((side * 4 + 255) / 256) * 256
        let readback = try XCTUnwrap(context.device.makeBuffer(length: bytesPerRow * side, options: .storageModeShared))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)

        let commandBuffer = try XCTUnwrap(context.queue.makeCommandBuffer())
        renderer.encode(passes, commandBuffer: commandBuffer, descriptor: pass,
                        viewportSize: SIMD2(Double(side), Double(side)))
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: side, height: side, depth: 1),
            to: readback, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * side
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let base = readback.contents().assumingMemoryBound(to: UInt8.self)
        var out: [UInt8] = []
        out.reserveCapacity(side * side * 4)
        for y in 0..<side {
            out.append(contentsOf: UnsafeBufferPointer(start: base + y * bytesPerRow, count: side * 4))
        }
        return out
    }
}
