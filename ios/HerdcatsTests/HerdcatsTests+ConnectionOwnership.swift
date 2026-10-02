import Foundation
import Security
import NIOSSH
import SwiftUI
import Testing
@testable import Herdcats

@Suite("Bounded timeout race")
struct BoundedTimeoutTests {
    @Test func immediateSuccessDoesNotLateTeardownAfterDeadline() async throws {
        let teardowns = Counter()
        let value = try await withTimeout(
            seconds: 0.15,
            label: "fast",
            onTimeout: { await teardowns.increment() },
            operation: { 7 }
        )
        #expect(value == 7)
        try await Task.sleep(for: .milliseconds(250))
        #expect(await teardowns.value == 0)
    }

    @Test func timeoutClaimsBeforeTeardownAndBeatsLateResult() async throws {
        let park = ExternallyReleasedWait<Int>()
        let teardowns = Counter()
        let order = EventLog()

        let task = Task {
            try await withTimeout(
                seconds: 0.05,
                label: "parked",
                onTimeout: {
                    await order.append("teardown")
                    await teardowns.increment()
                },
                operation: {
                    await order.append("wait")
                    return try await park.wait()
                }
            )
        }

        var thrown: Error?
        do {
            _ = try await task.value
        } catch {
            thrown = error
        }
        #expect(thrown as? HerdrError == .timeout("parked"))
        #expect(await teardowns.value == 1)
        #expect(await order.snapshot() == ["wait", "teardown"])

        park.release(99)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await teardowns.value == 1)
    }

    @Test func parentCancellationDoesNotTearDownTransport() async throws {
        let park = ExternallyReleasedWait<Int>()
        let teardowns = Counter()

        let task = Task {
            try await withTimeout(
                seconds: 5,
                label: "cancel-me",
                onTimeout: { await teardowns.increment() },
                operation: { try await park.wait() }
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        var thrown: Error?
        do {
            _ = try await task.value
        } catch {
            thrown = error
        }
        #expect(thrown is CancellationError)
        #expect(await teardowns.value == 0)
        park.release(1)
    }

    @Test func cancelBeforeInstallResumesContinuationImmediately() async throws {
        let race = TimeoutRace<Int>()
        race.cancelFromParent()

        var thrown: Error?
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                let installed = race.install(continuation)
                #expect(!installed)
            }
        } catch {
            thrown = error
        }
        #expect(thrown is CancellationError)
    }

    @Test func attachAfterCancelCancelsBothWorkAndTimer() async throws {
        let race = TimeoutRace<Int>()
        race.cancelFromParent()

        let workCancelled = Flag()
        let timerCancelled = Flag()
        let work = Task<Void, Never> {
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(10))
            } onCancel: {
                Task { await workCancelled.set() }
            }
        }
        let timer = Task<Void, Never> {
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(10))
            } onCancel: {
                Task { await timerCancelled.set() }
            }
        }
        race.attach(work: work, timer: timer)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await workCancelled.value)
        #expect(await timerCancelled.value)
    }

    @Test func alreadyCancelledCallerDoesNotStartOperation() async throws {
        let started = Flag()
        let teardowns = Counter()
        let task = Task {
            // Cancel before entering withTimeout body.
            try await Task.sleep(for: .milliseconds(1))
            return try await withTimeout(
                seconds: 2,
                label: "pre-cancelled",
                onTimeout: { await teardowns.increment() },
                operation: {
                    await started.set()
                    return 1
                }
            )
        }
        task.cancel()
        var thrown: Error?
        do {
            _ = try await task.value
        } catch {
            thrown = error
        }
        #expect(thrown is CancellationError)
        #expect(await !started.value)
        #expect(await teardowns.value == 0)
    }
}

@Suite("Connection session ownership")
struct ConnectionSessionOwnershipTests {
    @Test func reservedGenerationRequiredForWatchdogTeardown() {
        var ownership = ConnectionSessionOwnership()
        let attempt = ownership.beginAttempt()
        let beforeReserve = ownership.watchdogTimeout(for: attempt)
        #expect(beforeReserve == .stale)

        let reserved = ConnectionGeneration(rawValue: 7)
        let associated = ownership.associateReserved(reserved, for: attempt)
        #expect(associated)
        switch ownership.watchdogTimeout(for: attempt) {
        case .stale:
            Issue.record("expected timedOut after reserve")
        case let .timedOut(generation):
            #expect(generation == reserved)
            #expect(!ownership.isCurrent(attempt))
        }
        let lateInstall = ownership.noteTransportInstalled(reserved, for: attempt)
        #expect(!lateInstall)
    }

    @Test func lossInvalidatesAttemptSoDelayedHandshakeCannotPromote() {
        var ownership = ConnectionSessionOwnership()
        let attempt = ownership.beginAttempt()
        let gen = ConnectionGeneration(rawValue: 3)
        let associated = ownership.associateReserved(gen, for: attempt)
        #expect(associated)
        let installed = ownership.noteTransportInstalled(gen, for: attempt)
        #expect(installed)

        let staleLoss = ownership.handleLoss(generation: ConnectionGeneration(rawValue: 99))
        #expect(!staleLoss)
        #expect(ownership.isCurrent(attempt))

        let loss = ownership.handleLoss(generation: gen)
        #expect(loss)
        #expect(!ownership.isCurrent(attempt))
        let lossAgain = ownership.handleLoss(generation: gen)
        #expect(!lossAgain)
        // Late "handshake success" must not attach to a dead attempt.
        let lateInstall = ownership.noteTransportInstalled(gen, for: attempt)
        #expect(!lateInstall)
    }

    @Test func failOnStaleAttemptDoesNotClose() {
        var ownership = ConnectionSessionOwnership()
        let first = ownership.beginAttempt()
        let reserved = ConnectionGeneration(rawValue: 1)
        let associated = ownership.associateReserved(reserved, for: first)
        #expect(associated)
        _ = ownership.beginAttempt()
        let failResult = ownership.fail(for: first)
        #expect(failResult == .stale)
    }

    @Test func disconnectReturnsReservedGenerationForScopedClose() {
        var ownership = ConnectionSessionOwnership()
        let attempt = ownership.beginAttempt()
        let reserved = ConnectionGeneration(rawValue: 11)
        let associated = ownership.associateReserved(reserved, for: attempt)
        #expect(associated)
        let closed = ownership.disconnect()
        #expect(closed == reserved)
        let again = ownership.disconnect()
        #expect(again == nil)
    }
}

@Suite("Connection client slot")
struct ConnectionClientSlotTests {
    final class FakeClient: @unchecked Sendable {
        private(set) var closeCount = 0

        func close() async {
            closeCount += 1
        }
    }

    @Test func staleInstallReturnsOrphanWithoutReplacingNewerClient() {
        var slot = ConnectionClientSlot<FakeClient>()
        let (attempt1, _) = slot.beginReplace()
        let first = FakeClient()
        let install1 = slot.install(first, expected: attempt1)
        #expect(install1 == nil)

        let (attempt2, previous) = slot.beginReplace()
        #expect(previous === first)
        let second = FakeClient()
        let install2 = slot.install(second, expected: attempt2)
        #expect(install2 == nil)

        let orphan = FakeClient()
        let returned = slot.install(orphan, expected: attempt1)
        #expect(returned === orphan)
        #expect(slot.current === second)
    }

    @Test func invalidateRejectsLateInstallAndGuardsStaleTeardown() {
        var slot = ConnectionClientSlot<FakeClient>()
        let (attempt, _) = slot.beginReplace()
        let client = FakeClient()
        let install1 = slot.install(client, expected: attempt)
        #expect(install1 == nil)

        switch slot.invalidate(attempt) {
        case .stale:
            Issue.record("expected invalidated")
        case let .invalidated(captured):
            #expect(captured === client)
        }
        #expect(slot.current == nil)

        let late = FakeClient()
        let lateInstall = slot.install(late, expected: attempt)
        #expect(lateInstall === late)

        // Stale invalidate must not clear a newer reservation.
        let (next, _) = slot.beginReplace()
        let newer = FakeClient()
        let install2 = slot.install(newer, expected: next)
        #expect(install2 == nil)
        switch slot.invalidate(attempt) {
        case .stale:
            break
        case .invalidated:
            Issue.record("stale invalidate must not tear down newer slot")
        }
        #expect(slot.current === newer)
    }

    @Test func reservedGenerationCloseBeforeInstallBlocksHandshake() {
        // Mirrors AppModel: reserve → forceClose(reserved) → late install fails.
        var slot = ConnectionClientSlot<FakeClient>()
        let (reserved, _) = slot.beginReplace()
        switch slot.invalidate(reserved) {
        case .stale:
            Issue.record("expected invalidate of reserved generation")
        case .invalidated:
            break
        }
        let late = FakeClient()
        let lateInstall = slot.install(late, expected: reserved)
        #expect(lateInstall === late)
        #expect(slot.current == nil)
    }

    @Test func newReplaceDuringOldCloseDoesNotClearNewerClient() async {
        var slot = ConnectionClientSlot<FakeClient>()
        let (attempt1, _) = slot.beginReplace()
        let old = FakeClient()
        let install1 = slot.install(old, expected: attempt1)
        #expect(install1 == nil)

        let (attempt2, previous) = slot.beginReplace()
        #expect(previous === old)
        let newer = FakeClient()
        let install2 = slot.install(newer, expected: attempt2)
        #expect(install2 == nil)

        await previous?.close()
        #expect(slot.current === newer)
        switch slot.invalidate(attempt1) {
        case .stale:
            break
        case .invalidated:
            Issue.record("old generation invalidate must be stale")
        }
        #expect(slot.current === newer)
    }
}

@Suite("Persistence isolation")
struct PanePersistenceIsolationTests {
    @Test func storageKeyPreservesUsernameCase() {
        let alice = ConnectionIdentity(host: "Mac.local", port: 22, username: "Alice")
        let aliceLower = ConnectionIdentity(host: "mac.local", port: 22, username: "alice")
        #expect(alice.storageKey != aliceLower.storageKey)
        let tricky = ConnectionIdentity(host: "h", port: 22, username: "u@x:y")
        #expect(tricky.storageKey.hasPrefix("u="))
        #expect(PanePersistenceKeys.draft(scope: alice, paneId: "w1:p1").contains(alice.storageKey))
    }

    @Test func scopedDraftKeysDoNotAutoClaimLegacy() throws {
        let suiteName = "PersistIsolation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scope = ConnectionIdentity(host: "a.local", port: 22, username: "bob")
        let legacyKey = PanePersistenceKeys.legacyDraft(paneId: "w1:p1")
        let scopedKey = PanePersistenceKeys.draft(scope: scope, paneId: "w1:p1")
        defaults.set("legacy-draft", forKey: legacyKey)
        #expect(defaults.string(forKey: scopedKey) == nil)
        #expect(defaults.string(forKey: legacyKey) == "legacy-draft")
    }

    @Test func lastUpdatedScopesAreIsolatedAndLegacyUntouched() throws {
        let suiteName = "PaneLastUpdated.scope.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let hostA = ConnectionIdentity(host: "a.local", port: 22, username: "bob")
        let hostB = ConnectionIdentity(host: "b.local", port: 22, username: "bob")
        let panesJSON = """
        {"id":"cli:pane:list","result":{"panes":[
        {"agent_status":"idle","focused":true,"pane_id":"w1:p1","revision":1,"tab_id":"w1:t1","workspace_id":"w1"}
        ]}}
        """
        let panes = try HerdrConnection.decode(panesJSON, as: PaneListResult.self).panes
        let firstObservedAt = Date(timeIntervalSince1970: 1_000)
        _ = PaneLastUpdatedStore.observe(panes, scope: hostA, now: firstObservedAt, defaults: defaults)
        #expect(PaneLastUpdatedStore.dates(scope: hostA, defaults: defaults)["w1:p1"] == firstObservedAt)
        #expect(PaneLastUpdatedStore.dates(scope: hostB, defaults: defaults)["w1:p1"] == nil)

        PaneLastUpdatedStore.saveLegacy(
            ["w1:p1": .init(fingerprint: "legacy", updatedAt: Date(timeIntervalSince1970: 50))],
            defaults: defaults
        )
        _ = PaneLastUpdatedStore.observe(
            panes, scope: hostB, now: Date(timeIntervalSince1970: 2_000), defaults: defaults
        )
        #expect(PaneLastUpdatedStore.loadLegacy(defaults: defaults)["w1:p1"]?.fingerprint == "legacy")
    }
}
