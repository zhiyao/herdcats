import Foundation

/// JSON values on Core's wire. Backend models decode only the fields they own.
enum CoreJSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CoreJSON])
    case object([String: CoreJSON])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode([CoreJSON].self) { self = .array(item) }
        else { self = .object(try value.decode([String: CoreJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case let .bool(item): try value.encode(item)
        case let .number(item): try value.encode(item)
        case let .string(item): try value.encode(item)
        case let .array(item): try value.encode(item)
        case let .object(item): try value.encode(item)
        }
    }

    subscript(_ key: String) -> CoreJSON { objectValue?[key] ?? .null }
    var stringValue: String? { if case let .string(item) = self { return item }; return nil }
    var boolValue: Bool? { if case let .bool(item) = self { return item }; return nil }
    var arrayValue: [CoreJSON]? { if case let .array(item) = self { return item }; return nil }
    var objectValue: [String: CoreJSON]? { if case let .object(item) = self { return item }; return nil }
    var intValue: Int? {
        guard case let .number(item) = self else { return nil }
        return Int(exactly: item)
    }
    var uint64Value: UInt64? {
        guard case let .number(item) = self else { return nil }
        return UInt64(exactly: item)
    }
    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

enum CoreRPCError: Error, LocalizedError, Equatable, Sendable {
    case closed
    case timeout
    case invalidFrame
    case frameTooLarge
    case unsupportedGeneration
    case tooManyRequests
    case remote(code: Int, kind: String, message: String, hint: String?)

    var errorDescription: String? {
        switch self {
        case .closed: return "The Herdr Core connection closed. Reconnect to continue."
        case .timeout: return "Herdr Core did not respond in time. Input was not retried."
        case .invalidFrame: return "Herdr Core returned an invalid protocol response."
        case .frameTooLarge: return "Herdr Core exceeded the connection's response limit."
        case .unsupportedGeneration: return "This Herdr Core protocol is unsupported. Update Herdcats or check the installed Core version."
        case .tooManyRequests: return "Herdr Core is busy. Try again when the current operation finishes."
        case let .remote(_, kind, message, hint):
            return "Herdr Core (\(kind)): \(message)" + (hint.flatMap { $0.isEmpty ? nil : " \($0)" } ?? "")
        }
    }

    static func responseError(_ reply: CoreJSON) -> CoreRPCError? {
        guard let error = reply["error"].objectValue else { return nil }
        let details = error["data"] ?? .null
        return .remote(code: error["code"]?.intValue ?? -32000,
                       kind: details["kind"].stringValue ?? "rpc_error",
                       message: error["message"]?.stringValue ?? "Request failed",
                       hint: details["hint"].stringValue)
    }
}

enum CoreFrameKind: UInt8, Sendable {
    case data = 0, credit = 1, close = 2, resize = 3, focus = 4, facts = 5
}

struct CoreFrame: Equatable, Sendable {
    static let maximumPayload = 16 * 1024 * 1024
    let channel: UInt32
    let kind: CoreFrameKind
    let payload: Data

    func encoded() throws -> Data {
        guard payload.count <= Self.maximumPayload else { throw CoreRPCError.frameTooLarge }
        var data = Data()
        data.reserveCapacity(9 + payload.count)
        Self.appendLittleEndian(channel, to: &data)
        data.append(kind.rawValue)
        Self.appendLittleEndian(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}

/// Buffers bytes, not strings: a read may end inside a header or UTF-8 scalar.
struct CoreFrameParser {
    private var buffer = Data()

    mutating func append(_ bytes: Data) throws -> [CoreFrame] {
        buffer.append(bytes)
        var offset = 0
        var frames: [CoreFrame] = []
        while buffer.count - offset >= 9 {
            let channel = littleEndian(at: offset)
            guard let kind = CoreFrameKind(rawValue: buffer[offset + 4]) else {
                throw CoreRPCError.invalidFrame
            }
            let count = Int(littleEndian(at: offset + 5))
            guard count <= CoreFrame.maximumPayload else { throw CoreRPCError.frameTooLarge }
            guard buffer.count - offset - 9 >= count else { break }
            let start = offset + 9
            frames.append(CoreFrame(channel: channel, kind: kind, payload: Data(buffer[start..<(start + count)])))
            offset = start + count
        }
        if offset > 0 { buffer = Data(buffer.dropFirst(offset)) }
        return frames
    }

    func finish() throws {
        guard buffer.isEmpty else { throw CoreRPCError.invalidFrame }
    }

    private func littleEndian(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(buffer[offset + $1]) << ($1 * 8) }
    }
}

struct CoreJSONLineParser {
    private var buffer = Data()
    let maximumLineBytes: Int

    init(maximumLineBytes: Int = CoreFrame.maximumPayload) {
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func append(_ bytes: Data) throws -> [CoreJSON] {
        buffer.append(bytes)
        var messages: [CoreJSON] = []
        while let newline = buffer.firstIndex(of: 10) {
            guard newline <= maximumLineBytes else { throw CoreRPCError.frameTooLarge }
            let line = Data(buffer.prefix(upTo: newline))
            buffer = Data(buffer.suffix(from: newline + 1))
            if !line.isEmpty {
                do { messages.append(try JSONDecoder().decode(CoreJSON.self, from: line)) }
                catch { throw CoreRPCError.invalidFrame }
            }
        }
        guard buffer.count <= maximumLineBytes else { throw CoreRPCError.frameTooLarge }
        return messages
    }

    func finish() throws {
        guard buffer.isEmpty else { throw CoreRPCError.invalidFrame }
    }
}
