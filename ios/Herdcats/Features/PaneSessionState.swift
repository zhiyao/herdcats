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
    /// In-flight read guard for rapid live pacing; ignored by observation so
    /// background reads don't invalidate UI observers.
    @ObservationIgnored private(set) var isReading = false
    private(set) var isSending = false
    private(set) var errorMessage: String?

    private(set) var outputRevision: UInt64 = 0
    /// Selectable text with diff tint, rebuilt once per `outputRevision`.
    private(set) var selectableOutput = AttributedString()

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
        let outputLines = PaneOutputPresentation.trimmedLines(
            from: output,
            palette: palette
        )
        selectableOutput = PaneOutputPresentation.selectableText(from: outputLines)
        outputRevision &+= 1
    }

    /// Stores a pane read; identical text leaves `output` untouched so
    /// observers are not invalidated.
    func applyRead(_ text: String) {
        guard text != output else { return }
        output = text
    }

    func reload(_ connection: HerdrConnection) async {
        await reload { try await connection.paneReadText(paneId: self.pane.paneId) }
    }

    /// Reloads pane text using a custom reader (test seam). Only marks
    /// `isLoading = true` when output is initially empty so non-empty views
    /// avoid two redraws per read.
    func reload(read: () async throws -> String) async {
        reloadGeneration += 1
        let generation = reloadGeneration
        isReading = true
        let wasEmpty = output.isEmpty
        if wasEmpty { isLoading = true }
        defer {
            if reloadGeneration == generation {
                isLoading = false
                isReading = false
            }
        }
        do {
            let text = try await read()
            guard reloadGeneration == generation else { return }
            applyRead(text)
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
        lastAcknowledgedAt: TimeInterval?,
        isFocused: Bool
    ) -> Bool {
        // Only the focused pane owns Live input; an output-only pane in a
        // split keeps the normal lifecycle poll and nothing faster.
        guard isFocused else { return false }
        guard let lastAcknowledgedAt else { return false }
        guard now - lastAcknowledgedAt <= activityWindow else { return false }
        guard let lastReadAt else { return true }
        return now - lastReadAt >= minReadInterval
    }
}

/// What a split slot gaining or losing focus means for its pane. Pure, so the
/// teardown rules stay covered without a view.
enum PaneFocusPolicy {
    struct Effects: Equatable {
        /// Resign the keyboard, end the Live session, and stop dictation.
        let releasesInput: Bool
        /// The pane may now run its implicit Done → Idle mark.
        let marksSeen: Bool
    }

    static func effects(wasFocused: Bool, isFocused: Bool) -> Effects {
        Effects(releasesInput: wasFocused && !isFocused, marksSeen: !wasFocused && isFocused)
    }

    /// How long after a slot put its keyboard away the other slot may still
    /// take it over.
    static let keyboardHandoffWindow: TimeInterval = 1.5

    /// A slot that lost focus with its keyboard up leaves a handoff stamp. The
    /// slot that gains focus raises its own keyboard when the stamp is fresh,
    /// so the old one slides down and the new one slides up.
    static func takesOverKeyboard(handoffAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let handoffAt else { return false }
        return now - handoffAt <= keyboardHandoffWindow
    }

    enum DictationTeardown: Equatable {
        /// Recording: cancel and restore the draft from before the recording.
        case cancelRecording
        /// Draining after recording: complete as failed so nothing is sent.
        case interrupt
        case none
    }

    static func dictationTeardown(isRecording: Bool, isBusy: Bool) -> DictationTeardown {
        if isRecording { return .cancelRecording }
        return isBusy ? .interrupt : .none
    }

    /// The automatic Done → Idle mark runs for the focused pane only, once per visit.
    static func shouldImplicitlyMarkSeen(
        isImplicitPreference: Bool,
        isDone: Bool,
        isFocused: Bool,
        alreadyMarked: Bool
    ) -> Bool {
        isImplicitPreference && isDone && isFocused && !alreadyMarked
    }
}

/// Whether periodic pane polling should run a tick.
enum PaneRefreshPolicy {
    static let terminalPollInterval: TimeInterval = 5

    static func shouldAutoPoll(
        autoRefreshEnabled: Bool,
        isSceneActive: Bool
    ) -> Bool {
        autoRefreshEnabled && isSceneActive
    }

    static func shouldRunTerminalInitialRead(
        showsTimeline: Bool,
        isSceneActive: Bool,
        isOffline: Bool = false
    ) -> Bool {
        !showsTimeline && isSceneActive && !isOffline
    }

    static func shouldPollTerminal(
        showsTimeline: Bool,
        autoRefreshEnabled: Bool,
        isSceneActive: Bool,
        isOffline: Bool = false
    ) -> Bool {
        !showsTimeline && autoRefreshEnabled && isSceneActive && !isOffline
    }

    static func shouldPrepareLiveSession(
        showsTimeline: Bool,
        isFocused: Bool,
        isSceneActive: Bool,
        isOffline: Bool = false
    ) -> Bool {
        !showsTimeline && isFocused && isSceneActive && !isOffline
    }

    static func shouldParseTerminalOutput(showsTimeline: Bool) -> Bool {
        !showsTimeline
    }
}

struct TerminalRefreshTaskKey: Equatable {
    let paneId: String
    let showsTimeline: Bool
    let isSceneActive: Bool
    let isOffline: Bool
    let autoRefreshEnabled: Bool
}

/// Deterministic terminal snapshot + polling loop shared by `PaneSessionView`
/// and unit tests. While Timeline is visible, hidden terminal output is never
/// read or sleep-polled by this runner.
@MainActor
struct PaneTerminalPollingRunner {
    let key: TerminalRefreshTaskKey
    let currentKey: () -> TerminalRefreshTaskKey
    let needsInitialRead: Bool
    let markInitialReadDone: () -> Void
    let reloadAndParse: () async -> Void
    let sleep: (TimeInterval) async throws -> Void

    private var isCurrent: Bool { key == currentKey() }

    func run() async {
        guard !Task.isCancelled,
              isCurrent,
              PaneRefreshPolicy.shouldRunTerminalInitialRead(
                  showsTimeline: key.showsTimeline,
                  isSceneActive: key.isSceneActive,
                  isOffline: key.isOffline
              ) else { return }

        if needsInitialRead || key.autoRefreshEnabled {
            markInitialReadDone()
            await reloadAndParse()
        }

        guard key.autoRefreshEnabled else { return }

        while !Task.isCancelled {
            do {
                try await sleep(PaneRefreshPolicy.terminalPollInterval)
            } catch {
                return
            }
            let latest = currentKey()
            guard !Task.isCancelled,
                  latest == key,
                  PaneRefreshPolicy.shouldPollTerminal(
                      showsTimeline: latest.showsTimeline,
                      autoRefreshEnabled: latest.autoRefreshEnabled,
                      isSceneActive: latest.isSceneActive,
                      isOffline: latest.isOffline
                  ) else { return }
            await reloadAndParse()
        }
    }
}

/// Deterministic Live session acquisition loop shared by `PaneSessionView`
/// and unit tests. Enforces visibility, barrier-then-read ordering, and
/// cancellation-safe retirement of prepared tokens/shells.
@MainActor
struct PaneLiveSessionRunner {
    let targetPaneId: String
    let isEligible: () -> Bool
    let isEnabled: () -> Bool
    let needsResyncOrMissingSession: () -> Bool
    let retireCurrentSession: () -> Void
    let beginLiveInput: (String) async throws -> PaneLiveInputSession
    let endLiveInput: (PaneLiveInputSession) async -> Void
    let reloadPostBarrier: () async -> String?
    let installSession: (PaneLiveInputSession) -> Void
    let noteTimeout: () -> Void
    let sleep: (TimeInterval) async throws -> Void

    func run() async {
        var retryDelay = 2.0
        while !Task.isCancelled && isEligible() {
            guard !isEnabled() else { return }
            if needsResyncOrMissingSession() {
                await acquireOnce()
                retryDelay = isEnabled() ? 2 : min(retryDelay * 2, 10)
            }
            guard !Task.isCancelled, isEligible(), !isEnabled() else { return }
            do {
                try await sleep(retryDelay)
            } catch {
                return
            }
        }
    }

    func acquireOnce() async {
        guard !Task.isCancelled, isEligible() else { return }
        retireCurrentSession()
        do {
            let token = try await beginLiveInput(targetPaneId)
            var installed = false
            defer {
                if !installed {
                    Task { await endLiveInput(token) }
                }
            }
            guard !Task.isCancelled, isEligible() else {
                await Task { await endLiveInput(token) }.value
                installed = true
                return
            }
            let errorMessage = await reloadPostBarrier()
            guard !Task.isCancelled, isEligible() else {
                await Task { await endLiveInput(token) }.value
                installed = true
                return
            }
            if let errorMessage {
                if errorMessage.contains("Timed out") {
                    noteTimeout()
                }
                await Task { await endLiveInput(token) }.value
                installed = true
                return
            }
            installSession(token)
            installed = true
        } catch {
            retireCurrentSession()
        }
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
