import CoreGraphics
import Foundation
import ImageIO
import XCTest
import UniformTypeIdentifiers
@testable import GrapherKit
@testable import GrapherRender

/// 画出来的图里有多少比例的像素与角落（底色）不同。
func inkFraction(of image: CGImage) -> Double {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(
            data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return 0 }
    let background = (bytes[0], bytes[1], bytes[2])
    var different = 0
    for i in stride(from: 0, to: bytes.count, by: 4) {
        let d = abs(Int(bytes[i]) - Int(background.0)) + abs(Int(bytes[i + 1]) - Int(background.1)) + abs(Int(bytes[i + 2]) - Int(background.2))
        if d > 24 { different += 1 }
    }
    return Double(different) / Double(width * height)
}

/// 示例目录：每个示例都能打开、公式没错、引用的图层都在、真的画得出东西，并且有中文说明。
final class DemoTests: XCTestCase {

    func testCatalogIsOrganisedByFeature() {
        let ids = Demos.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "id 不能重复")
        for category in DemoCategory.allCases {
            XCTAssertGreaterThanOrEqual(Demos.demos(in: category).count, 1, "\(category) 没有示例")
        }
        for demo in Demos.all {
            XCTAssertEqual(demo.make().dimension, demo.dimension, demo.id)
        }
        XCTAssertEqual(Demos.categories(for: .plane), [.curves, .parameters, .tangents, .data])
        XCTAssertEqual(Demos.categories(for: .space), [.surfaces, .intersections, .geometry, .projections, .gradients])
        XCTAssertNotNil(Demos.demo(id: "space.sphere-plane"))
        XCTAssertNil(Demos.demo(id: "nope"))
        XCTAssertGreaterThanOrEqual(Demos.all.count, 33)
    }

    /// 测试固定用简体中文跑：标题、说明、分类名都得有中文，说明没漏翻译。
    func testEveryDemoIsTranslated() {
        func hasCJK(_ text: String) -> Bool {
            text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        }
        for category in DemoCategory.allCases {
            XCTAssertTrue(hasCJK(category.title), "分类 \(category.title) 没翻译")
        }
        for demo in Demos.all {
            XCTAssertTrue(hasCJK(demo.title), "\(demo.id) 的标题 \(demo.title) 没翻译")
            XCTAssertTrue(hasCJK(demo.summary), "\(demo.id) 的说明没翻译：\(demo.summary)")
        }
    }

    func testEveryDemoCompilesAndReferencesExistingLayers() {
        for demo in Demos.all {
            let document = demo.make()
            XCTAssertFalse(document.layers.isEmpty, demo.id)
            let compiled = LayerCompiler().compile(document)
            for entry in compiled {
                XCTAssertFalse(entry.hasError, "\(demo.id) / \(entry.layer.name)：\(String(describing: entry.firstError))")
            }
            let ids = Set(document.layers.map(\.id))
            for layer in document.layers {
                for reference in [layer.sourceA, layer.sourceB].compactMap({ $0 }) {
                    XCTAssertTrue(ids.contains(reference), "\(demo.id) / \(layer.name) 引用了不存在的图层")
                }
                XCTAssertTrue(PlotKind.cases(for: document.dimension).contains(layer.kind),
                              "\(demo.id) 里的 \(layer.kind) 不属于 \(document.dimension)")
            }
        }
    }

    func testEveryDemoDrawsSomethingAndSurvivesSaveAndLoad() throws {
        for demo in Demos.all {
            let document = demo.make()
            let restored = try DocumentStore.decode(DocumentStore.encode(document))
            XCTAssertEqual(restored, document, "\(demo.id) 存取后变了")

            if document.dimension == .space {
                let built = SceneBuilder3D.build(SceneBuild3DRequest(
                    document: document, compiled: LayerCompiler().compile(document),
                    view: document.view3D, quality: .interactive, backingScale: 1))
                XCTAssertFalse(built.scene.isEmpty, "\(demo.id) 什么都没画")
            } else {
                let viewport = GraphSnapshot.planeViewport(of: document, pixelWidth: 640, pixelHeight: 480)
                let built = SceneBuilder2D.build(SceneBuildRequest(
                    document: document, compiled: LayerCompiler().compile(document), viewport: viewport,
                    quality: .full, backingScale: 1))
                XCTAssertEqual(built.probeCurves.count, document.layers.filter { $0.kind != .text }.count,
                               "\(demo.id) 有图层没画出来")
            }
        }
    }

    /// 每个示例真的渲染出图：非底色的像素占一定比例。顺便把图存到 `GRAPHER_DEMO_DIR`（没设就不存），方便肉眼过一遍。
    func testEveryDemoRendersAVisibleImage() throws {
        let outputDirectory = ProcessInfo.processInfo.environment["GRAPHER_DEMO_DIR"].map { URL(fileURLWithPath: $0) }
        if let outputDirectory { try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true) }
        for demo in Demos.all {
            let document = demo.make()
            let image = try XCTUnwrap(
                GraphSnapshot.image(of: document, pixelWidth: 720, pixelHeight: 540, pointScale: 1, quality: .full, labels: true),
                "\(demo.id) 渲染失败")
            XCTAssertGreaterThan(inkFraction(of: image), 0.004, "\(demo.id) 画面几乎是空的")
            if let outputDirectory,
               let destination = CGImageDestinationCreateWithURL(
                outputDirectory.appendingPathComponent("\(demo.id).png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
    }

    /// 带讲解的几个具体数字：示例里算出来的辅助图形要对。
    func testGeometryDemosCarryTheRightConstructions() throws {
        // 点 P(2,2,2.5) 到平面 x + 2y + 2z = 6：距离 (2 + 4 + 5 − 6)/3 = 5/3。
        let pointPlane = try XCTUnwrap(Demos.demo(id: "space.point-plane")).make()
        let caption = try XCTUnwrap(pointPlane.layers.first { $0.kind == .text }).formula
        XCTAssertTrue(caption.contains("1.667"), caption)
        XCTAssertTrue(pointPlane.layers.contains { $0.kind == .point && $0.name != "P" }, "垂足点")

        // 球面与平面 z = 1 的圆、圆柱与球的维维亚尼曲线，都有交线图层。
        for id in ["space.sphere-plane", "space.steinmetz", "space.viviani", "space.conic-section", "space.paraboloid-plane"] {
            let document = try XCTUnwrap(Demos.demo(id: id)).make()
            let cut = try XCTUnwrap(document.layers.first { $0.kind == .surfaceIntersection }, id)
            let built = SceneBuilder3D.build(SceneBuild3DRequest(
                document: document, compiled: LayerCompiler().compile(document),
                view: document.view3D, quality: .full, backingScale: 1))
            XCTAssertFalse(built.scene.polylines.filter { $0.layerID == cut.id }.isEmpty, "\(id) 的交线是空的")
        }

        // 异面直线：公垂线段在，说明是 lines_skew。
        let skew = try XCTUnwrap(Demos.demo(id: "space.skew-lines")).make()
        XCTAssertTrue(skew.layers.contains { $0.kind == .spaceCurve && $0.lineStyle.isDashed }, "公垂线段")
    }
}
