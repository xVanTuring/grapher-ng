import XCTest
@testable import GrapherNG

/// 图层拖拽排序：表格给的落点是「插到第 row 行之前」，模型按它挪（`moveElements`），
/// 表格动画按 `row > source ? row - 1 : row` 挪。两边必须落到同一个位置，否则松手后
/// 列表显示的顺序与实际画的顺序不一致。
final class LayerMoveTests: XCTestCase {

    func testEveryDropPositionAgreesWithTheTableAnimation() {
        let original = ["a", "b", "c", "d", "e"]
        for source in original.indices {
            for row in 0...original.count where row != source && row != source + 1 {
                var moved = original
                moved.moveElements(fromOffsets: IndexSet(integer: source), toOffset: row)
                let finalRow = row > source ? row - 1 : row
                XCTAssertEqual(moved[finalRow], original[source], "源行 \(source) 插到 \(row) 之前")
                XCTAssertEqual(moved.count, original.count)
                XCTAssertEqual(Set(moved), Set(original), "不丢也不重复")
            }
        }
    }

    func testDroppingBackInPlaceChangesNothing() {
        var items = ["a", "b", "c"]
        items.moveElements(fromOffsets: IndexSet(integer: 1), toOffset: 1)
        XCTAssertEqual(items, ["a", "b", "c"])
        items.moveElements(fromOffsets: IndexSet(integer: 1), toOffset: 2)
        XCTAssertEqual(items, ["a", "b", "c"])
    }

    func testMovingToTheEnd() {
        var items = ["a", "b", "c"]
        items.moveElements(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(items, ["b", "c", "a"])
    }
}
