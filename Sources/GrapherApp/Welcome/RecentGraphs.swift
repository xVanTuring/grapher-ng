import AppKit
import GrapherKit
import GrapherRender

/// 最近打开的文档（同 FreeMind 的 `RecentMaps`）：列表由 NSDocumentController 记录，打开、保存时系统自动登记。
@MainActor
enum RecentGraphs {
    static var urls: [URL] {
        NSDocumentController.shared.recentDocumentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// NSDocumentController 没有删除单个条目的接口：清空后按原顺序重新登记其余条目。
    static func remove(_ url: URL) {
        let controller = NSDocumentController.shared
        let remaining = controller.recentDocumentURLs.filter { $0 != url }
        controller.clearRecentDocuments(nil)
        for other in remaining.reversed() { controller.noteNewRecentDocumentURL(other) }
    }

    static func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    static func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    // MARK: - Thumbnails

    /// 缩略图在列表里的尺寸（点）。按两倍像素渲染。
    static let thumbnailSize = CGSize(width: 80, height: 50)

    private static var thumbnails: [String: NSImage] = [:]
    private static let queue = DispatchQueue(label: "tech.xvanturing.GrapherNG.thumbnails", qos: .utility)

    /// 按路径 + 修改时间缓存；没缓存的在后台读文件、重新采样、离屏渲染，好了再回主线程交给 `completion`。
    /// 读不出来（不是本 App 的文档、文件坏了）时交回 nil，列表显示文件图标。
    static func thumbnail(for url: URL, modified: Date?, completion: @escaping (NSImage?) -> Void) {
        let key = "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)"
        if let cached = thumbnails[key] {
            completion(cached)
            return
        }
        let size = thumbnailSize
        queue.async {
            let image = renderThumbnail(url, pixelWidth: Int(size.width) * 2, pixelHeight: Int(size.height) * 2)
            Task { @MainActor in
                let thumbnail = image.map { NSImage(cgImage: $0, size: size) }
                if let thumbnail { thumbnails[key] = thumbnail }
                completion(thumbnail)
            }
        }
    }

    /// 文档保存时的样子（`GraphSnapshot`，与 Finder 缩略图同一份画法），只画网格、坐标轴与图形，不画刻度文字。
    nonisolated private static func renderThumbnail(_ url: URL, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        guard let document = try? DocumentStore.load(from: url) else { return nil }
        return GraphSnapshot.image(of: document, pixelWidth: pixelWidth, pixelHeight: pixelHeight, pointScale: 1, labels: false)
    }

    // MARK: - Dates

    /// 「2 分钟前」「昨天」。语言跟界面走（不跟系统地区），中文界面上不会冒出英文日期。
    static func relativeDate(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return formatter
    }()
}
