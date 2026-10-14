import Foundation
import Network

/// MCP 设置项，存在 UserDefaults；访问令牌在 Keychain。
enum MCPSettings {
    static let enabledKey = "mcpServerEnabled"
    static let portKey = "mcpServerPort"
    static let allowWriteKey = "mcpAllowWrite"
    static let defaultPort = 8775
    private static let tokenAccount = "mcp-token"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var allowsWrite: Bool {
        get { UserDefaults.standard.bool(forKey: allowWriteKey) }
        set { UserDefaults.standard.set(newValue, forKey: allowWriteKey) }
    }

    static var port: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: portKey)
            return (1024...65535).contains(stored) ? stored : defaultPort
        }
        set { UserDefaults.standard.set(newValue, forKey: portKey) }
    }

    /// 每次读取都保证有值：第一次打开设置就能复制，不必先手动生成。
    static var token: String {
        if let existing = Keychain.read(account: tokenAccount) { return existing }
        return regenerateToken()
    }

    @discardableResult
    static func regenerateToken() -> String {
        let generated = UUID().uuidString
        Keychain.write(generated, account: tokenAccount)
        return generated
    }
}

/// MCP 服务器：本机唯一入口，让 AI（Claude Code 等）经 HTTP + JSON-RPC 读写文档里的图形。
/// 协议与 HTTP 解析是纯逻辑（`MCPProtocol` / `MCPHTTP`），这里只管网络监听、鉴权与生命周期。
/// 只监听 127.0.0.1，跑在本进程里，不是独立的进程或 target。
@MainActor
final class MCPServer {
    /// 运行状态变了（启动、停止、监听失败）时发出，设置窗口据此刷新。
    static let didChange = Notification.Name("GrapherNGMCPServerDidChange")

    private(set) var isRunning = false
    private(set) var lastError: String?
    /// 实际监听的端口（设置里改了端口、还没重启监听前，和 `MCPSettings.port` 可能不同）。
    private(set) var listeningPort: Int?

    let catalog = MCPCatalog()

    private var listener: NWListener?
    private let netQueue = DispatchQueue(label: "tech.xvanturing.grapherng.mcp.net")
    /// initialize 响应里带的 session id：Streamable HTTP 要求服务端返回一个，但单进程本机工具不跟踪会话，
    /// 固定一个值即可，后续请求不校验它。
    private let sessionID = UUID().uuidString

    init(facade: MCPFacade) {
        catalog.isWriteAllowed = { MCPSettings.allowsWrite }
        MCPTools.registerAll(into: catalog, facade: facade)
    }

    func start() {
        guard listener == nil else { return }
        let port = MCPSettings.port
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            report(error: "invalid port \(port)")
            return
        }

        let parameters = NWParameters.tcp
        // 改端口后马上重启会撞上旧 socket 的 TIME_WAIT，允许复用本地地址。
        parameters.allowLocalEndpointReuse = true
        // 端口已经写在 requiredLocalEndpoint 里，不能再给 NWListener 传一次，两处同时给会直接 EINVAL。
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)

        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerStateChanged(state, port: port) }
            }
            listener.start(queue: netQueue)
            self.listener = listener
        } catch {
            report(error: "\(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        listeningPort = nil
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func restart() {
        stop()
        start()
    }

    private func listenerStateChanged(_ state: NWListener.State, port: Int) {
        switch state {
        case .ready:
            isRunning = true
            listeningPort = port
            lastError = nil
        case .failed(let error):
            // 失败后 listener 已不可用，丢掉它，下次 start() 才能重建。
            listener?.cancel()
            listener = nil
            isRunning = false
            listeningPort = nil
            lastError = "\(error)"
        case .cancelled:
            isRunning = false
        default:
            return
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func report(error: String) {
        lastError = error
        isRunning = false
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - Connection handling
    //
    // 下面几个方法标 `nonisolated`：它们跑在网络队列上，不该把网络 I/O 悄悄顶到主线程。
    // 真要碰主线程状态（目录、令牌）的地方显式 `Task { @MainActor in }` 跳一次。

    private nonisolated func accept(_ connection: NWConnection) {
        let parser = MCPHTTPRequestParser()
        connection.start(queue: netQueue)
        receiveLoop(connection: connection, parser: parser)
    }

    private nonisolated func receiveLoop(connection: NWConnection, parser: MCPHTTPRequestParser) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    if let request = try parser.feed(data) {
                        self.respond(to: request, on: connection)
                        return
                    }
                } catch {
                    self.send(.json(400, ["error": "bad request"]), on: connection)
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveLoop(connection: connection, parser: parser)
        }
    }

    private nonisolated func respond(to request: MCPHTTPRequest, on connection: NWConnection) {
        guard request.path == "/mcp" else {
            send(.json(404, ["error": "not found; POST to /mcp"]), on: connection)
            return
        }
        guard request.method == "POST" else {
            send(.json(405, ["error": "method not allowed; this server only supports POST /mcp"]), on: connection)
            return
        }
        // curl、Claude Code 这类非浏览器客户端不带 Origin：只在带了的时候校验，
        // 防的是恶意网页用 fetch() 打本机端口（DNS rebinding），不是拦本机的命令行。
        if let origin = request.headers["origin"], !Self.isOriginAllowed(origin) {
            send(.json(403, ["error": "origin not allowed"]), on: connection)
            return
        }

        Task { @MainActor in
            guard Self.isAuthorized(request.headers["authorization"]) else {
                self.send(.json(401, ["error": "missing or invalid bearer token"]), on: connection)
                return
            }
            let result = await MCPDispatcher.dispatch(body: request.body, catalog: self.catalog)
            guard let responseObject = result.responseObject else {
                self.send(.empty(202), on: connection)
                return
            }
            self.send(.json(200, responseObject, extraHeaders: ["Mcp-Session-Id": self.sessionID]), on: connection)
        }
    }

    private nonisolated func send(_ response: MCPHTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialize(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    nonisolated static func isOriginAllowed(_ origin: String) -> Bool {
        ["http://localhost", "http://127.0.0.1", "https://localhost", "https://127.0.0.1"].contains { prefix in
            // 要么整个相等，要么后面紧跟端口或路径：挡掉 http://localhost.evil.com。
            origin == prefix || origin.hasPrefix(prefix + ":") || origin.hasPrefix(prefix + "/")
        }
    }

    private static func isAuthorized(_ header: String?) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        return constantTimeEquals(String(header.dropFirst("Bearer ".count)), MCPSettings.token)
    }

    /// 不用 `==` 直接比令牌：字符串比较遇到第一个不同的字符就返回，理论上留了计时侧信道。
    /// 逐字节异或再判断是否全零，耗时与内容无关。
    nonisolated static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<aBytes.count { difference |= aBytes[index] ^ bBytes[index] }
        return difference == 0
    }
}
