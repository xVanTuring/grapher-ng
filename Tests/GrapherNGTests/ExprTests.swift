import XCTest
import GrapherKit

final class ExprTests: XCTestCase {

    private func compile(_ source: String, _ variables: [String] = ["x", "y"], parameters: [String: Double] = [:]) throws -> CompiledExpression {
        try CompiledExpression(source: source, context: ExpressionContext(variables: variables, parameters: parameters))
    }

    private func value(_ source: String, _ inputs: [Double] = [], variables: [String] = ["x", "y"], parameters: [String: Double] = [:]) throws -> Double {
        try compile(source, variables, parameters: parameters).evaluate(inputs)
    }

    private func error(_ source: String, variables: [String] = ["x", "y"], parameters: [String: Double] = [:]) -> ExpressionError? {
        do {
            _ = try compile(source, variables, parameters: parameters)
            return nil
        } catch let error as ExpressionError {
            return error
        } catch {
            return nil
        }
    }

    private func assertError(_ source: String, _ message: String, column: Int, length: Int, variables: [String] = ["x", "y"], parameters: [String: Double] = [:], line: UInt = #line) {
        guard let err = error(source, variables: variables, parameters: parameters) else {
            XCTFail("expected error for \"\(source)\"", line: line)
            return
        }
        XCTAssertEqual(err.message, message, "message for \"\(source)\"", line: line)
        XCTAssertEqual(err.column, column, "column for \"\(source)\"", line: line)
        XCTAssertEqual(err.length, length, "length for \"\(source)\"", line: line)
    }

    // MARK: - 1. precedence and associativity

    func testPrecedenceAndAssociativity() throws {
        XCTAssertEqual(try value("1+2*3"), 7, accuracy: 1e-12)
        XCTAssertEqual(try value("(1+2)*3"), 9, accuracy: 1e-12)
        XCTAssertEqual(try value("2^3^2"), 512, accuracy: 1e-12)
        XCTAssertEqual(try value("2^2^3"), 256, accuracy: 1e-12)
        XCTAssertEqual(try value("10-3-2"), 5, accuracy: 1e-12)
        XCTAssertEqual(try value("10/2/5"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("-x^2", [3]), -9, accuracy: 1e-12)
        XCTAssertEqual(try value("-2^2"), -4, accuracy: 1e-12)
        XCTAssertEqual(try value("(-2)^2"), 4, accuracy: 1e-12)
        XCTAssertEqual(try value("2^-3"), 0.125, accuracy: 1e-12)
        XCTAssertEqual(try value("-2^-3"), -0.125, accuracy: 1e-12)
        XCTAssertEqual(try value("2*2^3"), 16, accuracy: 1e-12)
        XCTAssertEqual(try value("--x", [5]), 5, accuracy: 1e-12)
        XCTAssertEqual(try value("+-x", [5]), -5, accuracy: 1e-12)
        XCTAssertEqual(try value("1+2 < 4"), 1, accuracy: 1e-12)
    }

    // MARK: - 2. implicit multiplication

    func testImplicitMultiplication() throws {
        XCTAssertEqual(try value("2x", [5]), 10, accuracy: 1e-12)
        XCTAssertEqual(try value("3sin(x)", [Double.pi / 2]), 3, accuracy: 1e-12)
        XCTAssertEqual(try value("2(x+1)", [2]), 6, accuracy: 1e-12)
        XCTAssertEqual(try value("(x+1)(x-1)", [3]), 8, accuracy: 1e-12)
        XCTAssertEqual(try value("2x^2", [3]), 18, accuracy: 1e-12)
        XCTAssertEqual(try value("xy", [2, 3]), 6, accuracy: 1e-12)
        XCTAssertEqual(try value("2xy", [2, 3]), 12, accuracy: 1e-12)
        XCTAssertEqual(try value("1/2x", [4]), 2, accuracy: 1e-12)
        XCTAssertEqual(try value("x y", [2, 3]), 6, accuracy: 1e-12)
        XCTAssertEqual(try value("2 (x+1)", [2]), 6, accuracy: 1e-12)
        XCTAssertEqual(try value("xy^2", [2, 3]), 18, accuracy: 1e-12)
        XCTAssertEqual(try value("(x)(y)", [2, 3]), 6, accuracy: 1e-12)
        XCTAssertEqual(try value("2sin(x)cos(x)", [Double.pi / 4]), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("2 - 3"), -1, accuracy: 1e-12)
        XCTAssertEqual(try value("x < y", [2, 3]), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("x - 3", [2]), -1, accuracy: 1e-12)
        XCTAssertEqual(try value("x 2", [3]), 6, accuracy: 1e-12)
    }

    // MARK: - 3. identifier splitting

    func testIdentifierSplitting() throws {
        XCTAssertEqual(try value("xy", [2, 3]), 6, accuracy: 1e-12)
        XCTAssertEqual(try value("2xy", [2, 3]), 12, accuracy: 1e-12)
        XCTAssertEqual(try value("theta", [0.5], variables: ["theta"]), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try value("ax", [4], variables: ["x"], parameters: ["a": 2]), 8, accuracy: 1e-12)
        XCTAssertEqual(try value("abx", [4], variables: ["x"], parameters: ["a": 2, "b": 3]), 24, accuracy: 1e-12)

        // 精确匹配优先于逐字符拆分
        XCTAssertEqual(try value("xy", [7, 1, 2], variables: ["xy", "x", "y"]), 7, accuracy: 1e-12)
        // 变量优先于参数
        XCTAssertEqual(try value("a", [7], variables: ["a"], parameters: ["a": 5]), 7, accuracy: 1e-12)
        // 常量优先于变量
        XCTAssertEqual(try value("e", [1], variables: ["e"]), Darwin.M_E, accuracy: 1e-12)

        assertError("sinx", "未知的符号 \"sinx\"", column: 0, length: 4, variables: ["x"])
        assertError("x2", "未知的符号 \"x2\"", column: 0, length: 2, variables: ["x"])
        assertError("1 + zz", "未知的符号 \"zz\"", column: 4, length: 2, variables: ["x"])
    }

    // MARK: - 4. constants

    func testConstants() throws {
        XCTAssertEqual(try value("pi"), Double.pi, accuracy: 1e-12)
        XCTAssertEqual(try value("\u{3C0}"), Double.pi, accuracy: 1e-12)
        XCTAssertEqual(try value("e"), Darwin.M_E, accuracy: 1e-12)
        XCTAssertEqual(try value("tau"), 2 * Double.pi, accuracy: 1e-12)
        XCTAssertEqual(try value("\u{3C4}"), 2 * Double.pi, accuracy: 1e-12)
        XCTAssertEqual(try value("2\u{3C0}"), 2 * Double.pi, accuracy: 1e-12)
        XCTAssertEqual(try value("2e3"), 2000, accuracy: 1e-12)
        XCTAssertEqual(try value("2e"), 2 * Darwin.M_E, accuracy: 1e-12)
        XCTAssertEqual(try value("1.2e-3"), 0.0012, accuracy: 1e-15)
        XCTAssertEqual(try value(".5"), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try value("1e3x", [2]), 2000, accuracy: 1e-12)
        XCTAssertEqual(try value("pi/2"), Double.pi / 2, accuracy: 1e-12)
    }

    // MARK: - 5. builtins

    func testUnaryBuiltins() throws {
        let p = Double.pi
        XCTAssertEqual(try value("sin(pi/2)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("cos(0)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("tan(pi/4)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("cot(pi/4)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("sec(0)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("csc(pi/2)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("asin(1)"), p / 2, accuracy: 1e-12)
        XCTAssertEqual(try value("acos(1)"), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("atan(1)"), p / 4, accuracy: 1e-12)
        XCTAssertEqual(try value("sinh(1)"), 1.1752011936438014, accuracy: 1e-12)
        XCTAssertEqual(try value("cosh(1)"), 1.5430806348152437, accuracy: 1e-12)
        XCTAssertEqual(try value("tanh(1)"), 0.7615941559557649, accuracy: 1e-12)
        XCTAssertEqual(try value("asinh(1)"), 0.881373587019543, accuracy: 1e-12)
        XCTAssertEqual(try value("acosh(2)"), 1.3169578969248166, accuracy: 1e-12)
        XCTAssertEqual(try value("atanh(0.5)"), 0.5493061443340549, accuracy: 1e-12)
        XCTAssertEqual(try value("exp(1)"), Darwin.M_E, accuracy: 1e-12)
        XCTAssertEqual(try value("ln(e)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("log(e)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("log2(8)"), 3, accuracy: 1e-12)
        XCTAssertEqual(try value("log10(1000)"), 3, accuracy: 1e-12)
        XCTAssertEqual(try value("sqrt(16)"), 4, accuracy: 1e-12)
        XCTAssertEqual(try value("cbrt(27)"), 3, accuracy: 1e-12)
        XCTAssertEqual(try value("abs(-3.5)"), 3.5, accuracy: 1e-12)
        XCTAssertEqual(try value("sign(-2)"), -1, accuracy: 1e-12)
        XCTAssertEqual(try value("sign(0)"), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("sign(3)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("floor(1.7)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("floor(-1.2)"), -2, accuracy: 1e-12)
        XCTAssertEqual(try value("ceil(1.2)"), 2, accuracy: 1e-12)
        XCTAssertEqual(try value("round(1.5)"), 2, accuracy: 1e-12)
        XCTAssertEqual(try value("round(-1.5)"), -2, accuracy: 1e-12)
        XCTAssertEqual(try value("trunc(-1.7)"), -1, accuracy: 1e-12)
        XCTAssertEqual(try value("erf(1)"), 0.8427007929497149, accuracy: 1e-12)
        XCTAssertEqual(try value("gamma(5)"), 24, accuracy: 1e-9)
        XCTAssertEqual(try value("gamma(0.5)"), sqrt(Double.pi), accuracy: 1e-9)
        XCTAssertEqual(try value("step(-1)"), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("step(0)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("step(1)"), 1, accuracy: 1e-12)
        XCTAssertTrue(try value("sign(sqrt(-1))").isNaN)
    }

    func testBinaryAndTernaryBuiltins() throws {
        XCTAssertEqual(try value("atan2(1, 1)"), Double.pi / 4, accuracy: 1e-12)
        XCTAssertEqual(try value("atan2(1, 0)"), Double.pi / 2, accuracy: 1e-12)
        XCTAssertEqual(try value("mod(7, 3)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("7 % 3"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("pow(2, 10)"), 1024, accuracy: 1e-12)
        XCTAssertEqual(try value("hypot(3, 4)"), 5, accuracy: 1e-12)
        XCTAssertEqual(try value("min(2, 5)"), 2, accuracy: 1e-12)
        XCTAssertEqual(try value("max(2, 5)"), 5, accuracy: 1e-12)
        XCTAssertEqual(try value("clamp(5, 0, 1)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("clamp(-5, 0, 1)"), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("clamp(0.5, 0, 1)"), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try value("smoothstep(0, 1, 0.5)"), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try value("smoothstep(0, 1, 2)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("smoothstep(0, 1, -1)"), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("smoothstep(0, 1, 0.25)"), 0.15625, accuracy: 1e-12)
        XCTAssertEqual(try value("if(1, 2, 3)"), 2, accuracy: 1e-12)
        XCTAssertEqual(try value("if(0, 2, 3)"), 3, accuracy: 1e-12)
        XCTAssertEqual(try value("if(2>1, 2, 3)"), 2, accuracy: 1e-12)
    }

    // MARK: - 6. comparison, logic, ternary

    func testComparisonAndLogic() throws {
        XCTAssertEqual(try value("1 < 2"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("2 <= 2"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("3 > 4"), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("3 >= 4"), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("1 == 1"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("1 != 1"), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("1 != 2"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("1 < 2 && 2 < 3"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("1 < 2 && 3 < 2"), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("0 || 1"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("0 || 0"), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("!0"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("!5"), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("!x", [0]), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("!(x > 0)", [-1]), 1, accuracy: 1e-12)

        // 短路：x < 0 时 log(x) 是 NaN，非短路会污染结果
        XCTAssertEqual(try value("x>0 && log(x)>1", [-1]), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("x>0 && log(x)>1", [10]), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("x<0 || log(x)>1", [-1]), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("x<0 || log(x)>1", [10]), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("x<0 || sqrt(x)>1", [1]), 0, accuracy: 1e-12)

        // NaN 归一化
        XCTAssertEqual(try value("sqrt(-1) != 0"), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("sqrt(-1) == 0"), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("sqrt(-1) > 0"), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("sqrt(-1) < 0"), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("sqrt(-1) <= 0"), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("sqrt(-1) >= 0"), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("!sqrt(-1)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try value("sqrt(-1) && 1"), 0, accuracy: 1e-12)

        // 三元
        XCTAssertEqual(try value("1 ? 2 : 3"), 2, accuracy: 1e-12)
        XCTAssertEqual(try value("0 ? 2 : 3"), 3, accuracy: 1e-12)
        XCTAssertEqual(try value("x > 0 ? x : -x", [-5]), 5, accuracy: 1e-12)
        XCTAssertEqual(try value("1 ? 2 : 3 ? 4 : 5"), 2, accuracy: 1e-12)
        XCTAssertEqual(try value("0 ? 2 : 0 ? 4 : 5"), 5, accuracy: 1e-12)
        XCTAssertEqual(try value("sqrt(-1) ? 1 : 2"), 2, accuracy: 1e-12)

        // 三元出现在运算数位置上
        XCTAssertEqual(try value("(1 ? 2 : 3) + (0 ? 4 : 5)"), 7, accuracy: 1e-12)
        XCTAssertEqual(try value("(x > 0 ? 1 : 2) + (y > 0 ? 10 : 20)", [1, -1]), 21, accuracy: 1e-12)
        XCTAssertEqual(try value("1 + (0 ? 2 : 3)"), 4, accuracy: 1e-12)
        XCTAssertEqual(try value("(1 ? 2 : 3) * 2"), 4, accuracy: 1e-12)
        XCTAssertEqual(try value("2 * (0 ? 2 : 3)"), 6, accuracy: 1e-12)
        XCTAssertEqual(try value("-(1 ? 2 : 3)"), -2, accuracy: 1e-12)
        XCTAssertEqual(try value("sin((1 ? 0 : 1) * pi)"), 0, accuracy: 1e-12)
        XCTAssertEqual(try value("1 ? 2 : 3 ? 4 : 5"), 2, accuracy: 1e-12)
        XCTAssertEqual(try value("(1 && 1 ? 2 : 3) + 100"), 102, accuracy: 1e-12)
    }

    // MARK: - 7. error positions

    func testErrorPositions() throws {
        assertError("", "表达式为空", column: 0, length: 1)
        assertError("   ", "表达式为空", column: 0, length: 1)
        assertError("sinx", "未知的符号 \"sinx\"", column: 0, length: 4, variables: ["x"])
        assertError("x2", "未知的符号 \"x2\"", column: 0, length: 2, variables: ["x"])
        assertError("(x+1", "缺少右括号", column: 0, length: 1)
        assertError("sin(x", "缺少右括号", column: 3, length: 1)
        assertError("x+1)", "多了一个右括号", column: 3, length: 1)
        assertError("x = 1", "公式里不能出现单个 =，请把式子写成 F(x,y) 的形式", column: 2, length: 1)
        assertError("F(x)", "未知的函数 \"F\"", column: 0, length: 1)
        assertError("foo(x)", "未知的函数 \"foo\"", column: 0, length: 3)
        assertError("sin(1, 2)", "函数 sin 需要 1 个参数，给了 2 个", column: 0, length: 3)
        assertError("  1 + sin(1, 2)", "函数 sin 需要 1 个参数，给了 2 个", column: 6, length: 3)
        assertError("2 + foo(x)", "未知的函数 \"foo\"", column: 4, length: 3)
        assertError("sin()", "函数 sin 需要 1 个参数，给了 0 个", column: 0, length: 3)
        assertError("clamp(1, 2)", "函数 clamp 需要 3 个参数，给了 2 个", column: 0, length: 5)
        assertError("1 +", "表达式不完整", column: 3, length: 1)
        assertError("x + y , 1", "多余的内容 \",\"", column: 6, length: 1)
        assertError("x @ y", "无法识别的字符 \"@\"", column: 2, length: 1)
        assertError("2**3", "意外的符号 \"*\"", column: 2, length: 1)
        assertError("1 ? 2", "三元运算符缺少 \":\"", column: 5, length: 1)

        let err = error("sinx", variables: ["x"])
        XCTAssertEqual(err?.description, "第 1 列: 未知的符号 \"sinx\"")
    }

    func testErrorColumnIsCharacterOffset() throws {
        // π 与 θ 都是多字节字符，column 必须按字符数计算
        assertError("π + \u{3B8} + z", "未知的符号 \"z\"", column: 8, length: 1, variables: ["x", "\u{3B8}"])
        let ok = try compile("2\u{3C0} + 1", ["x"])
        XCTAssertEqual(ok.evaluate([]), 2 * Double.pi + 1, accuracy: 1e-12)
    }

    // MARK: - 8. variables and parameters

    func testVariablesAndParameters() throws {
        XCTAssertEqual(try value("x - y", [3, 1]), 2, accuracy: 1e-12)
        XCTAssertEqual(try value("y - x", [3, 1]), -2, accuracy: 1e-12)
        XCTAssertEqual(try value("x^2 + y^2", [3, 4]), 25, accuracy: 1e-12)
        XCTAssertEqual(try value("a*x + b", [1], variables: ["x"], parameters: ["a": 2, "b": 3]), 5, accuracy: 1e-12)
        XCTAssertEqual(try value("ax + b", [4], variables: ["x"], parameters: ["a": 2, "b": 3]), 11, accuracy: 1e-12)
        XCTAssertEqual(try value("k", [], variables: [], parameters: ["k": 2.5]), 2.5, accuracy: 1e-12)

        let constantExpression = try compile("1 + 1", [])
        XCTAssertEqual(constantExpression.evaluate([]), 2, accuracy: 1e-12)
        XCTAssertTrue(try compile("x", ["x"]).evaluate([]).isNaN)

        let expr = try compile("x + y", ["x", "y"])
        XCTAssertEqual(expr.variables, ["x", "y"])
    }

    // MARK: - 9. batch and generic evaluation

    func testEvaluateBatch() throws {
        let expr = try compile("x*y + 1", ["x", "y"])
        let inputs: [Double] = [1, 2, 3, 4, 5, 6]
        var output = [Double](repeating: 0, count: 3)
        inputs.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                expr.evaluateBatch(inputBuffer, count: 3, into: outputBuffer)
            }
        }
        XCTAssertEqual(output, [3, 13, 31])

        // count 超过输入行数 / 输出容量时安全截断
        var small = [Double](repeating: -1, count: 2)
        inputs.withUnsafeBufferPointer { inputBuffer in
            small.withUnsafeMutableBufferPointer { outputBuffer in
                expr.evaluateBatch(inputBuffer, count: 99, into: outputBuffer)
            }
        }
        XCTAssertEqual(small, [3, 13])
    }

    func testGenericEvaluation() throws {
        let expr = try compile("sin(x)*x", ["x"])
        func runGeneric<T: MathScalar>(_ type: T.Type, _ x: Double) -> T {
            expr.evaluate([T.fromDouble(x)])
        }
        let generic: Double = runGeneric(Double.self, 0.5)
        XCTAssertEqual(generic, sin(0.5) * 0.5, accuracy: 1e-12)
        XCTAssertEqual(expr.evaluate([0.5]), sin(0.5) * 0.5, accuracy: 1e-12)
    }

    // MARK: - 10. thread safety

    func testConcurrentEvaluation() throws {
        let expr = try compile("sin(x)*x + log(x) + if(x > 0, 1, 0)", ["x"])
        let iterations = 10_000
        let results = UnsafeMutablePointer<Double>.allocate(capacity: iterations)
        defer { results.deallocate() }

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let x = 0.5 + Double(i) * 0.001
            results[i] = expr.evaluate([x])
        }

        for i in 0..<iterations {
            let x = 0.5 + Double(i) * 0.001
            let expected = sin(x) * x + log(x) + 1
            XCTAssertEqual(results[i], expected, accuracy: 1e-12)
        }
    }

    func testDeepNesting() throws {
        var source = "x"
        for _ in 0..<200 { source = "(" + source + "+1)" }
        XCTAssertEqual(try value(source, [0]), 200, accuracy: 1e-9)

        let logical = "(x > 0 ? 1 : 2) + (y > 0 ? 10 : 20) + (x > y ? 100 : 200)"
        XCTAssertEqual(try value(logical, [1, -1]), 1 + 20 + 100, accuracy: 1e-12)
        XCTAssertEqual(try value(logical, [-1, 1]), 2 + 10 + 200, accuracy: 1e-12)
    }
}
