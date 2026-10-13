import Foundation

/// 各处的应用目录统一在这里建，别在调用处拼路径（同 FreeMind / Perch / UniReader）。
enum AppDirectories {
    /// `~/Library/Application Support/GrapherNG`
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("GrapherNG", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
