import Foundation
import Observation

enum PaneCommandHistory {
    static let maxEntries = 50

    static func load(from raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let items = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return items
    }

    static func encode(_ items: [String]) -> String {
        guard let data = try? JSONEncoder().encode(items),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    static func record(_ text: String, into raw: inout String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var items = load(from: raw)
        items.removeAll { $0 == trimmed }
        items.insert(trimmed, at: 0)
        if items.count > maxEntries {
            items = Array(items.prefix(maxEntries))
        }
        raw = encode(items)
    }
}

/// Synchronous gate and store for pane text. Revision tokens prevent a pane
/// view that predates erasure from writing its cached value back afterward.
@MainActor @Observable
final class PaneContentPersistence {
    static let enabledKey = "pane-content-saving-enabled"
    static let shared = PaneContentPersistence(defaults: .standard)

    private let defaults: UserDefaults
    private(set) var revision: UInt64 = 0
    private(set) var isEnabled: Bool

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        eraseSavedContent()
        defaults.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled
    }

    /// Removes scoped and legacy pane drafts/history, across all machines.
    /// Pane-last-updated and unrelated preferences are deliberately retained.
    func eraseSavedContent() {
        revision &+= 1
        for key in defaults.dictionaryRepresentation().keys where
            key.hasPrefix("pane-draft.") || key.hasPrefix("pane-history.") {
            defaults.removeObject(forKey: key)
        }
    }

    func loadDraft(key: String) -> String {
        guard isEnabled else { return "" }
        return defaults.string(forKey: key) ?? ""
    }

    func loadHistory(key: String) -> [String] {
        guard isEnabled else { return [] }
        return PaneCommandHistory.load(from: defaults.string(forKey: key) ?? "[]")
    }

    @discardableResult
    func saveDraft(_ value: String, key: String, revision expectedRevision: UInt64) -> Bool {
        guard isEnabled, revision == expectedRevision else { return false }
        if value.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(value, forKey: key)
        }
        return true
    }

    @discardableResult
    func record(_ value: String, key: String, revision expectedRevision: UInt64) -> Bool {
        guard isEnabled, revision == expectedRevision,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var raw = defaults.string(forKey: key) ?? "[]"
        PaneCommandHistory.record(value, into: &raw)
        defaults.set(raw, forKey: key)
        return true
    }
}
