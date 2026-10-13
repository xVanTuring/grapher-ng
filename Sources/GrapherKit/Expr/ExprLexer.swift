import Darwin
import Foundation

enum ExprOperator: UInt8 {
    case plus, minus, star, slash, percent, caret
    case less, greater, lessEqual, greaterEqual, equalEqual, notEqual
    case andAnd, orOr, bang, question, colon, comma, leftParen, rightParen
}

enum ExprTokenKind {
    case number(Double)
    case identifier(String)
    case op(ExprOperator)
    case end
}

struct ExprToken {
    let kind: ExprTokenKind
    let column: Int
    let length: Int
    let raw: String
}

enum ExprLexer {
    static func tokens(for source: String) throws -> [ExprToken] {
        var scanner = Scanner(source: source)
        return try scanner.run()
    }

    private struct Scanner {
        private let chars: [Character]
        private var pos = 0

        init(source: String) {
            chars = Array(source)
        }

        mutating func run() throws -> [ExprToken] {
            var result: [ExprToken] = []
            let count = chars.count
            while pos < count {
                let c = chars[pos]
                if c.isWhitespace {
                    pos += 1
                    continue
                }
                let start = pos
                if isDigit(c) || (c == "." && pos + 1 < count && isDigit(chars[pos + 1])) {
                    result.append(try scanNumber(start: start))
                } else if isIdentifierStart(c) {
                    result.append(scanIdentifier(start: start))
                } else {
                    result.append(try scanOperator(start: start))
                }
            }
            result.append(ExprToken(kind: .end, column: count, length: 1, raw: ""))
            return result
        }

        private mutating func scanNumber(start: Int) throws -> ExprToken {
            let count = chars.count
            var p = start
            while p < count && isDigit(chars[p]) { p += 1 }
            if p < count && chars[p] == "." {
                p += 1
                while p < count && isDigit(chars[p]) { p += 1 }
            }
            if p < count && (chars[p] == "e" || chars[p] == "E") {
                var q = p + 1
                if q < count && (chars[q] == "+" || chars[q] == "-") { q += 1 }
                if q < count && isDigit(chars[q]) {
                    q += 1
                    while q < count && isDigit(chars[q]) { q += 1 }
                    p = q
                }
            }
            let raw = String(chars[start..<p])
            pos = p
            var literal = raw
            if literal.hasSuffix(".") { literal += "0" }
            guard let value = Double(literal) else {
                throw ExpressionError(message: String(format: L("Unrecognized number \"%@\""), raw), column: start, length: p - start)
            }
            return ExprToken(kind: .number(value), column: start, length: p - start, raw: raw)
        }

        private mutating func scanIdentifier(start: Int) -> ExprToken {
            let count = chars.count
            var p = start
            while p < count && isIdentifierPart(chars[p]) { p += 1 }
            let raw = String(chars[start..<p])
            pos = p
            return ExprToken(kind: .identifier(raw), column: start, length: p - start, raw: raw)
        }

        private mutating func scanOperator(start: Int) throws -> ExprToken {
            let c = chars[start]
            if start + 1 < chars.count, let pair = Self.doubleOperators[String(chars[start..<(start + 2)])] {
                pos = start + 2
                return ExprToken(kind: .op(pair), column: start, length: 2, raw: String(chars[start..<(start + 2)]))
            }
            if c == "=" {
                throw ExpressionError(
                    message: L("A single = is not allowed; write the formula as F(x,y)"),
                    column: start,
                    length: 1
                )
            }
            guard let op = Self.singleOperators[c] else {
                throw ExpressionError(message: String(format: L("Unrecognized character \"%@\""), String(c)), column: start, length: 1)
            }
            pos = start + 1
            return ExprToken(kind: .op(op), column: start, length: 1, raw: String(c))
        }

        private static let doubleOperators: [String: ExprOperator] = [
            "<=": .lessEqual, ">=": .greaterEqual, "==": .equalEqual,
            "!=": .notEqual, "&&": .andAnd, "||": .orOr,
        ]

        private static let singleOperators: [Character: ExprOperator] = [
            "+": .plus, "-": .minus, "*": .star, "/": .slash, "%": .percent, "^": .caret,
            "<": .less, ">": .greater, "!": .bang, "?": .question, ":": .colon,
            ",": .comma, "(": .leftParen, ")": .rightParen,
        ]

        private func isDigit(_ c: Character) -> Bool {
            c.isASCII && c.isNumber
        }

        private func isIdentifierStart(_ c: Character) -> Bool {
            c.isLetter || c == "_"
        }

        private func isIdentifierPart(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_"
        }
    }
}

enum ExprConstants {
    static func value(_ name: String) -> Double? {
        switch name {
        case "pi", "π": return Double.pi
        case "e": return Darwin.M_E
        case "tau", "τ": return 2 * Double.pi
        default: return nil
        }
    }
}
