import Foundation
import Observation
import Testing
@testable import Herdcats

@MainActor
struct OptimisticPaneStatusTests {
    private func pane(_ status: String, agent: String? = "codex", id: String = "p1", revision: UInt64? = nil) -> PaneEntry {
        let json = """
        {"pane_id":"\(id)","tab_id":"t","workspace_id":"w","agent":\(agent.map { "\"\($0)\"" } ?? "null"),\
        "agent_status":"\(status)","focused":false\(revision.map { ",\"revision\":\($0)" } ?? "")}
        """
        return try! JSONDecoder().decode(PaneEntry.self, from: Data(json.utf8))
    }

    /// Time is driven by `clock`; a store's sleeps return at once and advance
    /// it by the requested amount unless `advances` is false.
    private final class Clock { var date = Date(timeIntervalSince1970: 1_000) }
    private func makeStore(_ clock: Clock = Clock(), advances: Bool = true) -> OptimisticPaneStatus {
        OptimisticPaneStatus(now: { clock.date }, sleep: { if advances { clock.date += $0 } else { await Task.yield() } })
    }

    @Test func showsWorkingImmediatelyOnSubmit() {
        let store = makeStore()
        let idle = pane("idle")
        #expect(store.status(for: idle) == .idle)
        #expect(store.begin(for: idle) != nil)
        #expect(store.status(for: idle) == .working)
    }

    @Test func confirmedWorkingThenCompletionIsNotMasked() {
        let store = makeStore()
        store.begin(for: pane("done"))
        store.reconcile([pane("working")])
        #expect(store.status(for: pane("working")) == .working)
        // Fast completion back to the submission baseline must show through.
        store.reconcile([pane("done")])
        #expect(store.status(for: pane("done")) == .done)
    }

    @Test func fastCompletionMissedByPollingShowsDone() {
        let store = makeStore()
        store.begin(for: pane("idle"))
        // No poll ever saw working; the turn finished between polls.
        #expect(store.status(for: pane("done")) == .done)
        store.reconcile([pane("done")])
        #expect(store.status(for: pane("idle")) == .idle)
    }

    @Test func resetForgetsOverridesAcrossConnections() {
        let store = makeStore()
        store.begin(for: pane("idle"))
        store.reset()
        #expect(store.status(for: pane("idle")) == .idle)
    }

    @Test func timerWakingBeforeDeadlineKeepsWaiting() async {
        // Clock moved backward: the first wake is early, expiry must still happen.
        let clock = Clock()
        var wakes = 0
        let store = OptimisticPaneStatus(now: { clock.date }, sleep: { _ in
            wakes += 1
            if wakes == 2 { clock.date += OptimisticPaneStatus.grace + 1 }
        })
        store.begin(for: pane("idle"))
        await store.expiryTask(for: "p1")?.value
        #expect(wakes == 2)
        #expect(store.status(for: pane("idle")) == .idle)
    }

    @Test func olderSnapshotFromAnotherConsumerIsIgnoredAfterConfirmation() {
        let store = makeStore()
        store.begin(for: pane("idle", revision: 10))
        store.reconcile([pane("working", revision: 12)])
        // A split pane's delayed refresh, taken before the prompt, still says idle.
        store.reconcile([pane("idle", revision: 9)])
        #expect(store.status(for: pane("idle", revision: 9)) == .working)
        // So does one taken after the submission but before the working report.
        store.reconcile([pane("idle", revision: 11)])
        #expect(store.status(for: pane("idle", revision: 11)) == .working)
        // A newer snapshot is authoritative and retires the entry.
        #expect(store.status(for: pane("done", revision: 13)) == .done)
        store.reconcile([pane("done", revision: 13)])
        #expect(store.status(for: pane("done", revision: 13)) == .done)
    }

    @Test func staleBlockedOrDoneBeforeConfirmationIsNotShown() {
        let store = makeStore()
        store.begin(for: pane("idle", revision: 10))
        store.reconcile([pane("idle", revision: 12)])
        #expect(store.status(for: pane("blocked", revision: 11)) == .working)
        #expect(store.status(for: pane("done", revision: 11)) == .working)
        #expect(store.status(for: pane("done", revision: 13)) == .done)
    }

    @Test func fastCompletionAfterDoneToIdleAcknowledgementShowsDone() {
        let store = makeStore()
        store.begin(for: pane("done", revision: 10))
        store.reconcile([pane("idle", revision: 11)])
        #expect(store.status(for: pane("idle", revision: 11)) == .working)
        // The working state was never polled; the turn finished.
        #expect(store.status(for: pane("done", revision: 13)) == .done)
        store.reconcile([pane("done", revision: 13)])
        #expect(store.status(for: pane("idle", revision: 14)) == .idle)
    }

    @Test func snapshotOlderThanSubmissionNeverRetiresIt() {
        let store = makeStore()
        store.begin(for: pane("idle", revision: 10))
        store.reconcile([pane("done", revision: 8)])
        #expect(store.status(for: pane("done", revision: 8)) == .working)
        store.reconcile([pane("done", revision: 11)])
        #expect(store.status(for: pane("done", revision: 11)) == .done)
    }

    @Test func blockedReplacesImmediately() {
        let store = makeStore()
        store.begin(for: pane("idle"))
        #expect(store.status(for: pane("blocked")) == .blocked)
        store.reconcile([pane("blocked")])
        #expect(store.status(for: pane("idle")) == .idle)
    }

    @Test func pendingMarkSeenAcknowledgementDoesNotCancelNewPrompt() {
        let store = makeStore()
        // Opened a Done pane, then sent before the done→idle refresh landed.
        store.begin(for: pane("done"))
        store.reconcile([pane("idle")])
        #expect(store.status(for: pane("idle")) == .working)
        store.reconcile([pane("working")])
        store.reconcile([pane("idle")])
        #expect(store.status(for: pane("idle")) == .idle)
    }

    @Test func staleIdleRefreshKeepsWorking() {
        let store = makeStore()
        store.begin(for: pane("idle"))
        store.reconcile([pane("idle")])
        #expect(store.status(for: pane("idle")) == .working)
    }

    @Test func failureWithdrawsOnlyOwnOverride() {
        let store = makeStore()
        let first = store.begin(for: pane("idle"))!
        let second = store.begin(for: pane("idle"))!
        store.withdraw(paneId: "p1", token: first)
        #expect(store.status(for: pane("idle")) == .working)
        store.withdraw(paneId: "p1", token: second)
        #expect(store.status(for: pane("idle")) == .idle)
    }

    @Test func expiryInvalidatesObservers() async {
        let clock = Clock()
        let store = makeStore(clock)
        store.begin(for: pane("idle"))
        var invalidated = false
        withObservationTracking {
            _ = store.status(for: pane("idle"))
        } onChange: { invalidated = true }
        await store.expiryTask(for: "p1")?.value
        #expect(invalidated)
        #expect(store.status(for: pane("idle")) == .idle)
    }

    @Test func staleTimerDoesNotExpireNewerSubmission() async {
        let clock = Clock()
        let store = makeStore(clock, advances: false)
        store.begin(for: pane("idle"))
        let firstTimer = store.expiryTask(for: "p1")
        store.begin(for: pane("idle"))
        await firstTimer?.value
        #expect(store.status(for: pane("idle")) == .working)
        store.reset() // stops the second timer, which never reaches its deadline here
    }

    @Test func ignoresShellPanesAndAlreadyBusyPanes() {
        let store = makeStore()
        #expect(store.begin(for: pane("idle", agent: nil)) == nil)
        #expect(store.begin(for: pane("working")) == nil)
        #expect(store.begin(for: pane("blocked")) == nil)
    }

    @Test func overridesArePerPane() {
        let store = makeStore()
        store.begin(for: pane("idle", id: "a"))
        #expect(store.status(for: pane("idle", id: "b")) == .idle)
    }

    @Test func appModelResetsOverridesWhenTransportGenerationChanges() {
        let app = AppModel()
        let token = app.ownership.beginAttempt()
        _ = app.ownership.associateReserved(ConnectionGeneration(rawValue: 1), for: token)
        app.optimisticPaneStatus.begin(for: pane("idle", revision: 10))
        // Same endpoint reconnects on a new transport; revisions may restart lower.
        let next = app.ownership.beginAttempt()
        _ = app.ownership.associateReserved(ConnectionGeneration(rawValue: 2), for: next)
        #expect(app.optimisticPaneStatus.status(for: pane("done", revision: 3)) == .done)
    }
}
