import XCTest
@testable import GrapherKit

private struct ExprFuzzGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

private indirect enum ExprFuzzNode {
    case variable(Int)
    case constant(Double)
    case negate(ExprFuzzNode)
    case logicalNot(ExprFuzzNode)
    case binary(String, ExprFuzzNode, ExprFuzzNode)
    case conditional(ExprFuzzNode, ExprFuzzNode, ExprFuzzNode)
    case call(String, ExprFuzzNode)
}

final class ExprFuzzTests: XCTestCase {

    private static let binaryOperators = ["+", "-", "*", "/", "^", "<", "<=", ">", ">=", "==", "!=", "&&", "||"]
    private static let unaryFunctions = ["sin", "cos", "abs", "floor", "sqrt", "exp"]

    private func makeNode(_ rng: inout ExprFuzzGenerator, depth: Int) -> ExprFuzzNode {
        if depth <= 0 {
            switch Int.random(in: 0..<4, using: &rng) {
            case 0: return .variable(0)
            case 1: return .variable(1)
            case 2: return .constant(Double(Int.random(in: -3...3, using: &rng)))
            default: return .constant(Double(Int.random(in: 1...4, using: &rng)))
            }
        }
        switch Int.random(in: 0..<12, using: &rng) {
        case 0:
            return .negate(makeNode(&rng, depth: depth - 1))
        case 1:
            return .logicalNot(makeNode(&rng, depth: depth - 1))
        case 2:
            return .conditional(
                makeNode(&rng, depth: depth - 1),
                makeNode(&rng, depth: depth - 1),
                makeNode(&rng, depth: depth - 1)
            )
        case 3, 4, 5, 6:
            let op = Self.binaryOperators[Int.random(in: 0..<Self.binaryOperators.count, using: &rng)]
            return .binary(op, makeNode(&rng, depth: depth - 1), makeNode(&rng, depth: depth - 1))
        default:
            let name = Self.unaryFunctions[Int.random(in: 0..<Self.unaryFunctions.count, using: &rng)]
            return .call(name, makeNode(&rng, depth: depth - 1))
        }
    }

    private func text(_ node: ExprFuzzNode) -> String {
        switch node {
        case .variable(let slot):
            return slot == 0 ? "x" : "y"
        case .constant(let value):
            return "(\(value))"
        case .negate(let inner):
            return "(-\(text(inner)))"
        case .logicalNot(let inner):
            return "(!\(text(inner)))"
        case .binary(let op, let lhs, let rhs):
            return "(\(text(lhs)) \(op) \(text(rhs)))"
        case .conditional(let condition, let then, let otherwise):
            return "(\(text(condition)) ? \(text(then)) : \(text(otherwise)))"
        case .call(let name, let argument):
            return "(\(name)(\(text(argument))))"
        }
    }

    private func truthy(_ value: Double) -> Bool {
        value == value && value != 0
    }

    private func number(_ flag: Bool) -> Double {
        flag ? 1 : 0
    }

    private func reference(_ node: ExprFuzzNode, _ x: Double, _ y: Double) -> Double {
        switch node {
        case .variable(let slot):
            return slot == 0 ? x : y
        case .constant(let value):
            return value
        case .negate(let inner):
            return -reference(inner, x, y)
        case .logicalNot(let inner):
            return number(!truthy(reference(inner, x, y)))
        case .conditional(let condition, let then, let otherwise):
            return truthy(reference(condition, x, y)) ? reference(then, x, y) : reference(otherwise, x, y)
        case .call(let name, let argument):
            let value = reference(argument, x, y)
            switch name {
            case "sin": return sin(value)
            case "cos": return cos(value)
            case "abs": return abs(value)
            case "floor": return floor(value)
            case "sqrt": return sqrt(value)
            default: return exp(value)
            }
        case .binary(let op, let lhs, let rhs):
            let left = reference(lhs, x, y)
            if op == "&&" { return truthy(left) ? number(truthy(reference(rhs, x, y))) : 0 }
            if op == "||" { return truthy(left) ? 1 : number(truthy(reference(rhs, x, y))) }
            let right = reference(rhs, x, y)
            let hasNaN = left != left || right != right
            switch op {
            case "+": return left + right
            case "-": return left - right
            case "*": return left * right
            case "/": return left / right
            case "^": return pow(left, right)
            case "<": return hasNaN ? 0 : number(left < right)
            case "<=": return hasNaN ? 0 : number(left <= right)
            case ">": return hasNaN ? 0 : number(left > right)
            case ">=": return hasNaN ? 0 : number(left >= right)
            case "==": return number(left == right)
            case "!=": return hasNaN ? 0 : number(left != right)
            default: return 0
            }
        }
    }

    private let samples: [(Double, Double)] = [(0.5, -1.25), (-2.0, 3.0), (1.0, 1.0), (0.0, 0.0), (-0.5, 2.5)]

    func testRandomExpressionsMatchReference() throws {
        var rng = ExprFuzzGenerator(seed: 0x5DEECE66D)
        for _ in 0..<1500 {
            let node = makeNode(&rng, depth: 3)
            let source = text(node)
            let expression: CompiledExpression
            do {
                expression = try CompiledExpression(source: source, context: ExpressionContext(variables: ["x", "y"]))
            } catch let error as ExpressionError {
                XCTFail("无法编译 \(source): \(error)")
                return
            }
            for (x, y) in samples {
                let got = expression.evaluate([x, y])
                let want = reference(node, x, y)
                if want.isNaN && got.isNaN { continue }
                if got != want {
                    XCTFail("\(source) 在 x=\(x), y=\(y) 处得到 \(got)，期望 \(want)")
                    return
                }
            }
        }
    }

    /// 用带边界检查的解释器重放字节码，确认静态算出的栈深度足够、求值不会越界。
    func testStackDepthIsSufficient() throws {
        var rng = ExprFuzzGenerator(seed: 0x1234567)
        var deepest = 0
        for _ in 0..<1500 {
            let node = makeNode(&rng, depth: 3)
            let source = text(node)
            let expression = try CompiledExpression(source: source, context: ExpressionContext(variables: ["x", "y"]))
            let limit = expression.program.stackDepth
            let constants = expression.program.constants
            var stack = [Double](repeating: 0, count: limit)
            var sp = 0
            var pc = 0
            var insideBounds = true

            func push(_ value: Double) {
                if sp < limit {
                    stack[sp] = value
                    sp += 1
                } else {
                    insideBounds = false
                }
            }

            while insideBounds && pc < expression.program.ops.count {
                let op = expression.program.ops[pc]
                let operand = Int(expression.program.operands[pc])
                switch op {
                case .pushConstant:
                    push(constants[operand])
                case .pushVariable:
                    push(operand == 0 ? 1.0 : 2.0)
                case .duplicate:
                    push(stack[sp - 1])
                case .discard:
                    sp -= 1
                case .jump:
                    pc = operand - 1
                case .jumpIfFalse:
                    sp -= 1
                    if !truthy(stack[sp]) { pc = operand - 1 }
                case .jumpIfTrue:
                    sp -= 1
                    if truthy(stack[sp]) { pc = operand - 1 }
                case .halt:
                    break
                case .callTernary:
                    sp -= 2
                case .callBinary, .add, .subtract, .multiply, .divide, .modulo, .power,
                     .less, .lessEqual, .greater, .greaterEqual, .equal, .notEqual:
                    sp -= 1
                default:
                    break
                }
                if sp > limit { insideBounds = false; deepest = max(deepest, sp); break }
                deepest = max(deepest, sp)
                pc += 1
            }
            XCTAssertTrue(insideBounds, "\(source) 求值时求值栈越界（静态栈深 \(limit)）")
        }
        XCTAssertLessThanOrEqual(deepest, 8)
    }
}
