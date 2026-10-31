import Foundation

enum CoreSnapshotError: LocalizedError, Equatable {
    case invalidSnapshot
    case invalidEvent

    var errorDescription: String? {
        switch self {
        case .invalidSnapshot: "Herdr Core returned an invalid terminal snapshot."
        case .invalidEvent: "Herdr Core returned an invalid terminal event."
        }
    }
}

/// Core owns terminal lifecycle; OSC 7501 owns activity. In particular, a turn
/// event's `state` is the activity it ended on, never the terminal's lifecycle.
struct CoreSnapshot: Sendable {
    var terminals: [String: CoreJSON]
    var seq: UInt64
    private(set) var revisions: [String: UInt64]
    private(set) var statusSequences: [String: UInt64]

    init(subscription: CoreJSON) throws {
        guard let sequence = subscription["seq"].uint64Value,
              let records = subscription["terminals"].arrayValue else {
            throw CoreSnapshotError.invalidSnapshot
        }
        var terminals: [String: CoreJSON] = [:]
        for record in records {
            guard record.objectValue != nil,
                  let address = record["address"].stringValue, !address.isEmpty,
                  record["state"].stringValue?.isEmpty == false else {
                throw CoreSnapshotError.invalidSnapshot
            }
            terminals[address] = record
        }
        self.terminals = terminals
        seq = sequence
        revisions = Dictionary(uniqueKeysWithValues: terminals.keys.map { ($0, sequence) })
        statusSequences = [:]
    }

    /// Returns whether layout documents must be fetched again. A fresh
    /// subscription must construct a fresh CoreSnapshot: sequences reset with
    /// the core process and cannot be compared across connections.
    @discardableResult
    mutating func apply(_ notification: CoreJSON) throws -> Bool {
        guard let method = notification["method"].stringValue else {
            throw CoreSnapshotError.invalidEvent
        }
        if method == "heartbeat" { return false }
        let params = notification["params"]
        if method == "missed" {
            let replacement = try CoreSnapshot(subscription: params)
            guard replacement.seq >= seq else { return false }
            self = replacement
            return true
        }
        guard method == "event" else { return false }
        guard let sequence = params["seq"].uint64Value,
              let type = params["type"].stringValue else {
            throw CoreSnapshotError.invalidEvent
        }
        guard sequence > seq else { return false }
        if type == "doc" {
            seq = sequence
            return params["data"]["name"].stringValue == "herdr-app"
        }
        guard let address = params["terminal"].stringValue, !address.isEmpty else {
            // Future global event kinds are permitted to grow the protocol.
            seq = sequence
            return false
        }
        let data = params["data"]
        switch type {
        case "created", "restarted":
            try replace(data, address: address, sequence: sequence)
        case "removed":
            terminals.removeValue(forKey: address)
            revisions.removeValue(forKey: address)
            statusSequences.removeValue(forKey: address)
        case "labels":
            if data["record"].objectValue != nil {
                try replace(data["record"], address: address, sequence: sequence)
            }
            update(address, sequence: sequence) { $0["labels"] = data["labels"] }
        case "status":
            if let record = terminals[address], record["status"] != data["status"] {
                statusSequences[address] = sequence
            }
            update(address, sequence: sequence) {
                $0["status"] = data["status"]
                $0["records"] = data["records"]
                $0["reported"] = data["reported"]
            }
        case "turn":
            update(address, sequence: sequence) { $0["turn"] = data["turn"] }
        case "foreground":
            update(address, sequence: sequence) { $0["foreground"] = data }
        case "finished", "lost":
            guard let fields = data.objectValue else { throw CoreSnapshotError.invalidEvent }
            update(address, sequence: sequence) {
                $0.merge(fields) { _, new in new }
                $0["foreground"] = .null
                if type == "finished" { $0["state"] = .string("finished") }
                else { $0["pid"] = .null }
            }
        case "title":
            update(address, sequence: sequence) { $0["title"] = data["title"] }
        case "size":
            update(address, sequence: sequence) {
                $0["cols"] = data["cols"]
                $0["rows"] = data["rows"]
            }
        case "keep":
            update(address, sequence: sequence) { $0["keep"] = data["keep"] }
        default:
            break
        }
        seq = sequence
        return false
    }

    private mutating func replace(_ record: CoreJSON, address: String, sequence: UInt64) throws {
        guard record.objectValue != nil, record["address"].stringValue == address,
              record["state"].stringValue?.isEmpty == false else {
            throw CoreSnapshotError.invalidEvent
        }
        terminals[address] = record
        revisions[address] = sequence
        statusSequences.removeValue(forKey: address)
    }

    private mutating func update(
        _ address: String, sequence: UInt64,
        mutation: (inout [String: CoreJSON]) -> Void
    ) {
        guard var fields = terminals[address]?.objectValue else { return }
        mutation(&fields)
        terminals[address] = .object(fields)
        revisions[address] = sequence
    }
}
