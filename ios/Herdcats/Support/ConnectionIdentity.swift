import Foundation

/// Stable identity for one runtime at a remote SSH endpoint.
///
/// Used to namespace pane drafts, command history, remote-draft markers, and
/// activity timestamps so the same Herdr pane id on two machines cannot collide.
struct ConnectionIdentity: Hashable, Sendable, Codable, Equatable {
    var host: String
    var port: Int
    var username: String
    var backend: ConnectionBackend

    init(host: String, port: Int, username: String, backend: ConnectionBackend = .tui) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.backend = backend
    }

    init(_ config: ConnectionConfig) {
        self.init(host: config.host, port: config.port, username: config.username, backend: config.backend)
    }

    /// UserDefaults-safe fragment unique for this endpoint.
    ///
    /// Username case is preserved (SSH logins are case-sensitive). Host is
    /// lowercased for DNS. Components are percent-encoded and joined with
    /// unambiguous delimiters so `@`, `:`, or `/` in a name cannot collide.
    var storageKey: String {
        let user = Self.encodeComponent(username)
        let host = Self.encodeComponent(self.host.lowercased())
        let endpoint = "u=\(user)|h=\(host)|p=\(port)"
        // Keep existing TUI draft/history keys byte-for-byte compatible.
        return backend == .tui ? endpoint : endpoint + "|b=\(backend.rawValue)"
    }

    private static let allowedComponentCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func encodeComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowedComponentCharacters) ?? value
    }
}

extension ConnectionIdentity {
    private enum CodingKeys: String, CodingKey { case host, port, username, backend }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(host: try values.decode(String.self, forKey: .host),
                  port: try values.decode(Int.self, forKey: .port),
                  username: try values.decode(String.self, forKey: .username),
                  backend: try values.decodeIfPresent(ConnectionBackend.self, forKey: .backend) ?? .tui)
    }
}

/// UserDefaults keys for per-pane local state, scoped by connection identity.
///
/// ## Legacy migration
/// Pre-scoped keys (`pane-draft.{paneId}`, `pane-history.{paneId}`,
/// and unscoped `pane-last-updated` entries) are **left untouched**. Ownership
/// of that data cannot be proven across hosts, so scoped storage starts empty.
/// Legacy values remain available for a future explicit import if a single-host
/// ownership proof is added; they are never auto-claimed into a connection
/// scope. The explicit pane privacy erasure does remove every `pane-draft.*`
/// and `pane-history.*` key, including these legacy values, while preserving
/// `pane-last-updated`.
enum PanePersistenceKeys {
    static func draft(scope: ConnectionIdentity, paneId: String) -> String {
        "pane-draft.\(scope.storageKey).\(paneId)"
    }

    static func history(scope: ConnectionIdentity, paneId: String) -> String {
        "pane-history.\(scope.storageKey).\(paneId)"
    }

    static func legacyDraft(paneId: String) -> String { "pane-draft.\(paneId)" }
}

/// Deferring helper setup is scoped to the SSH host and user, never a pane ID.
enum TimelineSetupPreference {
    static func key(scope: ConnectionIdentity) -> String {
        "timeline-setup-deferred.\(scope.storageKey)"
    }
}
