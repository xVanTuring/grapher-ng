import simd
import XCTest
@testable import GrapherKit

/// 3D 视角：盒子归一化、投影方向、交互手感与文件兼容。
final class View3DTests: XCTestCase {

    private func view(width: Double = 1000, height: Double = 800) -> View3D {
        var v = View3D.standard
        v.widthPixels = width
        v.heightPixels = height
        return v
    }

    private func assertClose(_ a: Double, _ b: Double, _ accuracy: Double = 1e-6, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a, b, accuracy: accuracy, message, file: file, line: line)
    }

    // MARK: - 盒子

    func testNormalizedRoundTripsAndTheBoxIsTheUnitCube() {
        var v = view()
        v.center = SIMD3(1, -2, 3)
        v.halfExtent = 5
        let p = SIMD3(6.0, -7.0, 3.0)
        let n = v.normalized(p)
        XCTAssertEqual(n, SIMD3(1, -1, 0))
        XCTAssertEqual(v.data(n), p)
        XCTAssertEqual(v.range(axis: 2), -2...8)
    }

    func testBoxTransformMatchesRenormalizing() {
        var source = view()
        source.center = SIMD3(0.5, 0, -1)
        source.halfExtent = 4
        var current = source
        current.pan(byPixels: SIMD2(40, -25))
        current.zoom(by: 1.6)
        let (scale, translation) = current.boxTransform(from: source)
        for p in [SIMD3(1.0, 2.0, 3.0), SIMD3(-3.0, 0.5, -2.0)] {
            let viaTransform = source.normalized(p) * scale + translation
            let direct = current.normalized(p)
            for axis in 0..<3 { assertClose(viaTransform[axis], direct[axis], 1e-9) }
        }
    }

    // MARK: - 投影

    func testBoxCentreProjectsToTheUnobscuredCentre() throws {
        var v = view()
        let centre = try XCTUnwrap(v.project(.zero))
        assertClose(centre.x, 500, 1e-6)
        assertClose(centre.y, 400, 1e-6)

        // 左边被 300 像素宽的毛玻璃侧栏盖住：盒心推到右边那块的中心。
        v.insetLeft = 300
        let pushed = try XCTUnwrap(v.project(.zero))
        assertClose(pushed.x, 300 + 700.0 / 2, 1e-6)
        assertClose(pushed.y, 400, 1e-6)
    }

    /// 默认视角就是课本上的样子：x 轴朝左下，y 轴朝右，z 轴朝上。
    func testStandardViewLooksLikeTheTextbook() throws {
        let v = view()
        let origin = try XCTUnwrap(v.project(.zero))
        let x = try XCTUnwrap(v.project(SIMD3(1, 0, 0)))
        let y = try XCTUnwrap(v.project(SIMD3(0, 1, 0)))
        let z = try XCTUnwrap(v.project(SIMD3(0, 0, 1)))
        XCTAssertLessThan(x.x, origin.x, "x 轴朝左")
        XCTAssertGreaterThan(x.y, origin.y, "x 轴朝下（离观察者近）")
        XCTAssertGreaterThan(y.x, origin.x, "y 轴朝右")
        XCTAssertLessThan(z.y, origin.y, "z 轴朝上")
        assertClose(z.x, origin.x, 1e-6, "z 轴竖直")
    }

    func testTheWholeBoxFitsInsideTheCanvasFromAnyAngle() throws {
        var v = view(width: 900, height: 600)
        for azimuth in stride(from: -3.0, through: 3.0, by: 0.7) {
            for elevation in [-1.4, -0.6, 0.0, 0.5, 1.4] {
                v.azimuth = azimuth
                v.elevation = elevation
                for corner in [-1.0, 1.0] {
                    for c2 in [-1.0, 1.0] {
                        for c3 in [-1.0, 1.0] {
                            let p = try XCTUnwrap(v.project(SIMD3(corner, c2, c3)))
                            // 外接球正好装进画面短边：盒角最多贴到边上。
                            XCTAssertTrue((-0.5...900.5).contains(p.x) && (-0.5...600.5).contains(p.y),
                                          "角点 (\(corner), \(c2), \(c3)) 在 az=\(azimuth) el=\(elevation) 时出了画布：\(p)")
                            XCTAssertTrue((0...1).contains(p.z), "深度在近远裁剪面之间")
                        }
                    }
                }
            }
        }
    }

    func testNearerPointsHaveSmallerDepth() throws {
        let v = view()
        let towardsEye = simd_normalize(v.eye) * 0.9
        let near = try XCTUnwrap(v.project(towardsEye))
        let far = try XCTUnwrap(v.project(-towardsEye))
        XCTAssertLessThan(near.z, far.z)
    }

    // MARK: - 交互

    // MARK: - 正交与轴向视图

    /// 屏幕上的位置（像素，左上角原点）。
    private func screen(_ v: View3D, _ p: SIMD3<Double>) throws -> SIMD2<Double> {
        let s = try XCTUnwrap(v.project(p))
        return SIMD2(s.x, s.y)
    }

    func testAxisViewsLayTheOtherTwoAxesFlat() throws {
        // depth：朝着观察者的方向（x 从 +x 看、y 从 -y 看、z 从 +z 俯视）。
        let cases: [(View3D.AxisView, right: SIMD3<Double>, up: SIMD3<Double>, depth: SIMD3<Double>)] = [
            (.x, SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0)),
            (.y, SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, -1, 0)),
            (.z, SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
        ]
        for (axis, right, up, depth) in cases {
            var v = view()
            v.look(along: axis)
            XCTAssertTrue(v.isOrthographic)
            let origin = try screen(v, .zero)
            let r = try screen(v, right) - origin
            let u = try screen(v, up) - origin
            XCTAssertGreaterThan(r.x, 100, "\(axis)")
            assertClose(r.y, 0, 1e-6, "\(axis)")
            assertClose(u.x, 0, 1e-6, "\(axis)")
            XCTAssertLessThan(u.y, -100, "\(axis)")
            // 沿视线的方向在屏幕上是一个点，只差深度：靠近相机的一端深度更小。
            let d = try screen(v, depth) - origin
            assertClose(d.x, 0, 1e-6, "\(axis)")
            assertClose(d.y, 0, 1e-6, "\(axis)")
            let near = try XCTUnwrap(v.project(depth)).z
            let far = try XCTUnwrap(v.project(-depth)).z
            XCTAssertLessThan(near, far, "\(axis)")
        }
    }

    func testOrthographicHasNoPerspective() throws {
        var v = view()
        v.isOrthographic = true
        // 盒内同一个屏幕位置的前后两点，投影到同一处；透视下则不然。
        let front = SIMD3(0.5, 0.5, 1.0)
        let back = front - v.basis.forward * 1.5
        let a = try screen(v, front), b = try screen(v, back)
        assertClose(a.x, b.x, 1e-6); assertClose(a.y, b.y, 1e-6)
        v.isOrthographic = false
        let c = try screen(v, front), d = try screen(v, back)
        XCTAssertGreaterThan(simd_length(c - d), 1)
    }

    func testOrthographicKeepsTheBoxSizeAtTheCentreAndFits() throws {
        var v = view()
        // 取与视线垂直、过盒心的一点：它与盒心同深度，两种投影下该一样远。
        let sideways = v.basis.right
        let perspective = try screen(v, sideways) - screen(v, .zero)
        v.isOrthographic = true
        let ortho = try screen(v, sideways) - screen(v, .zero)
        assertClose(simd_length(perspective), simd_length(ortho), 1e-6)
        // 任何角度盒子都在画布里、深度在 0…1 内。
        for azimuth in stride(from: 0.0, to: 6.2, by: 0.7) {
            for elevation in [-1.4, -0.4, 0.0, 0.8, 1.55] {
                v.azimuth = azimuth; v.elevation = elevation
                for sx in [-1.0, 1.0] { for sy in [-1.0, 1.0] { for sz in [-1.0, 1.0] {
                    let s = try XCTUnwrap(v.project(SIMD3(sx, sy, sz)))
                    XCTAssertTrue((0...v.widthPixels).contains(s.x) && (0...v.heightPixels).contains(s.y))
                    XCTAssertTrue((0...1).contains(s.z))
                }}}
            }
        }
    }

    func testOrthographicInsetShiftsTheCentreLikePerspective() throws {
        var v = view()
        v.insetLeft = 300
        v.isOrthographic = true
        let s = try screen(v, .zero)
        assertClose(s.x, v.focusX, 1e-6)
        assertClose(s.y, v.focusY, 1e-6)
    }

    func testPanFollowsThePointerInAxisView() throws {
        var v = view()
        v.look(along: .z)
        let anchor = SIMD3(1.0, 1.0, 0.0)
        let before = try screen(v, v.normalized(anchor))
        v.pan(byPixels: SIMD2(30, -20))
        let after = try screen(v, v.normalized(anchor))
        assertClose(after.x - before.x, 30, 1e-6)
        assertClose(after.y - before.y, -20, 1e-6)
    }

    func testOrthographicFlagIsSavedAndOlderFilesAreStillPerspective() throws {
        var v = View3D.standard
        v.isOrthographic = true
        let data = try JSONEncoder().encode(v)
        XCTAssertTrue(try JSONDecoder().decode(View3D.self, from: data).isOrthographic)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "isOrthographic")
        let older = try JSONSerialization.data(withJSONObject: object)
        XCTAssertFalse(try JSONDecoder().decode(View3D.self, from: older).isOrthographic)
    }

    func testOrbitTurnsAndClampsTheElevation() {
        var v = view()
        let azimuth = v.azimuth
        v.orbit(byPoints: SIMD2(100, 0))
        assertClose(v.azimuth, azimuth - 100 * View3D.orbitRadiansPerPoint)
        v.orbit(byPoints: SIMD2(0, 100_000))
        assertClose(v.elevation, View3D.elevationLimit)
        v.orbit(byPoints: SIMD2(0, -1_000_000))
        assertClose(v.elevation, -View3D.elevationLimit)
    }

    /// 平移跟手：往右拖 N 像素，盒心那个点在屏幕上也往右走 N 像素。
    func testPanFollowsThePointer() throws {
        var v = view()
        let before = try XCTUnwrap(v.project(.zero))
        let anchor = v.center
        v.pan(byPixels: SIMD2(37, -21))
        let after = try XCTUnwrap(v.project(v.normalized(anchor)))
        assertClose(after.x - before.x, 37, 1e-6)
        assertClose(after.y - before.y, -21, 1e-6)
    }

    func testZoomChangesTheRangeNotTheBoxOnScreen() throws {
        var v = view()
        let corner = try XCTUnwrap(v.project(SIMD3(1, 1, 1)))
        v.zoom(by: 2)
        XCTAssertEqual(v.halfExtent, 2)
        let after = try XCTUnwrap(v.project(SIMD3(1, 1, 1)))
        assertClose(corner.x, after.x)
        assertClose(corner.y, after.y)
    }

    func testFitFramesTheBoundsAndResetsTheBoxZoom() {
        var v = view()
        v.cameraZoom = 3
        v.fit(min: SIMD3(-1, 0, 2), max: SIMD3(3, 1, 4), margin: 0)
        XCTAssertEqual(v.center, SIMD3(1, 0.5, 3))
        XCTAssertEqual(v.halfExtent, 2)
        XCTAssertEqual(v.cameraZoom, 1)
    }

    // MARK: - 放大盒子

    /// 放大盒子：盒子连同图形在屏幕上按倍数变大，框住的数据范围不变。
    func testCameraZoomEnlargesTheBoxButKeepsTheRange() throws {
        var v = view()
        let centre = try XCTUnwrap(v.project(.zero))
        let corner = try XCTUnwrap(v.project(SIMD3(1, 1, 1)))
        v.zoomCamera(by: 2)
        XCTAssertEqual(v.halfExtent, View3D.standard.halfExtent)
        let zoomed = try XCTUnwrap(v.project(SIMD3(1, 1, 1)))
        assertClose(zoomed.x - centre.x, 2 * (corner.x - centre.x), 1e-6)
        assertClose(zoomed.y - centre.y, 2 * (corner.y - centre.y), 1e-6)
    }

    func testPanStillFollowsThePointerWhenZoomedIn() throws {
        var v = view()
        v.zoomCamera(by: 3)
        let before = try XCTUnwrap(v.project(.zero))
        let anchor = v.center
        v.pan(byPixels: SIMD2(25, 40))
        let after = try XCTUnwrap(v.project(v.normalized(anchor)))
        assertClose(after.x - before.x, 25, 1e-6)
        assertClose(after.y - before.y, 40, 1e-6)
    }

    func testCameraZoomIsClamped() {
        var v = view()
        v.zoomCamera(by: 1e6)
        XCTAssertEqual(v.cameraZoom, View3D.cameraZoomRange.upperBound)
        v.zoomCamera(by: 1e-9)
        XCTAssertEqual(v.cameraZoom, View3D.cameraZoomRange.lowerBound)
    }

    func testOlderSpaceViewsOpenAtTheDefaultBoxSize() throws {
        let json = #"{"center":[0,0,0],"halfExtent":4,"azimuth":0.5,"elevation":0.4}"#
        let decoded = try JSONDecoder().decode(View3D.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.cameraZoom, 1)
        XCTAssertEqual(decoded.azimuth, 0.5)
    }

    // MARK: - 文件

    func testWindowStateNeverReachesTheFile() throws {
        var v = view()
        v.insetLeft = 440
        v.widthPixels = 3000
        let json = String(decoding: try JSONEncoder().encode(v), as: UTF8.self)
        XCTAssertFalse(json.contains("inset") || json.contains("Pixels"), json)
        let decoded = try JSONDecoder().decode(View3D.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.center, v.center)
        XCTAssertEqual(decoded.insetLeft, 0)
    }

    func testPlaneDocumentsFromBeforeThreeDStillOpen() throws {
        // 去掉 3D 新增的字段，模拟 2D 时代存下的文件。
        let original = GrapherDocument.sample()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: DocumentStore.encode(original)) as? [String: Any])
        object["dimension"] = nil
        object["view3D"] = nil
        var layers = try XCTUnwrap(object["layers"] as? [[String: Any]])
        for index in layers.indices {
            layers[index]["tertiaryFormula"] = nil
            layers[index]["domain2Lower"] = nil
            layers[index]["domain2Upper"] = nil
        }
        object["layers"] = layers
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try DocumentStore.decode(legacy)
        XCTAssertEqual(decoded.dimension, .plane)
        XCTAssertEqual(decoded.view3D, .standard)
        XCTAssertEqual(decoded.layers.map(\.formula), original.layers.map(\.formula))
        XCTAssertEqual(decoded.layers.first?.tertiaryFormula, "")
    }

    func testSpaceDocumentRoundTrips() throws {
        var document = GrapherDocument.sample3D()
        document.view3D.azimuth = 1.1
        document.view3D.halfExtent = 7
        let decoded = try DocumentStore.decode(DocumentStore.encode(document))
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.dimension, .space)
        XCTAssertTrue(decoded.layers.allSatisfy { $0.kind.dimension == .space })
    }

    func testKindsAreSplitByDimension() {
        XCTAssertEqual(PlotKind.cases(for: .plane), [.explicit, .parametric, .polar, .implicit, .region, .tangent, .text, .scatter])
        XCTAssertEqual(PlotKind.cases(for: .space), [
            .surface, .parametricSurface, .spaceCurve, .implicitSurface, .surfaceIntersection, .point, .projection, .tangentPlane, .gradientField, .gradientFlow,
            // 平面曲线也能放进立体图（画在 z = 0 上或延伸成竖直曲面），不等式区域不行。
            .explicit, .parametric, .polar, .implicit, .text,
        ])
    }
}
