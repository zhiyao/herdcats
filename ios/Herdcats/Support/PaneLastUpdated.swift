import Foundation

/// Client-side last-activity timestamps for panes.
///
/// Herdr pane payloads expose a monotonic `revision` but no wall-clock
/// activity time, so the app records when it first observes a pane fingerprint
/// change and persists that for the switcher cards.
///
/// Records are keyed by `ConnectionIdentity.storageKey` + pane id so the same
/// Herdr pane id on two hosts cannot share timestamps. See
/// `PanePersistenceKeys` for the legacy migration policy.
enum PaneLastUpdatedStore {
    static let storageKey = "pane-last-updated"
    static let scopedStorageKey = "pane-last-updated.scoped"

    struct Record: Codable, Hashable {
        var fingerprint: String
        var updatedAt: Date
    }

    static func dates(
        scope: ConnectionIdentity,
        defaults: UserDefaults = .standard
    ) -> [String: Date] {
        loadScoped(defaults: defaults)[scope.storageKey]?.mapValues(\.updatedAt) ?? [:]
    }

    /// Syncs stored fingerprints with the latest pane snapshots.
    /// Returns the full pane-id → updated-at map after applying any changes.
    @discardableResult
    static func observe(
        _ panes: [PaneEntry],
        scope: ConnectionIdentity,
        now: Date = .now,
        defaults: UserDefaults = .standard
    ) -> [String: Date] {
        observe(
            panes.map { ($0.paneId, $0.activityFingerprint) },
            scope: scope,
            now: now,
            defaults: defaults
        )
    }

    /// Same store and fingerprint rules as panes, keyed by each agent's pane id.
    @discardableResult
    static func observe(
        _ agents: [AgentEntry],
        scope: ConnectionIdentity,
        now: Date = .now,
        defaults: UserDefaults = .standard
    ) -> [String: Date] {
        observe(
            agents.map { ($0.paneId, $0.activityFingerprint) },
            scope: scope,
            now: now,
            defaults: defaults
        )
    }

    @discardableResult
    private static func observe(
        _ items: [(paneId: String, fingerprint: String)],
        scope: ConnectionIdentity,
        now: Date,
        defaults: UserDefaults
    ) -> [String: Date] {
        // Legacy unscoped records are intentionally not claimed into this scope.
        var all = loadScoped(defaults: defaults)
        var records = all[scope.storageKey] ?? [:]
        var dirty = false

        for item in items {
            if var existing = records[item.paneId] {
                if existing.fingerprint != item.fingerprint {
                    existing.fingerprint = item.fingerprint
                    existing.updatedAt = now
                    records[item.paneId] = existing
                    dirty = true
                }
            } else {
                records[item.paneId] = Record(fingerprint: item.fingerprint, updatedAt: now)
                dirty = true
            }
        }

        if dirty {
            all[scope.storageKey] = records
            saveScoped(all, defaults: defaults)
        }
        return records.mapValues(\.updatedAt)
    }

    /// Legacy unscoped store is preserved for inspection / future explicit import.
    /// It is never auto-merged into a connection scope.

    private static var inMemoryScopedCache: [String: [String: Record]]?

    static func loadScoped(defaults: UserDefaults = .standard) -> [String: [String: Record]] {
        if defaults == .standard, let cached = inMemoryScopedCache {
            return cached
        }
        guard let data = defaults.data(forKey: scopedStorageKey),
              let decoded = try? JSONDecoder().decode([String: [String: Record]].self, from: data)
        else {
            if defaults == .standard { inMemoryScopedCache = [:] }
            return [:]
        }
        if defaults == .standard { inMemoryScopedCache = decoded }
        return decoded
    }

    static func saveScoped(_ records: [String: [String: Record]], defaults: UserDefaults = .standard) {
        if defaults == .standard {
            inMemoryScopedCache = records
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: scopedStorageKey)
    }

    static func loadLegacy(defaults: UserDefaults = .standard) -> [String: Record] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    static func saveLegacy(_ records: [String: Record], defaults: UserDefaults = .standard) {
        if records.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }


}

/// Relative labels for pane activity: time today, "Yesterday", weekday within
/// a week, otherwise a calendar date.
enum PaneUpdatedFormat {
    static func label(
        for date: Date,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return format(date, calendar: calendar, locale: locale, dateStyle: .none, timeStyle: .short)
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }

        let startNow = calendar.startOfDay(for: now)
        let startDate = calendar.startOfDay(for: date)
        let dayDistance = calendar.dateComponents([.day], from: startDate, to: startNow).day ?? Int.max

        if dayDistance >= 2 && dayDistance < 7 {
            return format(date, calendar: calendar, locale: locale, template: "EEEE")
        }

        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return format(date, calendar: calendar, locale: locale, template: "MMMd")
        }

        return format(date, calendar: calendar, locale: locale, template: "yMMMd")
    }

    private static func format(
        _ date: Date,
        calendar: Calendar,
        locale: Locale,
        dateStyle: DateFormatter.Style = .medium,
        timeStyle: DateFormatter.Style = .none,
        template: String? = nil
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        if let template {
            formatter.setLocalizedDateFormatFromTemplate(template)
        } else {
            formatter.dateStyle = dateStyle
            formatter.timeStyle = timeStyle
        }
        return formatter.string(from: date)
    }
}

extension PaneEntry {
    /// Identity of pane state used to detect activity without a server clock.
    var activityFingerprint: String {
        [
            revision.map(String.init) ?? "",
            agentStatus,
            agent ?? "",
            terminalTitleStripped ?? "",
            terminalTitle ?? ""
        ].joined(separator: "\u{1f}")
    }
}

extension AgentEntry {
    /// Same activity identity shape as panes so agent and pane cards share timestamps.
    var activityFingerprint: String {
        [
            revision.map(String.init) ?? "",
            agentStatus,
            agent,
            terminalTitleStripped ?? "",
            terminalTitle ?? ""
        ].joined(separator: "\u{1f}")
    }
}
