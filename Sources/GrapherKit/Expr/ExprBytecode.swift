import Darwin

enum ExprOp: UInt8 {
    case pushConstant
    case pushVariable
    case add
    case subtract
    case multiply
    case divide
    case modulo
    case power
    case negate
    case logicalNot
    case less
    case lessEqual
    case greater
    case greaterEqual
    case equal
    case notEqual
    case jump
    case jumpIfFalse
    case jumpIfTrue
    case duplicate
    case discard
    case toBoolean
    case callUnary
    case callBinary
    case callTernary
    case halt
}

enum ExprBuiltin: Int32 {
    case sin, cos, tan, cot, sec, csc
    case asin, acos, atan
    case sinh, cosh, tanh
    case asinh, acosh, atanh
    case exp, ln, log, log2, log10
    case sqrt, cbrt, abs, sign
    case floor, ceil, round, trunc
    case erf, gamma, step
    case atan2, mod, pow, hypot, min, max
    case clamp, smoothstep, ifThen

    var arity: Int {
        switch self {
        case .atan2, .mod, .pow, .hypot, .min, .max: return 2
        case .clamp, .smoothstep, .ifThen: return 3
        default: return 1
        }
    }

    var callOp: ExprOp {
        switch arity {
        case 2: return .callBinary
        case 3: return .callTernary
        default: return .callUnary
        }
    }

    static let byName: [String: ExprBuiltin] = [
        "sin": .sin, "cos": .cos, "tan": .tan, "cot": .cot, "sec": .sec, "csc": .csc,
        "asin": .asin, "acos": .acos, "atan": .atan,
        "sinh": .sinh, "cosh": .cosh, "tanh": .tanh,
        "asinh": .asinh, "acosh": .acosh, "atanh": .atanh,
        "exp": .exp, "ln": .ln, "log": .log, "log2": .log2, "log10": .log10,
        "sqrt": .sqrt, "cbrt": .cbrt, "abs": .abs, "sign": .sign,
        "floor": .floor, "ceil": .ceil, "round": .round, "trunc": .trunc,
        "erf": .erf, "gamma": .gamma, "step": .step,
        "atan2": .atan2, "mod": .mod, "pow": .pow, "hypot": .hypot, "min": .min, "max": .max,
        "clamp": .clamp, "smoothstep": .smoothstep, "if": .ifThen,
    ]
}

struct ExprProgram {
    var ops: [ExprOp]
    var operands: [Int32]
    var constants: [Double]
    var stackDepth: Int
    var requiredValues: Int
}

@inline(__always)
func exprTruthy<T: MathScalar>(_ x: T) -> Bool {
    x == x && !(x == T.zero)
}

@inline(__always)
func exprApplyUnary<T: MathScalar>(_ fn: ExprBuiltin, _ a: T) -> T {
    switch fn {
    case .sin: return T.sin(a)
    case .cos: return T.cos(a)
    case .tan: return T.tan(a)
    case .cot: return T.cos(a) / T.sin(a)
    case .sec: return T.one / T.cos(a)
    case .csc: return T.one / T.sin(a)
    case .asin: return T.asin(a)
    case .acos: return T.acos(a)
    case .atan: return T.atan(a)
    case .sinh: return T.sinh(a)
    case .cosh: return T.cosh(a)
    case .tanh: return T.tanh(a)
    case .asinh: return T.asinh(a)
    case .acosh: return T.acosh(a)
    case .atanh: return T.atanh(a)
    case .exp: return T.exp(a)
    case .ln, .log: return T.ln(a)
    case .log2: return T.log2(a)
    case .log10: return T.log10(a)
    case .sqrt: return T.sqrt(a)
    case .cbrt: return T.cbrt(a)
    case .abs: return T.abs(a)
    case .sign:
        if !(a == a) { return a }
        if a == T.zero { return T.zero }
        return T.zero < a ? T.one : -T.one
    case .floor: return T.floor(a)
    case .ceil: return T.ceil(a)
    case .round: return T.round(a)
    case .trunc: return T.trunc(a)
    case .erf: return T.erf(a)
    case .gamma: return T.fromDouble(Darwin.tgamma(a.doubleValue))
    case .step: return (T.zero < a || a == T.zero) ? T.one : T.zero
    default: return a
    }
}

@inline(__always)
func exprApplyBinary<T: MathScalar>(_ fn: ExprBuiltin, _ a: T, _ b: T) -> T {
    switch fn {
    case .atan2: return T.atan2(a, b)
    case .mod: return T.fmod(a, b)
    case .pow: return T.pow(a, b)
    case .hypot: return T.hypot(a, b)
    case .min: return T.min(a, b)
    case .max: return T.max(a, b)
    default: return a
    }
}

@inline(__always)
func exprApplyTernary<T: MathScalar>(_ fn: ExprBuiltin, _ a: T, _ b: T, _ c: T) -> T {
    switch fn {
    case .clamp: return T.max(b, T.min(a, c))
    case .smoothstep:
        let two = T.fromDouble(2)
        let three = T.fromDouble(3)
        let t = T.max(T.zero, T.min(T.one, (c - a) / (b - a)))
        return t * t * (three - two * t)
    case .ifThen: return exprTruthy(a) ? b : c
    default: return a
    }
}

@inline(__always)
func exprRun<T: MathScalar>(
    ops: UnsafePointer<ExprOp>,
    operands: UnsafePointer<Int32>,
    constants: UnsafePointer<Double>,
    values: UnsafePointer<T>,
    stack: UnsafeMutablePointer<T>
) -> T {
    var pc = 0
    var sp = 0
    while true {
        switch ops[pc] {
        case .pushConstant:
            stack[sp] = T.fromDouble(constants[Int(operands[pc])])
            sp += 1
        case .pushVariable:
            stack[sp] = values[Int(operands[pc])]
            sp += 1
        case .add:
            sp -= 1
            stack[sp - 1] = stack[sp - 1] + stack[sp]
        case .subtract:
            sp -= 1
            stack[sp - 1] = stack[sp - 1] - stack[sp]
        case .multiply:
            sp -= 1
            stack[sp - 1] = stack[sp - 1] * stack[sp]
        case .divide:
            sp -= 1
            stack[sp - 1] = stack[sp - 1] / stack[sp]
        case .modulo:
            sp -= 1
            stack[sp - 1] = T.fmod(stack[sp - 1], stack[sp])
        case .power:
            sp -= 1
            stack[sp - 1] = T.pow(stack[sp - 1], stack[sp])
        case .negate:
            stack[sp - 1] = -stack[sp - 1]
        case .logicalNot:
            stack[sp - 1] = exprTruthy(stack[sp - 1]) ? T.zero : T.one
        case .toBoolean:
            stack[sp - 1] = exprTruthy(stack[sp - 1]) ? T.one : T.zero
        case .less:
            sp -= 1
            let a = stack[sp - 1]
            let b = stack[sp]
            stack[sp - 1] = (a == a && b == b && a < b) ? T.one : T.zero
        case .lessEqual:
            sp -= 1
            let a = stack[sp - 1]
            let b = stack[sp]
            stack[sp - 1] = (a == a && b == b && !(b < a)) ? T.one : T.zero
        case .greater:
            sp -= 1
            let a = stack[sp - 1]
            let b = stack[sp]
            stack[sp - 1] = (a == a && b == b && b < a) ? T.one : T.zero
        case .greaterEqual:
            sp -= 1
            let a = stack[sp - 1]
            let b = stack[sp]
            stack[sp - 1] = (a == a && b == b && !(a < b)) ? T.one : T.zero
        case .equal:
            sp -= 1
            let a = stack[sp - 1]
            let b = stack[sp]
            stack[sp - 1] = (a == b) ? T.one : T.zero
        case .notEqual:
            sp -= 1
            let a = stack[sp - 1]
            let b = stack[sp]
            stack[sp - 1] = (a == a && b == b && !(a == b)) ? T.one : T.zero
        case .duplicate:
            stack[sp] = stack[sp - 1]
            sp += 1
        case .discard:
            sp -= 1
        case .jump:
            pc = Int(operands[pc])
            continue
        case .jumpIfFalse:
            let value = stack[sp - 1]
            sp -= 1
            if !exprTruthy(value) {
                pc = Int(operands[pc])
                continue
            }
        case .jumpIfTrue:
            let value = stack[sp - 1]
            sp -= 1
            if exprTruthy(value) {
                pc = Int(operands[pc])
                continue
            }
        case .callUnary:
            stack[sp - 1] = exprApplyUnary(ExprBuiltin(rawValue: operands[pc]) ?? .sin, stack[sp - 1])
        case .callBinary:
            sp -= 1
            stack[sp - 1] = exprApplyBinary(ExprBuiltin(rawValue: operands[pc]) ?? .pow, stack[sp - 1], stack[sp])
        case .callTernary:
            sp -= 2
            stack[sp - 1] = exprApplyTernary(
                ExprBuiltin(rawValue: operands[pc]) ?? .clamp,
                stack[sp - 1], stack[sp], stack[sp + 1]
            )
        case .halt:
            return stack[sp - 1]
        }
        pc += 1
    }
}
