import Foundation

/// 界面文字一律走这里：key 用英文原文本身，翻译在 `Resources/<语言>.lproj/Localizable.strings`
/// （en、zh-Hans）。新增文字时两份都要补，`LocalizationTests` 会核对两边的 key 是否一致。
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
