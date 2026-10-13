import Darwin

public struct ExpressionContext {
    public var variables: [String]
    public var parameters: [String: Double]

    public init(variables: [String], parameters: [String: Double] = [:]) {
        self.variables = variables
        self.parameters = parameters
    }
}

public struct ExpressionError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public let column: Int
    public let length: Int

    public var description: String {
        "第 \(column + 1) 列: \(message)"
    }

    public init(message: String, column: Int, length: Int) {
        self.message = message
        self.column = column
        self.length = max(1, length)
    }
}

public final class CompiledExpression: @unchecked Sendable {
    public let variables: [String]

    let program: ExprProgram

    public init(source: String, context: ExpressionContext) throws {
        let tokens = try ExprLexer.tokens(for: source)
        self.variables = context.variables
        self.program = try ExprCompiler(tokens: tokens, context: context).compile()
    }

    public func evaluate(_ values: [Double]) -> Double {
        if program.requiredValues > values.count { return Double.nan }
        let needed = program.requiredValues

        let ops = program.ops
        let operands = program.operands
        let constants = program.constants
        let depth = program.stackDepth

        return ops.withUnsafeBufferPointer { opsBuffer in
            operands.withUnsafeBufferPointer { operandBuffer in
                constants.withUnsafeBufferPointer { constantBuffer in
                    withUnsafeTemporaryAllocation(of: Double.self, capacity: depth) { stack in
                        let base = stack.baseAddress!
                        base.initialize(repeating: 0, count: depth)
                        defer { base.deinitialize(count: depth) }
                        if needed == 0 {
                            var placeholder = 0.0
                            return withUnsafePointer(to: &placeholder) { pointer in
                                exprRun(
                                    ops: opsBuffer.baseAddress!,
                                    operands: operandBuffer.baseAddress!,
                                    constants: constantBuffer.baseAddress!,
                                    values: pointer,
                                    stack: base
                                )
                            }
                        }
                        return values.withUnsafeBufferPointer { valueBuffer in
                            exprRun(
                                ops: opsBuffer.baseAddress!,
                                operands: operandBuffer.baseAddress!,
                                constants: constantBuffer.baseAddress!,
                                values: valueBuffer.baseAddress!,
                                stack: base
                            )
                        }
                    }
                }
            }
        }
    }

    public func evaluate<T: MathScalar>(_ values: [T]) -> T {
        if program.requiredValues > values.count { return T.fromDouble(.nan) }
        let needed = program.requiredValues

        let ops = program.ops
        let operands = program.operands
        let constants = program.constants
        let depth = program.stackDepth

        return ops.withUnsafeBufferPointer { opsBuffer in
            operands.withUnsafeBufferPointer { operandBuffer in
                constants.withUnsafeBufferPointer { constantBuffer in
                    withUnsafeTemporaryAllocation(of: T.self, capacity: depth) { stack in
                        let base = stack.baseAddress!
                        base.initialize(repeating: .zero, count: depth)
                        defer { base.deinitialize(count: depth) }
                        if needed == 0 {
                            var placeholder = T.zero
                            return withUnsafePointer(to: &placeholder) { pointer in
                                exprRun(
                                    ops: opsBuffer.baseAddress!,
                                    operands: operandBuffer.baseAddress!,
                                    constants: constantBuffer.baseAddress!,
                                    values: pointer,
                                    stack: base
                                )
                            }
                        }
                        return values.withUnsafeBufferPointer { valueBuffer in
                            exprRun(
                                ops: opsBuffer.baseAddress!,
                                operands: operandBuffer.baseAddress!,
                                constants: constantBuffer.baseAddress!,
                                values: valueBuffer.baseAddress!,
                                stack: base
                            )
                        }
                    }
                }
            }
        }
    }

    public func evaluateBatch(_ inputs: UnsafeBufferPointer<Double>, count: Int, into output: UnsafeMutableBufferPointer<Double>) {
        let rowStride = variables.count
        let requested = max(0, count)
        let available = rowStride > 0 ? inputs.count / rowStride : requested
        let rows = min(min(requested, available), output.count)
        guard rows > 0, let inputBase = inputs.baseAddress, let outputBase = output.baseAddress else { return }

        let ops = program.ops
        let operands = program.operands
        let constants = program.constants
        let depth = program.stackDepth

        ops.withUnsafeBufferPointer { opsBuffer in
            operands.withUnsafeBufferPointer { operandBuffer in
                constants.withUnsafeBufferPointer { constantBuffer in
                    withUnsafeTemporaryAllocation(of: Double.self, capacity: depth) { stack in
                        let base = stack.baseAddress!
                        base.initialize(repeating: 0, count: depth)
                        defer { base.deinitialize(count: depth) }
                        for row in 0..<rows {
                            outputBase[row] = exprRun(
                                ops: opsBuffer.baseAddress!,
                                operands: operandBuffer.baseAddress!,
                                constants: constantBuffer.baseAddress!,
                                values: inputBase + row * rowStride,
                                stack: base
                            )
                        }
                    }
                }
            }
        }
    }
}
