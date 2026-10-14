import AppKit
import GrapherKit
import UniformTypeIdentifiers

/// 一份图形文档，走 AppKit 的 NSDocument 文档模型：打开、保存、另存为、窗口标题与代理图标、
/// 关闭按钮里的小圆点、关窗 / 退出时「是否保存更改」的提示，全是系统的标准流程。
/// 文件格式没变，仍是 `DocumentStore` 写的 JSON（Info.plist 里登记的文档类型是 `public.json`）。
final class GraphDocument: NSDocument {

    /// `CFBundleDocumentTypes` 里登记的类型（project.yml），也是 `fileType`。
    static let typeName = UTType.json.identifier

    let state: AppState

    /// 新建空白文档：平面图或立体图（⌘N / ⇧⌘N）。打开文件时也先建一份空白的，再由 `read` 换上内容。
    init(dimension: DocumentDimension) {
        state = AppState(dimension: dimension)
        super.init()
        // 撤销栈用 NSDocument 自己的：撤销 / 重做时它自动增减改动计数。
        state.undoManager = undoManager
        // 拖滑块、输入公式这些连续改动要等一串结束才记一步撤销，中途就得先标成已修改。
        state.onEdit = { [weak self] in self?.updateChangeCount(.changeDone) }
    }

    override convenience init() {
        self.init(dimension: .plane)
    }

    /// 不就地自动保存：改过的文档关窗、退出时弹标准的「是否保存更改」提示，而不是悄悄写回文件。
    override class var autosavesInPlace: Bool { false }

    /// 刚开出来、没动过、也没有任何内容的未命名文档。此时打开文件，文件就接替它的窗口
    /// （`GraphDocumentController.openDocument`），不在旁边留一扇空窗口。
    var isTransient: Bool {
        fileURL == nil && !isDocumentEdited
            && state.document.layers.isEmpty && state.document.parameters.isEmpty
    }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(state: state))
    }

    override func data(ofType typeName: String) throws -> Data {
        try DocumentStore.encode(state.document)
    }

    /// 没有声明可以并发读（`canConcurrentlyReadDocuments` 默认 false），AppKit 在主线程上调这里。
    nonisolated override func read(from data: Data, ofType typeName: String) throws {
        let loaded = try DocumentStore.decode(data)
        MainActor.assumeIsolated {
            state.replaceDocument(with: loaded)
        }
    }
}
