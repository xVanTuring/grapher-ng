import Foundation

/// 梯度流线的起点文本：每行一个起点，`x, y` 两栏，每一栏是数或含参数的公式（如 `3*cos(q), 3*sin(q)`）。
/// 栏之间用逗号、分号或制表符分开；整行没有这些、恰好是用空格隔开的两段时也算两栏（兼容 `1 2` 这种写法）。
/// 一栏一栏地编译，所以公式里可以有空格。
public enum GradientSeeds {

    /// 每个起点的两栏文字，不是恰好两栏的行（表头、空行、多余的栏）跳过。
    public static func fields(_ text: String) -> [(x: String, y: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let delimiters: Set<Character> = [",", ";", "\t"]
            var parts: [String]
            if line.contains(where: delimiters.contains) {
                parts = line.split(whereSeparator: delimiters.contains).map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                parts = line.split(separator: " ").map(String.init)
            }
            parts = parts.filter { !$0.isEmpty }
            guard parts.count >= 2 else { return nil }
            // 多于两栏（如 CSV 多一列）只取前两栏，同散点数据。
            return (parts[0], parts[1])
        }
    }
}
