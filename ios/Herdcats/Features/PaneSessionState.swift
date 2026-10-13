import Foundation
import Observation

/// Testable session state for a single pane: output, send, and
/// generation-safe reloads. UI binds to this from `PaneSessionView`.
@MainActor
@Observable
final class PaneSessionState {
    /// Live pane snapshot — updated when sibling polls refresh the same id.
    private(set) var pane: PaneEntry
    let connectionScope: ConnectionIdentity

    private(set) var output: String = ""
    private(set) var isLoading = false
    private(set) var isSending = false
    private(set) var errorMessage: String?

    /// Trimmed ANSI lines for the pane scroll view (no role translation).
    private(set) var outputLines: [ANSIText.Line] = []
    private(set) var outputRevision: UInt64 = 0

    private var lastParsedOutput: String?
    private var lastParsedPalette: TerminalPalette?

    private var reloadGeneration = 0

    init(pane: PaneEntry, connectionScope: ConnectionIdentity) {
        self.pane = pane
        self.connectionScope = connectionScope
    }

    var draftKey: String { PanePersistenceKeys.draft(scope: connectionScope, paneId: pane.paneId) }
    var historyKey: String { PanePersistenceKeys.history(scope: connectionScope, paneId: pane.paneId) }

    func updatePane(_ pane: PaneEntry) {
        guard pane.paneId == self.pane.paneId || pane.id == self.pane.id else { return }
        self.pane = pane
    }

    func updateParsedOutput(palette: TerminalPalette) {
        if lastParsedOutput == output,
           lastParsedPalette == palette {
            return
        }
        lastParsedOutput = output
        lastParsedPalette = palette
        outputLines = PaneOutputPresentation.trimmedLines(
            from: output,
            palette: palette
        )
        outputRevision &+= 1
    }

    func reload(_ connection: HerdrConnection) async {
        reloadGeneration += 1
        let generation = reloadGeneration
        isLoading = true
        defer {
            if reloadGeneration == generation {
                isLoading = false
            }
        }
        do {
            let text = try await connection.paneReadText(paneId: pane.paneId)
            guard reloadGeneration == generation else { return }
            output = text
            errorMessage = nil
        } catch {
            guard reloadGeneration == generation else { return }
            let message = HerdrConnection.friendlyMessage(for: error)
            if !HerdrConnection.isDisconnectionOrTransitionMessage(message) {
                errorMessage = message
            }
        }
    }

    func send(text: String, connection: HerdrConnection) async throws {
        isSending = true
        defer { isSending = false }
        try await connection.paneSubmit(
            paneId: pane.paneId,
            text: text,
            agent: pane.agent,
            status: pane.status
        )
    }
}

/// Rapid foreground pane-read pacing for Live input: after acknowledged input,
/// coalesce `pane read` calls within a short window, then back off to the
/// normal lifecycle-aware poll once typing stops. Rapid reads never run in
/// the background (`PaneRefreshPolicy` stays the fallback). Pure and
/// unit-testable without SSH; `now`/`lastReadAt`/`lastAcknowledgedAt` are
/// seconds on any monotonic clock.
enum PaneLiveRefreshPolicy {
    /// Minimum spacing between rapid reads (coalescing window).
    static let minReadInterval: TimeInterval = 0.15
    /// Acknowledged input keeps rapid reads alive for this long; once typing
    /// stops for longer, the loop idles and the five-second poll takes over.
    static let activityWindow: TimeInterval = 0.6
    /// How often the pacing loop wakes to re-evaluate.
    static let tickInterval: TimeInterval = 0.05

    static func shouldRead(
        now: TimeInterval,
        lastReadAt: TimeInterval?,
        lastAcknowledgedAt: TimeInterval?
    ) -> Bool {
        guard let lastAcknowledgedAt else { return false }
        guard now - lastAcknowledgedAt <= activityWindow else { return false }
        guard let lastReadAt else { return true }
        return now - lastReadAt >= minReadInterval
    }
}

/// Whether periodic pane polling should run a tick.
enum PaneRefreshPolicy {
    static func shouldAutoPoll(
        autoRefreshEnabled: Bool,
        isSceneActive: Bool
    ) -> Bool {
        autoRefreshEnabled && isSceneActive
    }
}

/// Pure helpers for `PaneDetailView.refreshPeersAndTabs` so selection / empty /
/// tab-order behavior stays covered without SSH.
enum PanePeerRefresh {
    enum PeersOutcome: Equatable {
        case dismiss
        case apply(peers: [PaneEntry], selectedPaneID: String)
    }

    /// Empty list → dismiss. Otherwise keep selection when still present,
    /// else fall back to the first peer.
    static func outcome(
        peers: [PaneEntry],
        selectedPaneID: String
    ) -> PeersOutcome {
        guard !peers.isEmpty else { return .dismiss }
        if peers.contains(where: { $0.id == selectedPaneID }) {
            return .apply(peers: peers, selectedPaneID: selectedPaneID)
        }
        return .apply(peers: peers, selectedPaneID: peers[0].id)
    }

    static func sortedTabs(_ tabs: [TabEntry]) -> [TabEntry] {
        tabs.sorted { $0.number < $1.number }
    }
}
