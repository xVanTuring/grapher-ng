import AppKit
import GrapherKit

/// 文档控制器：在 `applicationWillFinishLaunching` 里最先建出来，成为 `NSDocumentController.shared`。
/// 新建（⌘N）、打开（⌘O）、退出前逐个确认未保存的文档，都用 AppKit 自带的实现；这里只补两件事：
/// 新建立体图 / 示例，以及打开文件时接替那扇空白窗口。
final class GraphDocumentController: NSDocumentController {

    static var graphShared: GraphDocumentController? { shared as? GraphDocumentController }

    /// ⇧⌘N 与欢迎窗口的「示例」。自带的 `newDocument:` 只会建默认的空白平面图，其余的在这里建，
    /// 流程同 `openUntitledDocumentAndDisplay`。示例不算改动：原样关掉不提示保存。
    func newDocument(dimension: DocumentDimension, example: Bool = false) {
        let document = GraphDocument(dimension: dimension, example: example)
        document.fileType = defaultType ?? GraphDocument.typeName
        // 示例窗口标题写明是哪个示例，存的时候也以它为默认文件名。
        if example {
            document.displayName = dimension == .space ? L("3D Example") : L("2D Example")
        }
        addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
    }

    /// 只开着一扇刚建出来、没动过的空白窗口时打开文件，文件接替这扇窗口（同「文本编辑」）：
    /// 新窗口摆到它的位置上，再把它关掉。顺序不能反：先关空白窗口的话，那一刻一扇窗口都没有，
    /// `applicationShouldTerminateAfterLastWindowClosed` 会让程序直接退出。
    override func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
    ) {
        let transient = documents.count == 1 ? documents.first as? GraphDocument : nil
        super.openDocument(withContentsOf: url, display: false) { document, alreadyOpen, error in
            if let document, displayDocument {
                if document.windowControllers.isEmpty {
                    document.makeWindowControllers()
                }
                // 打开要花时间，期间那扇空白窗口可能已经被用上了，这里再核对一次。
                var replacing: GraphDocument?
                if let transient, transient !== document, !alreadyOpen, transient.isTransient {
                    replacing = transient
                }
                if let frame = replacing?.windowControllers.first?.window?.frame {
                    document.windowControllers.first?.window?.setFrame(frame, display: false)
                }
                document.showWindows()
                replacing?.close()
            }
            completionHandler(document, alreadyOpen, error)
        }
    }
}
