import simd
import XCTest
@testable import GrapherKit

/// 立体图点选：点到曲面、曲线、被挡住的曲线、贴在曲面上的交线，点空白处。
final class ScenePickerTests: XCTestCase {

    private func layer(_ kind: PlotKind, _ formula: String, secondary: String = "", tertiary: String = "") -> Layer {
        var layer = Layer.makeDefault(kind: kind, index: 0)
        layer.formula = formula
        if !secondary.isEmpty { layer.secondaryFormula = secondary }
        if !tertiary.isEmpty { layer.tertiaryFormula = tertiary }
        return layer
    }

    private func build(_ layers: [Layer]) -> BuiltScene3D {
        var document = GrapherDocument(dimension: .space)
        document.layers = layers
        return SceneBuilder3D.build(SceneBuild3DRequest(
            document: document, compiled: LayerCompiler().compile(document),
            view: .standard, quality: .full, backingScale: 2))
    }

    /// 数据坐标点在画布上的像素。
    private func pixel(_ p: SIMD3<Double>, _ view: View3D = .standard) -> SIMD2<Double> {
        let screen = view.project(view.normalized(p))!
        return SIMD2(screen.x, screen.y)
    }

    private func pick(_ built: BuiltScene3D, at p: SIMD3<Double>) -> UUID? {
        ScenePicker3D.pick(built.scene, source: built.view, view: .standard, pixel: pixel(p))
    }

    func testPicksTheSurfaceUnderTheCursorAndNothingInEmptySpace() {
        let sphere = layer(.implicitSurface, "x^2 + y^2 + z^2 - 4")
        let floor = layer(.surface, "-3")
        let built = build([sphere, floor])
        // 球心的屏幕位置：球面在最前面。
        XCTAssertEqual(pick(built, at: .zero), sphere.id)
        // 地面远处的一点：只有地面。
        XCTAssertEqual(pick(built, at: SIMD3(3, -3, -3)), floor.id)
        // 画布角落什么都没有。
        XCTAssertNil(ScenePicker3D.pick(built.scene, source: built.view, view: .standard, pixel: SIMD2(5, 5)))
    }

    func testPicksACurveButNotOneHiddenBehindAnOpaqueSurface() {
        let sphere = layer(.implicitSurface, "x^2 + y^2 + z^2 - 4")
        let axis = layer(.spaceCurve, "t", secondary: "0", tertiary: "0")
        var line = axis
        line.domainLower = -3.9
        line.domainUpper = 3.9
        // 线在球外的一段：点中线。
        XCTAssertEqual(pick(build([sphere, line]), at: SIMD3(3.4, 0, 0)), line.id)
        // 线穿过球心的一段被球面挡在后面：点中球。
        XCTAssertEqual(pick(build([sphere, line]), at: .zero), sphere.id)

        // 球半透明之后挡不住线。
        var glass = sphere
        glass.fillStyle.opacity = 0.4
        XCTAssertEqual(pick(build([glass, line]), at: .zero), line.id)
    }

    func testAnIntersectionCurveLyingOnSurfacesIsPickable() {
        let sphere = layer(.implicitSurface, "x^2 + y^2 + z^2 - 4")
        let floor = layer(.surface, "1")
        var cut = Layer.makeDefault(kind: .surfaceIntersection, index: 2)
        cut.sourceA = sphere.id
        cut.sourceB = floor.id
        // 圆上正对相机的那一点（方位角 0.55 的方向）：前面没有别的东西挡着。
        let a = 0.55
        let r = 3.0.squareRoot()
        let built = build([sphere, floor, cut])
        XCTAssertEqual(pick(built, at: SIMD3(r * cos(a), r * sin(a), 1)), cut.id)
    }

    func testTranslucencyAndLayerTagsInTheScene() {
        var glass = layer(.surface, "0")
        glass.fillStyle.opacity = 0.3
        let solid = layer(.surface, "1")
        let built = build([glass, solid])
        XCTAssertEqual(built.scene.meshes.count, 2)
        XCTAssertEqual(built.scene.meshes[0].layerID, glass.id)
        XCTAssertTrue(built.scene.meshes[0].isTranslucent)
        XCTAssertEqual(built.scene.meshes[0].color.a, 0.3, accuracy: 1e-9)
        XCTAssertEqual(built.scene.meshes[1].layerID, solid.id)
        XCTAssertFalse(built.scene.meshes[1].isTranslucent)
    }

    func testHiddenLayersAreNotPickable() {
        var sphere = layer(.implicitSurface, "x^2 + y^2 + z^2 - 4")
        sphere.isVisible = false
        XCTAssertNil(pick(build([sphere]), at: .zero))
    }

    func testRayTriangle() throws {
        let hit = ScenePicker3D.rayTriangle(
            SIMD3(0.2, 0.2, 5), SIMD3(0, 0, -1), SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        XCTAssertEqual(try XCTUnwrap(hit), 5, accuracy: 1e-12)
        XCTAssertNil(ScenePicker3D.rayTriangle(
            SIMD3(2, 2, 5), SIMD3(0, 0, -1), SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), "三角形外")
        XCTAssertNil(ScenePicker3D.rayTriangle(
            SIMD3(0.2, 0.2, -5), SIMD3(0, 0, -1), SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), "在射线后面")
    }
}
