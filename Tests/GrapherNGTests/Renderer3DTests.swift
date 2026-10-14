import CoreGraphics
import simd
import XCTest
@testable import GrapherKit
@testable import GrapherRender

/// 3D 渲染的像素断言：离屏渲染一张图，看该有颜色的地方有、该是底色的地方是底色。
final class Renderer3DTests: XCTestCase {

    private let width = 320
    private let height = 240

    private func view(elevation: Double = View3D.standard.elevation) -> View3D {
        var v = View3D.standard
        v.widthPixels = Double(width)
        v.heightPixels = Double(height)
        v.elevation = elevation
        return v
    }

    private func scene(_ layers: [Layer], view: View3D) -> Scene3D {
        var document = GrapherDocument(dimension: .space)
        document.layers = layers
        return SceneBuilder3D.build(SceneBuild3DRequest(
            document: document, compiled: LayerCompiler().compile(document),
            view: view, quality: .full, backingScale: 1)).scene
    }

    private func render(_ content: Scene3D?, chrome: Scene3D? = nil, view: View3D) throws -> Raster {
        let context = try TestHarness.context()
        let renderer = try XCTUnwrap(OffscreenRenderer3D(context: context, pixelWidth: width, pixelHeight: height))
        let image = renderer.makeImage(content: content, contentView: view, chrome: chrome, view: view, background: .white)
        return try XCTUnwrap(Raster(image))
    }

    private func layer(_ kind: PlotKind, _ formula: String, color: RGBAColor) -> Layer {
        var layer = Layer.makeDefault(kind: kind, index: 0)
        layer.formula = formula
        layer.lineStyle.color = color
        return layer
    }

    private func isBackground(_ p: Pixel) -> Bool { p.r > 250 && p.g > 250 && p.b > 250 }

    // MARK: -

    func testPipelinesCompileAndLayoutsMatchTheShaders() throws {
        let context = try TestHarness.context()
        XCTAssertNotNil(Renderer3D(context: context), "着色器（含 clip_distance）要能编译")
        XCTAssertEqual(MemoryLayout<MeshVertex3D>.stride, 48)
        XCTAssertEqual(MemoryLayout<MeshVertex3D>.offset(of: \.normal), 16)
        XCTAssertEqual(MemoryLayout<MeshVertex3D>.offset(of: \.parameter), 32)
        XCTAssertEqual(MemoryLayout<LineInstance3D>.stride, 64)
        XCTAssertEqual(MemoryLayout<LineInstance3D>.offset(of: \.color), 32)
        XCTAssertEqual(MemoryLayout<LineInstance3D>.offset(of: \.halfWidth), 48)
        XCTAssertEqual(MemoryLayout<Uniforms3D>.stride, 144)
        XCTAssertEqual(MemoryLayout<Uniforms3D>.offset(of: \.lineBoost), 108)
        XCTAssertEqual(MemoryLayout<Uniforms3D>.offset(of: \.tint), 112)
        XCTAssertEqual(MemoryLayout<Uniforms3D>.offset(of: \.alphaScale), 128)
        XCTAssertEqual(MemoryLayout<MeshStyle3D>.stride, 32)
        XCTAssertEqual(MemoryLayout<MeshStyle3D>.offset(of: \.highlight), 16)
    }

    private func render(_ content: Scene3D, view: View3D, highlight: UUID?) throws -> Raster {
        let context = try TestHarness.context()
        let renderer = try XCTUnwrap(OffscreenRenderer3D(context: context, pixelWidth: width, pixelHeight: height))
        let image = renderer.makeImage(content: content, contentView: view, chrome: nil, view: view,
                                       background: .white, highlight: highlight)
        return try XCTUnwrap(Raster(image))
    }

    /// 半透明的面透出背后的东西：不透明度 0.4 的红面盖在白底上是浅红，盖在不透明蓝面上带蓝。
    func testTranslucentSurfaceBlendsWithWhatIsBehind() throws {
        let v = view(elevation: 1.5)
        var glass = layer(.surface, "1", color: RGBAColor(1, 0, 0))
        glass.fillStyle.opacity = 0.4
        let onWhite = try render(scene([glass], view: v), view: v).pixel(x: width / 2, y: height / 2)
        XCTAssertGreaterThan(onWhite.r, 200, "仍偏红：\(onWhite)")
        XCTAssertGreaterThan(onWhite.g, 90, "但不是纯红，白底透出来：\(onWhite)")
        XCTAssertLessThan(onWhite.g, 220, "也不是白：\(onWhite)")

        let blue = layer(.surface, "-1", color: RGBAColor(0, 0, 1))
        let both = try render(scene([blue, glass], view: v), view: v).pixel(x: width / 2, y: height / 2)
        XCTAssertGreaterThan(both.b, 100, "透出背后的蓝面：\(both)")
        XCTAssertGreaterThan(both.r, 60, "红面的颜色也在：\(both)")
    }

    /// 选中的曲面往橙色偏；没选中的不变。
    func testHighlightedSurfaceShiftsTowardsOrange() throws {
        let v = view()
        let sphere = layer(.implicitSurface, "x^2 + y^2 + z^2 - 4", color: RGBAColor(0.2, 0.3, 0.9))
        let content = scene([sphere], view: v)
        let plain = try render(content, view: v, highlight: nil).pixel(x: width / 2, y: height / 2)
        let other = try render(content, view: v, highlight: UUID()).pixel(x: width / 2, y: height / 2)
        let selected = try render(content, view: v, highlight: sphere.id).pixel(x: width / 2, y: height / 2)
        XCTAssertEqual(plain, other, "高亮别的图层不影响它")
        XCTAssertGreaterThan(selected.r, plain.r + 25, "红分量上去了：\(plain) → \(selected)")
        XCTAssertLessThan(selected.b, plain.b, "蓝分量下去了：\(plain) → \(selected)")
    }

    /// 选中的曲线外面有一圈光晕：线旁边几个像素原本是底色，现在偏橙。
    func testHighlightedCurveHasAHalo() throws {
        let v = view()
        let right = SIMD3<Float>(v.basis.right)
        let id = UUID()
        let line = Polyline3D(points: [-right * 0.8, right * 0.8], color: RGBAColor(0, 0.4, 0), width: 3, layerID: id)
        let content = Scene3D(polylines: [line])
        let beside = (x: width / 2, y: height / 2 - 4)
        XCTAssertTrue(isBackground(try render(content, view: v, highlight: nil).pixel(x: beside.x, y: beside.y)))
        let halo = try render(content, view: v, highlight: id).pixel(x: beside.x, y: beside.y)
        XCTAssertFalse(isBackground(halo), "光晕：\(halo)")
        XCTAssertGreaterThan(halo.r, halo.b + 20, "偏橙：\(halo)")
    }

    func testSphereIsDrawnAtTheCentre() throws {
        let v = view()
        let sphere = layer(.implicitSurface, "x^2 + y^2 + z^2 - 4", color: RGBAColor(0.9, 0.2, 0.2))
        let raster = try render(scene([sphere], view: v), view: v)
        let centre = raster.pixel(x: width / 2, y: height / 2)
        XCTAssertFalse(isBackground(centre), "盒心处是球面：\(centre)")
        XCTAssertGreaterThan(centre.r, centre.g + 40, "是球面的红色（经光照）：\(centre)")
        XCTAssertTrue(isBackground(raster.pixel(x: 4, y: 4)), "角落是底色")
    }

    /// 坐标盒外的部分整片裁掉：z = 10 的平面完全在盒子（±4）之上，一个像素都不该画。
    func testGeometryOutsideTheBoxIsClipped() throws {
        let v = view()
        let plane = layer(.surface, "10", color: RGBAColor(0, 0, 1))
        let content = scene([plane], view: v)
        XCTAssertGreaterThan(content.meshes.first?.triangleCount ?? 0, 0, "网格是有的，只是在盒外")
        let raster = try render(content, view: v)
        for y in stride(from: 0, to: height, by: 6) {
            for x in stride(from: 0, to: width, by: 6) {
                XCTAssertTrue(isBackground(raster.pixel(x: x, y: y)), "(\(x), \(y)) 不该有颜色")
            }
        }
    }

    /// 从正上方往下看，z = 1 的蓝面挡住 z = -1 的红面。
    func testNearerSurfaceHidesFartherOne() throws {
        let v = view(elevation: 1.5)
        let low = layer(.surface, "-1", color: RGBAColor(1, 0, 0))
        let high = layer(.surface, "1", color: RGBAColor(0, 0, 1))
        let raster = try render(scene([low, high], view: v), view: v)
        let centre = raster.pixel(x: width / 2, y: height / 2)
        XCTAssertGreaterThan(centre.b, centre.r + 40, "看到的是上面那张蓝面：\(centre)")
    }

    func testCurveIsDrawnWithItsColour() throws {
        let v = view()
        // 一条穿过盒心、指向相机右方的线段，盒心处必然有它。
        let right = SIMD3<Float>(v.basis.right)
        let line = Polyline3D(points: [-right * 0.8, right * 0.8], color: RGBAColor(0, 0.6, 0), width: 4)
        let raster = try render(Scene3D(polylines: [line]), view: v)
        let centre = raster.pixel(x: width / 2, y: height / 2)
        XCTAssertGreaterThan(centre.g, centre.r + 60, "线是绿色：\(centre)")
        XCTAssertTrue(isBackground(raster.pixel(x: width / 2, y: height / 2 - 20)), "线外是底色")
    }

    /// 曲面挡住它背后的曲线：曲线在球心，从外面看不见。
    func testSurfaceHidesCurveBehindIt() throws {
        let v = view()
        let sphere = layer(.implicitSurface, "x^2 + y^2 + z^2 - 4", color: RGBAColor(0.8, 0.8, 0.8))
        var content = scene([sphere], view: v)
        let right = SIMD3<Float>(v.basis.right)
        content.polylines = [Polyline3D(points: [-right * 0.2, right * 0.2], color: RGBAColor(0, 0, 0), width: 6)]
        let raster = try render(content, view: v)
        let centre = raster.pixel(x: width / 2, y: height / 2)
        XCTAssertGreaterThan(Int(centre.r) + Int(centre.g) + Int(centre.b), 3 * 120, "黑线藏在球里，看到的是球面：\(centre)")
    }
}
