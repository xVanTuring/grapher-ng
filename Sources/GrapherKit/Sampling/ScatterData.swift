import Foundation

/// 散点图的数据：每行一个点，逗号 / 分号 / 空格 / 制表符分隔（能直接从表格里粘进来）。
/// 无法解析成两个有限数的行（表头、空行）跳过。
public enum ScatterData {

    public static func parse(_ text: String) -> [SIMD2<Double>] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: { ",;\t ".contains($0) }).compactMap { Double($0) }
            guard fields.count >= 2, fields[0].isFinite, fields[1].isFinite else { return nil }
            return SIMD2(fields[0], fields[1])
        }
    }

    /// 最小二乘直线 y = slope·x + intercept 与相关系数 r、决定系数 r²。
    public struct Fit: Equatable, Sendable {
        public var slope: Double
        public var intercept: Double
        /// 相关系数（y 全相同时为 nil，没有定义）。
        public var correlation: Double?
        public var count: Int
        public var mean: SIMD2<Double>
        /// 样本标准差（n − 1）；一个点时为 0。
        public var standardDeviation: SIMD2<Double>

        public var rSquared: Double? { correlation.map { $0 * $0 } }
    }

    /// 点数不足两个、或 x 全相同（拟合成竖直线）时返回 nil。
    public static func fit(_ points: [SIMD2<Double>]) -> Fit? {
        let n = Double(points.count)
        guard points.count >= 2 else { return nil }
        let mean = points.reduce(SIMD2<Double>.zero, +) / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in points {
            let d = p - mean
            sxx += d.x * d.x
            syy += d.y * d.y
            sxy += d.x * d.y
        }
        guard sxx > 1e-300 else { return nil }
        let slope = sxy / sxx
        let correlation: Double? = syy > 1e-300 ? sxy / (sxx * syy).squareRoot() : nil
        return Fit(
            slope: slope,
            intercept: mean.y - slope * mean.x,
            correlation: correlation,
            count: points.count,
            mean: mean,
            standardDeviation: SIMD2((sxx / (n - 1)).squareRoot(), (syy / (n - 1)).squareRoot())
        )
    }
}
