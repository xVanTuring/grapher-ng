import simd
import XCTest
@testable import GrapherKit

/// 坐标盒的线框与刻度：网格画在背向相机的墙上，轴名在棱的末端，原点出了盒子就不画坐标轴。
final class Chrome3DTests: XCTestCase {

    private func view(azimuth: Double = 0.55, elevation: Double = 0.45) -> View3D {
        var v = View3D.standard
        v.widthPixels = 1000
        v.heightPixels = 800
        v.azimuth = azimuth
        v.elevation = elevation
        return v
    }

    /// 网格线所在的墙（某一坐标恒为 ±1 且整条线贴在墙上）。
    private func gridWalls(_ result: Chrome3D.Result, document: GrapherDocument) -> Set<String> {
        var walls = Set<String>()
        for line in result.scene.polylines where line.color == document.theme.grid {
            let a = line.points[0], b = line.points[1]
            // 刻度正好落在盒子边界上的那条线同时贴着两面墙，分不清，跳过。
            let onWalls = (0..<3).filter { a[$0] == b[$0] && abs(a[$0]) == 1 }
            if onWalls.count == 1 { walls.insert("\(onWalls[0]):\(a[onWalls[0]])") }
        }
        return walls
    }

    func testGridSitsOnTheWallsFacingAwayFromTheCamera() {
        let document = GrapherDocument(dimension: .space)
        // 默认视角相机在 (+x, +y, +z) 一侧：网格在 x = -1、y = -1、z = -1 三面墙上。
        let front = Chrome3D.make(view: view(), document: document, backingScale: 2)
        XCTAssertEqual(gridWalls(front, document: document), ["0:-1.0", "1:-1.0", "2:-1.0"])
        // 转到对面、从下往上看：三面墙都换到另一侧。
        let back = Chrome3D.make(view: view(azimuth: 0.55 + .pi, elevation: -0.45), document: document, backingScale: 2)
        XCTAssertEqual(gridWalls(back, document: document), ["0:1.0", "1:1.0", "2:1.0"])
    }

    func testEveryAxisIsNamedAndTicked() {
        let result = Chrome3D.make(view: view(), document: GrapherDocument(dimension: .space), backingScale: 2)
        let names = result.labels.compactMap { label -> String? in
            if case .axisName(let name) = label.kind { return name }
            return nil
        }
        XCTAssertEqual(names.sorted(), ["x", "y", "z"])
        for axis in 0..<3 {
            let ticks = result.labels.filter { label in
                if case .tick = label.kind { return label.axis == axis }
                return false
            }
            XCTAssertGreaterThanOrEqual(ticks.count, 3, "第 \(axis) 轴的刻度太少")
        }
    }

    func testAxesThroughTheOriginOnlyWhenItIsInsideTheBox() {
        let document = GrapherDocument(dimension: .space)
        var v = view()
        let inside = Chrome3D.make(view: v, document: document, backingScale: 2)
        XCTAssertEqual(inside.scene.polylines.filter { $0.color == document.theme.axes }.count, 3)
        v.center = SIMD3(20, 0, 0)
        let outside = Chrome3D.make(view: v, document: document, backingScale: 2)
        XCTAssertEqual(outside.scene.polylines.filter { $0.color == document.theme.axes }.count, 0)
    }

    func testTogglesAreRespected() {
        var document = GrapherDocument(dimension: .space)
        document.showGrid = false
        document.showAxes = false
        document.showTickLabels = false
        let result = Chrome3D.make(view: view(), document: document, backingScale: 2)
        XCTAssertEqual(result.scene.polylines.count, 12, "只剩 12 条棱")
        XCTAssertTrue(result.labels.isEmpty)
    }
}
