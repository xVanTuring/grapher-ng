import XCTest
import GrapherKit

final class ExprBenchmarkTests: XCTestCase {
    func testEvaluationThroughput() throws {
        let expr = try CompiledExpression(source: "sin(x)*x", context: ExpressionContext(variables: ["x"]))
        var values = [0.0]

        #if DEBUG
        let iterations = 100_000
        #else
        let iterations = 5_000_000
        #endif

        var accumulator = 0.0
        for i in 0..<(iterations / 10) {
            values[0] = Double(i) * 1e-6
            accumulator += expr.evaluate(values)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<iterations {
            values[0] = Double(i) * 1e-6
            accumulator += expr.evaluate(values)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start

        let perSecond = Double(iterations) * 1e9 / Double(elapsed)
        print(String(format: "[benchmark] sin(x)*x: %.1fM evaluations/s (%d evaluations, checksum %.6f)",
                     perSecond / 1e6, iterations, accumulator))

        #if !DEBUG
        XCTAssertGreaterThan(perSecond, 5_000_000)
        #endif
    }

    func testBatchThroughput() throws {
        let expr = try CompiledExpression(source: "sin(x)*x + cos(y)", context: ExpressionContext(variables: ["x", "y"]))
        let rows = 200_000
        var inputs = [Double](repeating: 0, count: rows * 2)
        for i in 0..<rows {
            inputs[i * 2] = Double(i) * 1e-5
            inputs[i * 2 + 1] = Double(i) * 2e-5
        }
        var output = [Double](repeating: 0, count: rows)

        let start = DispatchTime.now().uptimeNanoseconds
        inputs.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                expr.evaluateBatch(inputBuffer, count: rows, into: outputBuffer)
            }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let perSecond = Double(rows) * 1e9 / Double(elapsed)
        print(String(format: "[benchmark] batch sin(x)*x+cos(y): %.1fM rows/s", perSecond / 1e6))

        XCTAssertEqual(output[1], sin(1e-5) * 1e-5 + cos(2e-5), accuracy: 1e-15)
    }
}
