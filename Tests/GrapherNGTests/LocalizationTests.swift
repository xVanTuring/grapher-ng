import XCTest
@testable import GrapherKit

/// 每种语言一份 `Localizable.strings`，key 用英文原文。新增文字时两份都要补：
/// 这里核对 App 与 GrapherKit 两个 bundle 里 en / zh-Hans 的 key 完全一致、译文不为空。
final class LocalizationTests: XCTestCase {

    private func table(_ bundle: Bundle, _ language: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: String] {
        let path = try XCTUnwrap(
            bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language),
            "\(bundle.bundleURL.lastPathComponent) 缺 \(language).lproj/Localizable.strings",
            file: file,
            line: line
        )
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], file: file, line: line)
    }

    private func assertComplete(_ bundle: Bundle, file: StaticString = #filePath, line: UInt = #line) throws {
        let en = try table(bundle, "en", file: file, line: line)
        let zh = try table(bundle, "zh-Hans", file: file, line: line)
        XCTAssertFalse(en.isEmpty, file: file, line: line)
        XCTAssertEqual(Set(en.keys).subtracting(zh.keys).sorted(), [], "zh-Hans 漏翻", file: file, line: line)
        XCTAssertEqual(Set(zh.keys).subtracting(en.keys).sorted(), [], "en 缺条目", file: file, line: line)
        for (key, value) in zh where value.isEmpty {
            XCTFail("zh-Hans 译文为空：\(key)", file: file, line: line)
        }
        // 带格式占位符的条目，两种语言的占位符个数必须一致，否则 String(format:) 会读错参数。
        for (key, value) in zh {
            XCTAssertEqual(placeholders(in: key), placeholders(in: value), "占位符对不上：\(key)", file: file, line: line)
        }
    }

    private func placeholders(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(@|ld|d|\\.4g|g)")
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    func testAppStringsAreCompleteInBothLanguages() throws {
        try assertComplete(Bundle.main)
    }

    func testKitStringsAreCompleteInBothLanguages() throws {
        try assertComplete(Bundle(for: LayerCompiler.self))
    }

    /// 测试方案固定用简体中文跑（project.yml 的 `language: zh-Hans`），GrapherKit 的文字应当是中文。
    func testKitResolvesToTheTestLanguage() {
        XCTAssertEqual(PlotKind.region.shortName, "区域")
    }
}
