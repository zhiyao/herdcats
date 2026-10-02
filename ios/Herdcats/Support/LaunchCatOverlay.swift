import Foundation

enum LaunchCatOverlay {
    static func shouldShow(
        hasActiveSession: Bool,
        phase: AppModel.Phase,
        hasHandedOff: Bool
    ) -> Bool {
        guard hasActiveSession, !hasHandedOff else { return false }
        switch phase {
        case .connecting, .disconnected:
            return true
        case .connected, .offline:
            return false
        }
    }

    static func message(phase: AppModel.Phase) -> String {
        if case .connecting = phase { return "Connecting…" }
        return "Starting…"
    }
}
