import XCTest
@testable import GrapherKit

/// 参数播放的步进：匀速、往返折返、循环回绕、大步长、非法输入。
final class ParameterPlaybackTests: XCTestCase {

    private func step(_ value: Double, _ direction: Double = 1, _ seconds: Double, mode: PlaybackMode = .pingPong,
                      range: ClosedRange<Double> = 0...10, sweep: Double = 5) -> (value: Double, direction: Double) {
        ParameterPlayback.advance(value: value, direction: direction, lower: range.lowerBound, upper: range.upperBound,
                                  seconds: seconds, sweepSeconds: sweep, mode: mode)
    }

    func testMovesAtAConstantSpeed() {
        // 范围 10、扫满要 5 秒：每秒走 2。
        XCTAssertEqual(step(0, 1, 1).value, 2, accuracy: 1e-12)
        XCTAssertEqual(step(3, 1, 0.5).value, 4, accuracy: 1e-12)
        XCTAssertEqual(step(5, -1, 1).value, 3, accuracy: 1e-12)
        XCTAssertEqual(step(4, 1, 0).value, 4, accuracy: 1e-12)
    }

    func testPingPongBouncesOffBothEnds() {
        let top = step(9, 1, 1.5)   // 9 → 10（0.5 秒）→ 往回 1.0 秒 = 2 → 8
        XCTAssertEqual(top.value, 8, accuracy: 1e-12)
        XCTAssertEqual(top.direction, -1)
        let bottom = step(1, -1, 1)  // 1 → 0（0.5 秒）→ 往上 0.5 秒 = 1 → 1
        XCTAssertEqual(bottom.value, 1, accuracy: 1e-12)
        XCTAssertEqual(bottom.direction, 1)
    }

    func testPingPongSurvivesHugeSteps() {
        // 一步走 12.5 秒 = 2.5 个整范围：0 → 10 → 0 → 5，方向向上。
        let result = step(0, 1, 12.5)
        XCTAssertEqual(result.value, 5, accuracy: 1e-9)
        XCTAssertEqual(result.direction, 1)
        // 反方向同理。
        let down = step(10, -1, 12.5)
        XCTAssertEqual(down.value, 5, accuracy: 1e-9)
        XCTAssertEqual(down.direction, -1)
        for seconds in stride(from: 0.0, through: 40, by: 0.7) {
            let v = step(3.3, 1, seconds).value
            XCTAssertTrue((0.0...10.0).contains(v), "值 \(v) 跑出了范围")
        }
    }

    func testLoopWrapsToTheStart() {
        let wrapped = step(9, 1, 1, mode: .loop)   // 9 + 2 = 11 → 回到 1
        XCTAssertEqual(wrapped.value, 1, accuracy: 1e-12)
        XCTAssertEqual(wrapped.direction, 1)
        XCTAssertEqual(step(2, -1, 1, mode: .loop).direction, 1, "循环永远向上")
        XCTAssertEqual(step(0, 1, 25, mode: .loop).value, 0, accuracy: 1e-9, "整整 5 圈回到原处")
    }

    func testClampsAnOutOfRangeStartAndIgnoresBadInput() {
        XCTAssertEqual(step(-5, 1, 0).value, 0, accuracy: 1e-12)
        XCTAssertEqual(step(99, 1, 0).value, 10, accuracy: 1e-12)
        XCTAssertEqual(step(5, 1, 1, range: 3...3).value, 5, "范围为空原样返回")
        XCTAssertEqual(step(5, 1, 1, sweep: 0).value, 5)
        XCTAssertEqual(step(5, 1, -1).value, 5)
        XCTAssertTrue(step(.nan, 1, 1).value.isNaN)
        // 负范围与小数。
        XCTAssertEqual(step(-1, 1, 1, range: -2...2, sweep: 4).value, 0, accuracy: 1e-12)
    }
}
