import Foundation

/// GrapherKit 自己的界面文字（图型名、公式错误提示、示例文档的图层名）。文字放在本 framework 的
/// `Localizable.strings` 里（en / zh-Hans），不在 App 那份里；key 用英文原文本身。
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: kitBundle, comment: "")
}

private final class KitBundleToken {}
private let kitBundle = Bundle(for: KitBundleToken.self)
