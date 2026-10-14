import Foundation

/// - `.read`：任何时候都能调。
/// - `.write`：会新建 / 修改文档或写文件，受设置里的「允许 AI 修改」总闸控制（默认关闭）；
///   闸门检查集中在 `MCPCatalog.call`，各工具不必自己判断。
enum MCPToolTier {
    case read
    case write
}

struct MCPToolResult {
    var text: String
    var structured: MCPObject?
    /// 附带的 PNG 图片（`render_image`）：以 MCP 的 image 内容块返回，模型能直接看到。
    var imagePNG: Data?

    init(text: String, structured: MCPObject? = nil, imagePNG: Data? = nil) {
        self.text = text
        self.structured = structured
        self.imagePNG = imagePNG
    }
}

struct MCPTool {
    let name: String
    let title: String
    let description: String
    let inputSchema: MCPObject
    let tier: MCPToolTier
    let handler: (MCPArgs) async throws -> MCPToolResult
}

/// 工具注册表 + 统一的写权限闸门：「写权限关闭时一切写操作都拒绝」这条规则只写在这一处。
final class MCPCatalog {
    private var tools: [String: MCPTool] = [:]
    /// 由 `MCPServer` 注入，读设置里的开关。
    var isWriteAllowed: () -> Bool = { false }

    func register(_ tool: MCPTool) {
        tools[tool.name] = tool
    }

    func toolDescriptors() -> [MCPObject] {
        tools.values.sorted { $0.name < $1.name }.map { tool in
            [
                "name": tool.name,
                "title": tool.title,
                "description": tool.description,
                "inputSchema": tool.inputSchema,
                "annotations": ["readOnlyHint": tool.tier == .read],
            ]
        }
    }

    func call(name: String, arguments: MCPObject) async throws -> MCPObject {
        guard let tool = tools[name] else {
            throw MCPInvalidParams("unknown tool: \(name)")
        }
        if tool.tier == .write, !isWriteAllowed() {
            return Self.errorResult(
                "Write access is disabled. Turn on \"Allow AI to modify graphs\" in Grapher NG ▸ Settings… to use \(name)."
            )
        }
        do {
            let result = try await tool.handler(MCPArgs(raw: arguments))
            var content: [MCPObject] = [["type": "text", "text": result.text]]
            if let png = result.imagePNG {
                content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"])
            }
            var object: MCPObject = ["content": content]
            if let structured = result.structured { object["structuredContent"] = structured }
            return object
        } catch let error as MCPToolError {
            return Self.errorResult(error.message)
        } catch let error as MCPInvalidParams {
            // 参数不对对模型来说也是可纠正的：当工具错误返回，而不是协议错误，它才看得到原因。
            return Self.errorResult("Invalid arguments: \(error.message)")
        }
    }

    private static func errorResult(_ message: String) -> MCPObject {
        ["content": [["type": "text", "text": message]], "isError": true]
    }
}
