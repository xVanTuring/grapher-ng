final class ExprCompiler {
    private let tokens: [ExprToken]
    private let context: ExpressionContext
    private let variableSlots: [String: Int]

    private var index = 0
    private var pending: [ExprToken] = []

    private var ops: [ExprOp] = []
    private var operands: [Int32] = []
    private var constants: [Double] = []
    private var depth = 0
    private var maxDepth = 1
    private var maxSlot = -1

    init(tokens: [ExprToken], context: ExpressionContext) {
        self.tokens = tokens
        self.context = context
        var slots: [String: Int] = [:]
        for (slot, name) in context.variables.enumerated() where slots[name] == nil {
            slots[name] = slot
        }
        self.variableSlots = slots
    }

    func compile() throws -> ExprProgram {
        if case .end = peek().kind {
            throw ExpressionError(message: "表达式为空", column: 0, length: 1)
        }
        try parseTernary()

        let trailing = peek()
        switch trailing.kind {
        case .end:
            break
        case .op(.rightParen):
            throw ExpressionError(message: "多了一个右括号", column: trailing.column, length: 1)
        default:
            throw ExpressionError(
                message: "多余的内容 \"\(trailing.raw)\"",
                column: trailing.column,
                length: max(1, trailing.length)
            )
        }

        emit(.halt)
        if constants.isEmpty { constants.append(0) }
        return ExprProgram(
            ops: ops,
            operands: operands,
            constants: constants,
            stackDepth: max(1, maxDepth),
            requiredValues: maxSlot + 1
        )
    }

    // MARK: - tokens

    private func peek(_ offset: Int = 0) -> ExprToken {
        if offset < pending.count { return pending[offset] }
        let i = index + (offset - pending.count)
        return i < tokens.count ? tokens[i] : tokens[tokens.count - 1]
    }

    @discardableResult
    private func advance() -> ExprToken {
        if !pending.isEmpty { return pending.removeFirst() }
        let token = tokens[index]
        if index < tokens.count - 1 { index += 1 }
        return token
    }

    private func isLeftParen(_ token: ExprToken) -> Bool {
        if case .op(.leftParen) = token.kind { return true }
        return false
    }

    private func isRightParen(_ token: ExprToken) -> Bool {
        if case .op(.rightParen) = token.kind { return true }
        return false
    }

    private func isComma(_ token: ExprToken) -> Bool {
        if case .op(.comma) = token.kind { return true }
        return false
    }

    // MARK: - emission

    private func emit(_ op: ExprOp, _ operand: Int32 = 0) {
        ops.append(op)
        operands.append(operand)
    }

    private func pushDepth() {
        depth += 1
        if depth > maxDepth { maxDepth = depth }
    }

    private func emitConstant(_ value: Double) {
        constants.append(value)
        emit(.pushConstant, Int32(constants.count - 1))
        pushDepth()
    }

    private func emitLoad(slot: Int) {
        emit(.pushVariable, Int32(slot))
        pushDepth()
        if slot > maxSlot { maxSlot = slot }
    }

    private func emitBinary(_ op: ExprOp) {
        emit(op)
        depth -= 1
    }

    private func emitUnary(_ op: ExprOp) {
        emit(op)
    }

    private func emitCall(_ fn: ExprBuiltin) {
        emit(fn.callOp, fn.rawValue)
        depth -= fn.arity - 1
    }

    private func emitJump(_ op: ExprOp) -> Int {
        let at = ops.count
        emit(op, 0)
        return at
    }

    private func patch(_ at: Int, to target: Int) {
        operands[at] = Int32(target)
    }

    // MARK: - grammar

    private func parseTernary() throws {
        try parseOr()
        if case .op(.question) = peek().kind {
            advance()
            let jumpElse = emitJump(.jumpIfFalse)
            depth -= 1
            try parseTernary()
            guard case .op(.colon) = peek().kind else {
                let t = peek()
                throw ExpressionError(message: "三元运算符缺少 \":\"", column: t.column, length: max(1, t.length))
            }
            advance()
            let jumpEnd = emitJump(.jump)
            depth -= 1
            patch(jumpElse, to: ops.count)
            try parseTernary()
            patch(jumpEnd, to: ops.count)
        }
    }

    private func parseOr() throws {
        try parseAnd()
        while case .op(.orOr) = peek().kind {
            advance()
            emitUnary(.toBoolean)
            emitUnary(.duplicate)
            pushDepth()
            let jumpEnd = emitJump(.jumpIfTrue)
            depth -= 1
            emitUnary(.discard)
            depth -= 1
            try parseAnd()
            emitUnary(.toBoolean)
            patch(jumpEnd, to: ops.count)
        }
    }

    private func parseAnd() throws {
        try parseEquality()
        while case .op(.andAnd) = peek().kind {
            advance()
            emitUnary(.toBoolean)
            emitUnary(.duplicate)
            pushDepth()
            let jumpEnd = emitJump(.jumpIfFalse)
            depth -= 1
            emitUnary(.discard)
            depth -= 1
            try parseEquality()
            emitUnary(.toBoolean)
            patch(jumpEnd, to: ops.count)
        }
    }

    private func parseEquality() throws {
        try parseComparison()
        while true {
            switch peek().kind {
            case .op(.equalEqual):
                advance()
                try parseComparison()
                emitBinary(.equal)
            case .op(.notEqual):
                advance()
                try parseComparison()
                emitBinary(.notEqual)
            default:
                return
            }
        }
    }

    private func parseComparison() throws {
        try parseAdditive()
        while true {
            switch peek().kind {
            case .op(.less):
                advance()
                try parseAdditive()
                emitBinary(.less)
            case .op(.lessEqual):
                advance()
                try parseAdditive()
                emitBinary(.lessEqual)
            case .op(.greater):
                advance()
                try parseAdditive()
                emitBinary(.greater)
            case .op(.greaterEqual):
                advance()
                try parseAdditive()
                emitBinary(.greaterEqual)
            default:
                return
            }
        }
    }

    private func parseAdditive() throws {
        try parseMultiplicative()
        while true {
            switch peek().kind {
            case .op(.plus):
                advance()
                try parseMultiplicative()
                emitBinary(.add)
            case .op(.minus):
                advance()
                try parseMultiplicative()
                emitBinary(.subtract)
            default:
                return
            }
        }
    }

    private func parseMultiplicative() throws {
        try parseUnary()
        while true {
            switch peek().kind {
            case .op(.star):
                advance()
                try parseUnary()
                emitBinary(.multiply)
            case .op(.slash):
                advance()
                try parseUnary()
                emitBinary(.divide)
            case .op(.percent):
                advance()
                try parseUnary()
                emitBinary(.modulo)
            case .number, .identifier, .op(.leftParen):
                try parseUnary()
                emitBinary(.multiply)
            default:
                return
            }
        }
    }

    private func parseUnary() throws {
        switch peek().kind {
        case .op(.minus):
            advance()
            try parseUnary()
            emitUnary(.negate)
        case .op(.plus):
            advance()
            try parseUnary()
        case .op(.bang):
            advance()
            try parseUnary()
            emitUnary(.logicalNot)
        default:
            try parsePower()
        }
    }

    private func parsePower() throws {
        try parsePrimary()
        if case .op(.caret) = peek().kind {
            advance()
            try parseUnary()
            emitBinary(.power)
        }
    }

    private func parsePrimary() throws {
        let token = peek()
        switch token.kind {
        case .number(let value):
            advance()
            emitConstant(value)
        case .identifier(let name):
            if isLeftParen(peek(1)) {
                try parseCall(name: name, token: token)
            } else {
                advance()
                try resolveName(name, token: token)
            }
        case .op(.leftParen):
            advance()
            try parseTernary()
            guard isRightParen(peek()) else {
                throw ExpressionError(message: "缺少右括号", column: token.column, length: 1)
            }
            advance()
        case .end:
            throw ExpressionError(message: "表达式不完整", column: token.column, length: 1)
        default:
            throw ExpressionError(
                message: "意外的符号 \"\(token.raw)\"",
                column: token.column,
                length: max(1, token.length)
            )
        }
    }

    // MARK: - names

    private enum NamePart {
        case slot(Int)
        case value(Double)
    }

    private func resolveName(_ name: String, token: ExprToken) throws {
        if let value = ExprConstants.value(name) {
            emitConstant(value)
            return
        }
        if let slot = variableSlots[name] {
            emitLoad(slot: slot)
            return
        }
        if let value = context.parameters[name] {
            emitConstant(value)
            return
        }
        let chars = Array(name)
        if let parts = splitParts(chars) {
            for offset in 1..<chars.count {
                let single = String(chars[offset])
                pending.append(ExprToken(kind: .identifier(single), column: token.column + offset, length: 1, raw: single))
            }
            emitPart(parts[0])
            return
        }
        throw ExpressionError(message: "未知的符号 \"\(name)\"", column: token.column, length: token.length)
    }

    private func splitParts(_ chars: [Character]) -> [NamePart]? {
        guard chars.count > 1 else { return nil }
        var parts: [NamePart] = []
        parts.reserveCapacity(chars.count)
        for c in chars {
            let single = String(c)
            if let slot = variableSlots[single] {
                parts.append(.slot(slot))
            } else if let value = context.parameters[single] {
                parts.append(.value(value))
            } else {
                return nil
            }
        }
        return parts
    }

    private func emitPart(_ part: NamePart) {
        switch part {
        case .slot(let slot): emitLoad(slot: slot)
        case .value(let value): emitConstant(value)
        }
    }

    // MARK: - calls

    private func parseCall(name: String, token: ExprToken) throws {
        guard let fn = ExprBuiltin.byName[name] else {
            throw ExpressionError(message: "未知的函数 \"\(name)\"", column: token.column, length: token.length)
        }
        advance()
        let open = advance()

        var argc = 0
        if !isRightParen(peek()) {
            try parseTernary()
            argc = 1
            while isComma(peek()) {
                advance()
                try parseTernary()
                argc += 1
            }
        }
        guard isRightParen(peek()) else {
            throw ExpressionError(message: "缺少右括号", column: open.column, length: 1)
        }
        advance()

        guard argc == fn.arity else {
            throw ExpressionError(
                message: "函数 \(name) 需要 \(fn.arity) 个参数，给了 \(argc) 个",
                column: token.column,
                length: token.length
            )
        }
        emitCall(fn)
    }
}
