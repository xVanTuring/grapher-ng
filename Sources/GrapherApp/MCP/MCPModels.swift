import Foundation

/// 松散的 JSON 对象：MCP 协议往返的最小公分母，免得给每个工具的输入输出各建一个 Codable 类型。
/// 整套 MCP 的结构参考 Perch / UniReader（手写 JSON-RPC over HTTP，不依赖 MCP SDK）。
typealias MCPObject = [String: Any]

enum MCPJSON {
    static func decode(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func encode(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data()
    }
}

/// 工具执行期间的「软失败」：不是协议错误，而是业务失败（比如公式写错、找不到文档）。
/// `MCPCatalog.call` 把它包成 `isError: true` 的正常响应，让模型看到原因后改参数重试。
struct MCPToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// 参数类型或必填项不对：JSON-RPC -32602 Invalid params。
struct MCPInvalidParams: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// 顶层 method 不存在。
struct MCPMethodNotFound: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// 按类型读工具的 `arguments`，类型不对统一转成 `MCPInvalidParams`，各工具不必重复校验。
struct MCPArgs {
    let raw: MCPObject

    /// 没传、或传了 null，都当没有值。
    private func value(_ key: String) -> Any? {
        guard let value = raw[key], !(value is NSNull) else { return nil }
        return value
    }

    func has(_ key: String) -> Bool { value(key) != nil }

    func string(_ key: String) throws -> String {
        guard let text = value(key) as? String, !text.isEmpty else {
            throw MCPInvalidParams("missing or empty required string '\(key)'")
        }
        return text
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = value(key) else { return nil }
        guard let text = value as? String else { throw MCPInvalidParams("'\(key)' must be a string") }
        return text
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard let value = value(key) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw MCPInvalidParams("'\(key)' must be a boolean")
        }
        return number.boolValue
    }

    func optionalDouble(_ key: String) throws -> Double? {
        guard let value = value(key) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw MCPInvalidParams("'\(key)' must be a number")
        }
        let result = number.doubleValue
        guard result.isFinite else { throw MCPInvalidParams("'\(key)' must be a finite number") }
        return result
    }

    func double(_ key: String) throws -> Double {
        guard let result = try optionalDouble(key) else { throw MCPInvalidParams("missing required number '\(key)'") }
        return result
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard let result = try optionalDouble(key) else { return nil }
        return Int(result.rounded())
    }

    func optionalDoubles(_ key: String, count: Int) throws -> [Double]? {
        guard let value = value(key) else { return nil }
        guard let list = value as? [Any], list.count == count else {
            throw MCPInvalidParams("'\(key)' must be an array of \(count) numbers")
        }
        let numbers = list.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard numbers.count == count, numbers.allSatisfy(\.isFinite) else {
            throw MCPInvalidParams("'\(key)' must be an array of \(count) numbers")
        }
        return numbers
    }

    func optionalUUID(_ key: String) throws -> UUID? {
        guard let text = try optionalString(key) else { return nil }
        guard let uuid = UUID(uuidString: text) else { throw MCPInvalidParams("'\(key)' is not a valid UUID: \(text)") }
        return uuid
    }

    func requiredUUID(_ key: String) throws -> UUID {
        guard let uuid = try optionalUUID(key) else { throw MCPInvalidParams("missing required UUID '\(key)'") }
        return uuid
    }
}

/// JSON Schema 构造小工具，只覆盖 MCP 工具 `inputSchema` 用到的那一小部分。
enum MCPSchema {
    static func object(_ properties: MCPObject, required: [String] = []) -> MCPObject {
        var object: MCPObject = ["type": "object", "properties": properties]
        if !required.isEmpty { object["required"] = required }
        return object
    }

    static func string(_ description: String, enumValues: [String]? = nil) -> MCPObject {
        var object: MCPObject = ["type": "string", "description": description]
        if let enumValues { object["enum"] = enumValues }
        return object
    }

    static func number(_ description: String) -> MCPObject {
        ["type": "number", "description": description]
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> MCPObject {
        var object: MCPObject = ["type": "integer", "description": description]
        if let minimum { object["minimum"] = minimum }
        if let maximum { object["maximum"] = maximum }
        return object
    }

    static func boolean(_ description: String) -> MCPObject {
        ["type": "boolean", "description": description]
    }

    static func numbers(_ description: String, count: Int) -> MCPObject {
        ["type": "array", "items": ["type": "number"], "minItems": count, "maxItems": count, "description": description]
    }
}
