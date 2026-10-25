import SwiftUI

/// Identifies the card that initiated a reorder so it can draw over its neighbors.
struct ReorderingCard: Equatable {
    let id: String
    let priorityKey: String

    static func movingID(from old: [Self], to new: [Self]) -> String? {
        let oldIDs = Set(old.map(\.id))
        let newIDs = Set(new.map(\.id))
        guard old.map(\.id).filter(newIDs.contains) != new.map(\.id).filter(oldIDs.contains) else {
            return nil
        }
        let oldPositions = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($0.element.id, $0.offset) })
        let oldKeys = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0.priorityKey) })
        let candidates = new.enumerated().compactMap { index, card -> (id: String, distance: Int, changed: Bool, index: Int)? in
            guard let oldIndex = oldPositions[card.id], oldIndex != index else { return nil }
            return (card.id, abs(oldIndex - index), oldKeys[card.id] != card.priorityKey, index)
        }
        return candidates.max {
            if $0.changed != $1.changed { return !$0.changed }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.index > $1.index
        }?.id
    }
}

// MARK: - Appearance preference

/// User-selected app appearance. Persisted via `@AppStorage` using `rawValue`.
enum AppearancePreference: String, CaseIterable, Identifiable {
    /// Follow the device's light / dark setting.
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    /// `nil` means follow the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static let storageKey = "appearancePreference"
    static let `default`: AppearancePreference = .dark
}

/// What to show when the app launches while disconnected.
enum LaunchPreference: String, CaseIterable, Identifiable {
    /// Show the recent-connections selection screen.
    case connectionSelection
    /// Connect immediately using the last-used remembered connection.
    case autoConnect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connectionSelection: "Connection List"
        case .autoConnect: "Auto-connect"
        }
    }

    var systemImage: String {
        switch self {
        case .connectionSelection: "rectangle.stack"
        case .autoConnect: "bolt.horizontal.circle"
        }
    }

    static let storageKey = "launchPreference"
    static let `default`: LaunchPreference = .connectionSelection

    /// Builds a config for the last-used remembered connection, if credentials exist.
    static func autoConnectConfig(
        defaults: UserDefaults = .standard,
        keychain: KeychainOperations = KeychainStore.operations
    ) -> ConnectionConfig? {
        let raw = defaults.string(forKey: storageKey) ?? LaunchPreference.default.rawValue
        guard LaunchPreference(rawValue: raw) == .autoConnect else { return nil }

        let entries = (try? RecentConnectionStore.load(defaults: defaults, using: keychain)) ?? []
        let remembered = entries.enumerated().filter { $0.element.remember }.sorted { lhs, rhs in
            switch (lhs.element.lastConnectedAt, rhs.element.lastConnectedAt) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }
        guard let entry = remembered.first?.element else { return nil }
        return RecentConnectionStore.config(for: entry, using: keychain)
    }
}

/// Whether pane detail keeps its Compose field visible when idle.
enum PaneComposePreference {
    static let storageKey = "paneShowComposeByDefault"
    static let `default` = true
}

/// Monospaced pane output size. Persisted via `@AppStorage` using `rawValue`.
enum PaneTextSizePreference: String, CaseIterable, Identifiable {
    case small
    case medium
    case large
    case extraLarge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        case .extraLarge: "XL"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    /// Point size for terminal / agent output (medium matches the historical default of 11).
    var pointSize: CGFloat {
        switch self {
        case .small: 9
        case .medium: 11
        case .large: 14
        case .extraLarge: 17
        }
    }

    var outputFont: Font {
        .system(size: pointSize, design: .monospaced)
    }

    /// Versioned because the case names shifted when `small` (9pt) was added;
    /// the old key's `small` meant 11pt, so old selections reset to the default.
    static let storageKey = "paneTextSizePreference.v2"
    static let `default`: PaneTextSizePreference = .medium
}

/// How a pane's output scroll view behaves when new agent output arrives.
/// Persisted via `@AppStorage` using `rawValue`.
enum PaneScrollBehaviorPreference: String, CaseIterable, Identifiable {
    /// Keep the reader where they are; only pin to the newest output on first
    /// load and right after the user sends input.
    case holdPosition
    /// Scroll to the newest output every time the agent responds.
    case followOutput

    var id: String { rawValue }

    var title: String {
        switch self {
        case .holdPosition: "Stay put"
        case .followOutput: "Jump to end"
        }
    }

    var systemImage: String {
        switch self {
        case .holdPosition: "hand.raised"
        case .followOutput: "arrow.down.to.line"
        }
    }

    var detail: String {
        switch self {
        case .holdPosition: "Maintain current scroll position."
        case .followOutput: "Automatically scroll to newest output."
        }
    }

    static let storageKey = "paneScrollBehaviorPreference"
    static let `default`: PaneScrollBehaviorPreference = .holdPosition
}

/// How opening a Done pane on iPhone clears that status to Idle.
/// Herdr treats Done as idle work that nobody has marked seen yet; focusing
/// the agent or its tab on the remote machine is what clears it.
enum DoneClearPreference: String, CaseIterable, Identifiable {
    /// Show a mark-as-read control; viewing alone leaves Done unchanged.
    case explicit
    /// Focus the agent when the pane opens so Done clears automatically.
    case implicit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explicit: "Manually"
        case .implicit: "When opened"
        }
    }

    var systemImage: String {
        switch self {
        case .explicit: "hand.tap"
        case .implicit: "eye"
        }
    }

    var detail: String {
        switch self {
        case .explicit:
            "Keeps Done until marked manually. Does not focus the remote machine."
        case .implicit:
            "Focuses the agent on the remote machine when opened, clearing Done."
        }
    }

    static let storageKey = "doneClearPreference"
    static let `default`: DoneClearPreference = .explicit

    static func load(from defaults: UserDefaults = .standard) -> DoneClearPreference {
        guard let raw = defaults.string(forKey: storageKey) else { return .default }
        return DoneClearPreference(rawValue: raw) ?? .default
    }
}

// MARK: - Agents list preferences

/// How the Agents screen orders its list. Mirrors herdr's
/// `agent_panel_sort` values: `priority` (flat attention queue) or `spaces`
/// (grouped by space, spaces in workspace order).
enum AgentsSortPreference: String, CaseIterable, Identifiable {
    /// Flat attention queue: blocked, done, working, idle, unknown.
    case priority
    /// Grouped by space.
    case spaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .priority: "By priority"
        case .spaces: "By space"
        }
    }

    var systemImage: String {
        switch self {
        case .priority: "exclamationmark.circle"
        case .spaces: "square.grid.3x3"
        }
    }

    static let storageKey = "agentsSortPreference"
    static let `default`: AgentsSortPreference = .priority
}

/// How the Spaces screen orders its workspace cards.
enum SpaceSortPreference: String, CaseIterable, Identifiable {
    /// Preserve Herdr's workspace-number order.
    case workspaceOrder
    /// Put the most attention-worthy space groups first.
    case priority

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspaceOrder: "Default"
        case .priority: "By priority"
        }
    }

    var systemImage: String {
        switch self {
        case .workspaceOrder: "list.number"
        case .priority: "exclamationmark.circle"
        }
    }

    static let storageKey = "spacesSortPreference"
    static let `default`: SpaceSortPreference = .workspaceOrder
}

// MARK: - Usage / quota preferences

/// Order of provider cards on the Quota tab. Rings use the hybrid
/// scale in `Theme.quotaColor` (pace above 40%, urgency below).
enum QuotaOrderPreference: String, CaseIterable, Identifiable {
    /// Cards whose quota runs out soonest at the current burn rate come first.
    case runsOutFirst
    /// Cards sorted by provider name.
    case alphabetical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runsOutFirst: "Runs Out First"
        case .alphabetical: "A–Z"
        }
    }

    var systemImage: String {
        switch self {
        case .runsOutFirst: "hourglass"
        case .alphabetical: "textformat"
        }
    }

    /// Cards in display order. Ties keep the incoming order.
    func ordered(_ cards: [AgentUsageCard], now: Date = .now) -> [AgentUsageCard] {
        let indexed = Array(cards.enumerated())
        switch self {
        case .runsOutFirst:
            return indexed.sorted { lhs, rhs in
                let l = lhs.element.depletionRank(now: now)
                let r = rhs.element.depletionRank(now: now)
                if l.tier != r.tier { return l.tier < r.tier }
                if l.value != r.value { return l.value < r.value }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        case .alphabetical:
            return indexed.sorted { lhs, rhs in
                let order = lhs.element.displayTitle.localizedCaseInsensitiveCompare(rhs.element.displayTitle)
                return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
            }
            .map(\.element)
        }
    }

    static let storageKey = "quotaOrderPreference"
    static let `default`: QuotaOrderPreference = .runsOutFirst
}

extension AgentUsageCard {
    /// Card title on the Quota tab.
    var displayTitle: String {
        switch provider {
        case "agy": "Agy"
        case "agy-claude": "Agy·C"
        case "zai": "ZAI"
        case "alibaba": "Alibaba"
        case "copilot": "Copilot"
        case "opencode-go": "OpenCode"
        case "kimi": "Kimi"
        case "grok": "Grok"
        default: AgentKindVisual.displayName(for: provider)
        }
    }
}
