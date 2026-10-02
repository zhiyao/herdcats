import AudioToolbox
import Foundation

// MARK: - Alert events

/// An agent status change worth announcing with a sound.
enum AgentAlertEvent: Hashable {
    /// An agent finished its turn.
    case done
    /// An agent is waiting on input.
    case blocked
}

enum AgentStatusAlerts {
    /// Pane-id → status map used as the baseline for the next comparison.
    static func snapshot(_ agents: [AgentEntry]) -> [String: AgentStatus] {
        Dictionary(
            agents.map { ($0.paneId, AgentStatus(rawValue: $0.agentStatus) ?? .unknown) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    /// The event to announce after a refresh, or `nil` when nothing changed.
    ///
    /// A `nil` baseline (first load after connecting) never alerts, and agents
    /// absent from the baseline are treated as new rather than transitioned.
    /// Blocked outranks done so one refresh plays at most one sound.
    static func event(
        previous: [String: AgentStatus]?,
        current: [AgentEntry]
    ) -> AgentAlertEvent? {
        guard let previous else { return nil }
        var sawDone = false
        for agent in current {
            guard let before = previous[agent.paneId] else { continue }
            let now = AgentStatus(rawValue: agent.agentStatus) ?? .unknown
            if now == .blocked, before != .blocked {
                return .blocked
            }
            // Herdr reports `idle` instead of `done` when the pane is already
            // being looked at, so working → idle also counts as finishing.
            if (now == .done && before != .done) || (now == .idle && before == .working) {
                sawDone = true
            }
        }
        return sawDone ? .done : nil
    }
}

// MARK: - Alert sound preference

/// Sound played for an agent alert. Persisted via `@AppStorage` using `rawValue`.
enum AgentAlertSound: String, CaseIterable, Identifiable {
    case off
    case triTone
    case chime
    case glass
    case horn
    case bell
    case electronic
    case anticipate
    case bloom
    case fanfare
    case ladder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "None"
        case .triTone: "Tri-tone"
        case .chime: "Chime"
        case .glass: "Glass"
        case .horn: "Horn"
        case .bell: "Bell"
        case .electronic: "Electronic"
        case .anticipate: "Anticipate"
        case .bloom: "Bloom"
        case .fanfare: "Fanfare"
        case .ladder: "Ladder"
        }
    }

    /// Built-in iOS alert tone; `nil` for `.off`.
    var systemSoundID: SystemSoundID? {
        switch self {
        case .off: nil
        case .triTone: 1007
        case .chime: 1008
        case .glass: 1009
        case .horn: 1010
        case .bell: 1011
        case .electronic: 1012
        case .anticipate: 1020
        case .bloom: 1021
        case .fanfare: 1025
        case .ladder: 1026
        }
    }

    /// Plays the tone. System sounds respect the Ring/Silent switch.
    func play() {
        guard let systemSoundID else { return }
        AudioServicesPlaySystemSound(systemSoundID)
    }

    static let doneStorageKey = "agentDoneSound"
    static let blockedStorageKey = "agentBlockedSound"
    static let defaultDone: AgentAlertSound = .chime
    static let defaultBlocked: AgentAlertSound = .triTone

    static func storageKey(for event: AgentAlertEvent) -> String {
        switch event {
        case .done: doneStorageKey
        case .blocked: blockedStorageKey
        }
    }

    static func `default`(for event: AgentAlertEvent) -> AgentAlertSound {
        switch event {
        case .done: defaultDone
        case .blocked: defaultBlocked
        }
    }

    /// The user's chosen sound for `event`.
    static func selected(
        for event: AgentAlertEvent,
        defaults: UserDefaults = .standard
    ) -> AgentAlertSound {
        defaults.string(forKey: storageKey(for: event))
            .flatMap(AgentAlertSound.init(rawValue:))
            ?? .default(for: event)
    }
}
