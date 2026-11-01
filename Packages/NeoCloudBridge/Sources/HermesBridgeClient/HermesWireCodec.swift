import Foundation
import CloudBridgeCore

// MARK: - A small JSON value

/// The bridge needs exactly enough JSON to read frames; it does not need a second Codable layer on
/// top of the one `CloudBridgeCore` already has. Accepting only the shapes Hermes actually sends
/// keeps the decoder strict.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(any: Any) {
        switch any {
        case is NSNull: self = .null
        case let value as Bool: self = .bool(value)
        case let value as NSNumber:
            // `NSNumber` also matches Bool, which the case above already handled.
            self = .number(value.doubleValue)
        case let value as String: self = .string(value)
        case let value as [Any]: self = .array(value.map(JSONValue.init(any:)))
        case let value as [String: Any]: self = .object(value.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    public var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let value): value.map(\.any)
        case .object(let value): value.mapValues(\.any)
        }
    }

    public subscript(key: String) -> JSONValue {
        if case .object(let dictionary) = self { return dictionary[key] ?? .null }
        return .null
    }

    public var string: String {
        if case .string(let value) = self { return value }
        return ""
    }

    public var int: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var bool: Bool {
        if case .bool(let value) = self { return value }
        return false
    }

    public var array: [JSONValue] {
        if case .array(let value) = self { return value }
        return []
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public static func encode(_ value: JSONValue) throws -> Data {
        try JSONSerialization.data(withJSONObject: value.any, options: [.sortedKeys])
    }

    public static func decode(_ data: Data) throws -> JSONValue {
        JSONValue(any: try JSONSerialization.jsonObject(with: data))
    }
}

// MARK: - Frames

public struct WireError: Sendable, Equatable, CustomStringConvertible {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    /// `-32601` on a capability probe is a *fact about the backend*, not a failure to retry.
    public var isUnknownMethod: Bool { code == -32601 }

    public var description: String { "\(code): \(message)" }
}

public enum WireFrame: Sendable, Equatable {
    case response(id: String, result: JSONValue)
    case failure(id: String, error: WireError)
    /// A server-sent event (`{"method":"event","params":{…}}`).
    case event(JSONValue)
    /// A server→client interactive request (approval, clarify, …).
    case serverRequest(id: String, method: String, params: JSONValue)
    case unrecognised(String)
}

/// The wire format: newline-delimited JSON-RPC, several frames possibly inside one WebSocket message.
public enum HermesWireCodec {
    public static func request(id: String, method: String, params: JSONValue = .object([:])) -> String {
        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .string(id),
            "method": .string(method),
            "params": params,
        ])
        guard let data = try? JSONValue.encode(frame) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func frames(from text: String) -> [WireFrame] {
        // One frame is allowed to arrive pretty-printed; several frames are newline-delimited.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
           let single = try? JSONValue.decode(data) {
            return [frame(from: single)]
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8), let value = try? JSONValue.decode(data) else {
                return .unrecognised(String(line))
            }
            return frame(from: value)
        }
    }

    public static func frame(from value: JSONValue) -> WireFrame {
        let id = value["id"].string
        let method = value["method"].string
        if !method.isEmpty {
            if method == "event" { return .event(value["params"]) }
            return .serverRequest(id: id, method: method, params: value["params"])
        }
        if !value["error"].isNull {
            let error = value["error"]
            return .failure(id: id, error: WireError(code: error["code"].int ?? 0,
                                                    message: error["message"].string))
        }
        if !id.isEmpty { return .response(id: id, result: value["result"]) }
        return .unrecognised(String(decoding: (try? JSONValue.encode(value)) ?? Data(), as: UTF8.self))
    }
}

// MARK: - Typed events

public enum HermesEventMapper {
    /// Map one event frame to the adapter's own vocabulary.
    ///
    /// Unknown frames are dropped rather than forwarded: the executor must never receive a raw frame
    /// it cannot attribute to a message and a stored session.
    public static func event(from params: JSONValue, messageID: UUID?) -> HermesBridgeEvent? {
        let type = params["type"].string
        let storedSessionID = params["session_id"].string
        switch type {
        case "message.start":
            return HermesBridgeEvent(kind: .started, messageID: messageID,
                                     storedSessionID: storedSessionID.isEmpty ? nil : storedSessionID)
        case "message.delta", "thinking.delta", "status.update":
            return HermesBridgeEvent(kind: .progress, messageID: messageID,
                                     storedSessionID: storedSessionID.isEmpty ? nil : storedSessionID,
                                     detail: params["payload"]["text"].string)
        case "message.complete":
            let payload = params["payload"]
            let status = payload["status"].string
            let text = payload["text"].string
            if status == "error" {
                return HermesBridgeEvent(kind: .failed, messageID: messageID,
                                         storedSessionID: storedSessionID.isEmpty ? nil : storedSessionID,
                                         text: text, detail: payload["error"].string)
            }
            return HermesBridgeEvent(kind: .completed, messageID: messageID,
                                     storedSessionID: storedSessionID.isEmpty ? nil : storedSessionID,
                                     text: text)
        case "error":
            return HermesBridgeEvent(kind: .failed, messageID: messageID,
                                     storedSessionID: storedSessionID.isEmpty ? nil : storedSessionID,
                                     detail: params["payload"]["message"].string)
        case "session.reclaimed":
            return HermesBridgeEvent(kind: .disconnected, messageID: messageID,
                                     storedSessionID: params["payload"]["stored_session_id"].string,
                                     detail: "session reclaimed")
        default:
            return nil
        }
    }
}

// MARK: - Endpoint policy

public enum HermesEndpointError: Error, Equatable, Sendable, CustomStringConvertible {
    case notLoopback(String)
    case invalidPort

    public var description: String {
        switch self {
        case .notLoopback(let host): "the bridge only talks to a loopback Hermes endpoint, not \(host)"
        case .invalidPort: "the Hermes endpoint needs a valid port"
        }
    }
}

/// Only `localhost`, `127.0.0.1` and `::1` — the plan's rule, enforced in one place.
public struct LoopbackEndpoint: Hashable, Sendable, CustomStringConvertible {
    public let host: String
    public let port: Int
    public let scheme: String

    public init(host: String, port: Int, scheme: String = "http") throws {
        let normalised = host.lowercased().trimmingCharacters(in: .whitespaces)
        guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(normalised) else {
            throw HermesEndpointError.notLoopback(host)
        }
        guard (1...65_535).contains(port) else { throw HermesEndpointError.invalidPort }
        self.host = normalised == "[::1]" ? "::1" : normalised
        self.port = port
        self.scheme = scheme
    }

    public var description: String { "\(scheme)://\(host):\(port)" }

    public func url(path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        return components.url ?? URL(string: "http://127.0.0.1:\(port)")!
    }

    public var socketURL: URL {
        var components = URLComponents()
        components.scheme = scheme == "https" ? "wss" : "ws"
        components.host = host
        components.port = port
        components.path = "/api/ws"
        return components.url ?? URL(string: "ws://127.0.0.1:\(port)/api/ws")!
    }
}
