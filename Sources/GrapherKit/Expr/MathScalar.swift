import Darwin

public protocol MathScalar: Equatable, AdditiveArithmetic {
    static var one: Self { get }
    static prefix func - (a: Self) -> Self
    static func / (lhs: Self, rhs: Self) -> Self
    static func * (lhs: Self, rhs: Self) -> Self
    static func < (lhs: Self, rhs: Self) -> Bool
    static func pow(_ a: Self, _ b: Self) -> Self
    static func exp(_ a: Self) -> Self
    static func ln(_ a: Self) -> Self
    static func log2(_ a: Self) -> Self
    static func log10(_ a: Self) -> Self
    static func sqrt(_ a: Self) -> Self
    static func cbrt(_ a: Self) -> Self
    static func sin(_ a: Self) -> Self
    static func cos(_ a: Self) -> Self
    static func tan(_ a: Self) -> Self
    static func asin(_ a: Self) -> Self
    static func acos(_ a: Self) -> Self
    static func atan(_ a: Self) -> Self
    static func atan2(_ y: Self, _ x: Self) -> Self
    static func sinh(_ a: Self) -> Self
    static func cosh(_ a: Self) -> Self
    static func tanh(_ a: Self) -> Self
    static func asinh(_ a: Self) -> Self
    static func acosh(_ a: Self) -> Self
    static func atanh(_ a: Self) -> Self
    static func abs(_ a: Self) -> Self
    static func floor(_ a: Self) -> Self
    static func ceil(_ a: Self) -> Self
    static func round(_ a: Self) -> Self
    static func trunc(_ a: Self) -> Self
    static func hypot(_ a: Self, _ b: Self) -> Self
    static func erf(_ a: Self) -> Self
    static func fmod(_ a: Self, _ b: Self) -> Self
    static func min(_ a: Self, _ b: Self) -> Self
    static func max(_ a: Self, _ b: Self) -> Self
    static func fromDouble(_ v: Double) -> Self
    var doubleValue: Double { get }
}

extension Double: MathScalar {
    public static var one: Double { 1 }

    public static func pow(_ a: Double, _ b: Double) -> Double { Darwin.pow(a, b) }
    public static func exp(_ a: Double) -> Double { Darwin.exp(a) }
    public static func ln(_ a: Double) -> Double { Darwin.log(a) }
    public static func log2(_ a: Double) -> Double { Darwin.log2(a) }
    public static func log10(_ a: Double) -> Double { Darwin.log10(a) }
    public static func sqrt(_ a: Double) -> Double { Darwin.sqrt(a) }
    public static func cbrt(_ a: Double) -> Double { Darwin.cbrt(a) }
    public static func sin(_ a: Double) -> Double { Darwin.sin(a) }
    public static func cos(_ a: Double) -> Double { Darwin.cos(a) }
    public static func tan(_ a: Double) -> Double { Darwin.tan(a) }
    public static func asin(_ a: Double) -> Double { Darwin.asin(a) }
    public static func acos(_ a: Double) -> Double { Darwin.acos(a) }
    public static func atan(_ a: Double) -> Double { Darwin.atan(a) }
    public static func atan2(_ y: Double, _ x: Double) -> Double { Darwin.atan2(y, x) }
    public static func sinh(_ a: Double) -> Double { Darwin.sinh(a) }
    public static func cosh(_ a: Double) -> Double { Darwin.cosh(a) }
    public static func tanh(_ a: Double) -> Double { Darwin.tanh(a) }
    public static func asinh(_ a: Double) -> Double { Darwin.asinh(a) }
    public static func acosh(_ a: Double) -> Double { Darwin.acosh(a) }
    public static func atanh(_ a: Double) -> Double { Darwin.atanh(a) }
    public static func abs(_ a: Double) -> Double { Swift.abs(a) }
    public static func floor(_ a: Double) -> Double { Darwin.floor(a) }
    public static func ceil(_ a: Double) -> Double { Darwin.ceil(a) }
    public static func round(_ a: Double) -> Double { Darwin.round(a) }
    public static func trunc(_ a: Double) -> Double { Darwin.trunc(a) }
    public static func hypot(_ a: Double, _ b: Double) -> Double { Darwin.hypot(a, b) }
    public static func erf(_ a: Double) -> Double { Darwin.erf(a) }
    public static func fmod(_ a: Double, _ b: Double) -> Double { Darwin.fmod(a, b) }
    public static func min(_ a: Double, _ b: Double) -> Double { a < b ? a : b }
    public static func max(_ a: Double, _ b: Double) -> Double { a < b ? b : a }
    public static func fromDouble(_ v: Double) -> Double { v }

    public var doubleValue: Double { self }
}
