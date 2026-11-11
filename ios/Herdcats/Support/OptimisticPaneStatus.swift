import Foundation
import Observation

/// Shows a pane as `working` the moment the user submits a prompt, before the
/// next pane refresh reports it. The override only bridges the server round
/// trip:
/// - The server confirms the prompt by reporting `working`. From then on the
///   authoritative status is shown, so a later completion is never masked.
/// - `blocked` replaces it immediately.
/// - `done` after a non-done baseline is the turn finishing between polls, so
///   it also retires the override.
/// - Other statuses (a pending done→idle acknowledgement, a refresh taken
///   before the agent started) do not confirm the prompt, so they leave it in
///   place.
/// - Snapshots older than the submission, or older than one already seen
///   (split panes refresh independently), are ignored by revision.
/// - A failed submission withdraws it, and it expires on its own so a prompt
///   that never starts cannot leave the pane stuck "working". Expiry mutates
///   observable state, so views redraw without waiting for another refresh.
@MainActor @Observable final class OptimisticPaneStatus {
    /// How long a submission may stay unconfirmed before the pane list wins.
    static let grace: TimeInterval = 15

    private struct Entry {
        let token: UUID
        /// The last non-working status accepted; a later `done` is a new completion.
        var base: AgentStatus
        let baseRevision: UInt64?
        let expires: Date
        var lastRevision: UInt64?
        var confirmed = false
        /// The newest revision this entry has accounted for.
        var seen: UInt64? { lastRevision ?? baseRevision }
    }
    private var entries: [String: Entry] = [:]
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: (TimeInterval) async -> Void

    init(
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    /// Marks `pane` working. Returns a token for `withdraw`, or nil when no
    /// override applies (not an agent pane, or already working/blocked).
    @discardableResult
    func begin(for pane: PaneEntry) -> UUID? {
        guard pane.agent != nil, pane.status != .working, pane.status != .blocked else { return nil }
        let token = UUID()
        let paneId = pane.paneId
        entries[paneId] = Entry(token: token, base: pane.status, baseRevision: pane.revision, expires: now().addingTimeInterval(Self.grace))
        timers[paneId]?.cancel()
        timers[paneId] = Task { [weak self, sleep] in
            // The deadline is wall-clock; if the clock moved back the sleep can
            // end early, so keep waiting until it has really passed.
            while let remaining = self?.remaining(paneId: paneId, token: token), remaining > 0 {
                await sleep(remaining)
                guard !Task.isCancelled else { return }
            }
            self?.expire(paneId: paneId, token: token)
        }
        return token
    }

    /// Drops the override after a failed submission, unless a newer one replaced it.
    func withdraw(paneId: String, token: UUID) {
        if entries[paneId]?.token == token { remove(paneId) }
    }

    /// The status to show for `pane`. Pure: it reads, never mutates.
    func status(for pane: PaneEntry) -> AgentStatus {
        guard let entry = entries[pane.paneId], now() < entry.expires else { return pane.status }
        let fresh = pane.revision.map { $0 > (entry.seen ?? 0) } ?? false
        // A snapshot older than the submission, or than one already accounted
        // for, says nothing about the prompt: reconcile ignores it, so show it
        // no differently.
        if let r = pane.revision, let seen = entry.seen, r < seen { return .working }
        // Once confirmed, another consumer's older snapshot must not leak through.
        if entry.confirmed { return fresh ? pane.status : .working }
        if pane.status == .blocked { return pane.status }
        if pane.status == .done && entry.base != .done { return pane.status }
        return .working
    }

    /// Feeds an authoritative status. Call for every refreshed pane, not just
    /// the one on screen.
    func reconcile(paneId: String, status: AgentStatus, revision: UInt64? = nil) {
        guard var entry = entries[paneId] else { return }
        if let revision {
            if let seen = entry.seen, revision < seen { return }
            entry.lastRevision = revision
            entries[paneId] = entry
        }
        switch status {
        case .working:
            entry.confirmed = true
            entries[paneId] = entry
        case .blocked:
            remove(paneId)
        default:
            // Once working was observed, any other status is the turn ending.
            // A fresh done also means a turn ran, even if no poll saw it working.
            if entry.confirmed || (status == .done && entry.base != .done) {
                remove(paneId)
            } else if status != entry.base {
                // E.g. a pending done→idle acknowledgement: remember it, so a
                // later done is recognised as the submitted turn finishing.
                entry.base = status
                entries[paneId] = entry
            }
        }
    }

    func reconcile(_ panes: [PaneEntry]) {
        for pane in panes { reconcile(paneId: pane.paneId, status: pane.status, revision: pane.revision) }
    }

    /// Awaitable handle on a pane's expiry timer, for tests.
    func expiryTask(for paneId: String) -> Task<Void, Never>? { timers[paneId] }

    private func remaining(paneId: String, token: UUID) -> TimeInterval? {
        guard let entry = entries[paneId], entry.token == token else { return nil }
        return max(0, entry.expires.timeIntervalSince(now()))
    }

    /// Forgets every override, e.g. when the connection changes and pane ids
    /// may name different panes.
    func reset() {
        entries = [:]
        timers.values.forEach { $0.cancel() }
        timers = [:]
    }

    private func expire(paneId: String, token: UUID) {
        guard let entry = entries[paneId], entry.token == token, now() >= entry.expires else { return }
        remove(paneId)
    }

    private func remove(_ paneId: String) {
        entries[paneId] = nil
        timers[paneId]?.cancel()
        timers[paneId] = nil
    }
}
