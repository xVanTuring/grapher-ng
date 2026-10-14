import Foundation

struct MCPHTTPRequest {
    var method: String
    var path: String
    /// key 已转小写：HTTP 头名不区分大小写。
    var headers: [String: String]
    var body: Data
}

struct MCPHTTPResponse {
    var status: Int
    var statusText: String
    var headers: [String: String] = [:]
    var body: Data

    static func json(_ status: Int, _ object: Any, extraHeaders: [String: String] = [:]) -> MCPHTTPResponse {
        var headers = extraHeaders
        headers["Content-Type"] = "application/json"
        return MCPHTTPResponse(status: status, statusText: statusText(for: status), headers: headers, body: MCPJSON.encode(object))
    }

    static func empty(_ status: Int) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, statusText: statusText(for: status), body: Data())
    }

    private static func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        default: return "Internal Server Error"
        }
    }

    func serialize() -> Data {
        var allHeaders = headers
        allHeaders["Content-Length"] = "\(body.count)"
        // 每条连接只服务一个请求，显式关闭，免得客户端复用这条 TCP 连接发第二个请求。
        allHeaders["Connection"] = "close"

        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        for (key, value) in allHeaders {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

/// 增量喂字节，凑齐一条完整的 HTTP 请求（头部 + `Content-Length` 指定长度的 body）就返回。
/// 只服务本机单发单收的 MCP 调用：不支持 chunked、keep-alive、pipelining，每条连接只处理一个请求。
/// `@unchecked Sendable`：每个解析器只在它那条连接的网络队列回调链里被访问，不会并发。
final class MCPHTTPRequestParser: @unchecked Sendable {
    /// 请求体上限：正常的工具调用只有几 KB，挡掉恶意的超大 `Content-Length`。
    static let maxBodyBytes = 1 << 20

    private var buffer = Data()
    private var headParsed: (method: String, path: String, headers: [String: String])?
    private var contentLength: Int?

    /// 追加收到的字节；凑够一条完整请求时返回，否则返回 nil 继续等。
    /// 请求格式不对时抛错，调用方回 400 并关闭连接。
    func feed(_ data: Data) throws -> MCPHTTPRequest? {
        buffer.append(data)

        if headParsed == nil {
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let headerData = buffer.subdata(in: buffer.startIndex..<separator.lowerBound)
            guard let headerString = String(data: headerData, encoding: .utf8) else {
                throw MCPToolError("invalid header encoding")
            }
            let lines = headerString.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { throw MCPToolError("empty request") }
            let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2 else { throw MCPToolError("malformed request line: \(requestLine)") }

            var headers: [String: String] = [:]
            for line in lines.dropFirst() where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }

            let length = headers["content-length"].flatMap(Int.init) ?? 0
            guard length >= 0, length <= Self.maxBodyBytes else { throw MCPToolError("body too large") }
            headParsed = (String(parts[0]), String(parts[1]), headers)
            contentLength = length
            buffer.removeSubrange(buffer.startIndex..<separator.upperBound)
        }

        guard let head = headParsed, let length = contentLength, buffer.count >= length else { return nil }
        let bodyEnd = buffer.index(buffer.startIndex, offsetBy: length)
        let body = buffer.subdata(in: buffer.startIndex..<bodyEnd)
        return MCPHTTPRequest(method: head.method, path: head.path, headers: head.headers, body: body)
    }
}
