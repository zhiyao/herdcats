import Foundation
import Security
import NIOSSH
import SwiftUI
import Testing
@testable import Herdcats

@Suite("Pane input coordinator")
struct PaneInputCoordinatorTests {
    @Test func serializesOperationsAndHonorsCancellationBeforeStart() async throws {
        let coordinator = PaneInputCoordinator()
        let log = EventLog()
        let started = ExternallyReleasedWait<Void>()
        let finish = ExternallyReleasedWait<Void>()

        let first = Task {
            try await coordinator.run(paneId: "w1:p1") {
                await log.append("first-start")
                started.release(())
                try await finish.wait()
                await log.append("first-end")
            }
        }

        try await started.wait()
        let second = Task {
            try await coordinator.run(paneId: "w1:p1") {
                await log.append("second-start")
                await log.append("second-end")
            }
        }

        await waitUntilQueued(coordinator, paneId: "w1:p1", count: 1)
        second.cancel()

        var secondError: Error?
        do { try await second.value } catch { secondError = error }
        #expect(secondError is CancellationError)
        finish.release(())
        try await first.value
        let events = await log.snapshot()
        #expect(events.contains("first-start"))
        #expect(events.contains("first-end"))
        #expect(!events.contains("second-start"))
    }

    @Test func parentCancelDuringMutationKeepsLaneUntilCleanupFinishes() async throws {
        let coordinator = PaneInputCoordinator()
        let log = EventLog()
        let started = ExternallyReleasedWait<Void>()
        let park = ExternallyReleasedWait<Void>()

        let mutation = Task {
            try await coordinator.run(paneId: "w1:p1") {
                await log.append("mutate-start")
                started.release(())
                try await park.wait()
                await log.append("mutate-end")
                // Awaited cleanup inside the shielded body — lane stays held.
                await log.append("cleanup-done")
            }
        }

        try await started.wait()
        mutation.cancel()

        let blocked = Task {
            try await coordinator.run(paneId: "w1:p1") {
                await log.append("second-start")
            }
        }

        // Mutation still owns the lane until body (including cleanup) finishes.
        #expect(await !log.snapshot().contains("second-start"))
        park.release(())
        try await mutation.value
        try await blocked.value

        let events = await log.snapshot()
        #expect(events.contains("mutate-end"))
        let cleanup = try #require(events.firstIndex(of: "cleanup-done"))
        let secondStart = try #require(events.firstIndex(of: "second-start"))
        #expect(cleanup < secondStart)
    }

    @Test func cancelledQueuedWaiterDoesNotParkLaterWaiters() async throws {
        // Cancel while still queued (holder still owns the lane) so `first`
        // cannot have started its body. Later FIFO waiters must still progress.
        let coordinator = PaneInputCoordinator()
        let log = EventLog()
        let holderStarted = ExternallyReleasedWait<Void>()
        let holderPark = ExternallyReleasedWait<Void>()
        let secondEntered = ExternallyReleasedWait<Void>()
        let secondPark = ExternallyReleasedWait<Void>()

        let holder = Task { try await coordinator.run(paneId: "w1:p1") {
                await log.append("holder")
                holderStarted.release(())
                try await holderPark.wait()
        } }
        try await holderStarted.wait()
        #expect(await coordinator.isBusy("w1:p1"))

        let first = Task { try await coordinator.run(paneId: "w1:p1") { await log.append("first-body") } }
        await waitUntilQueued(coordinator, paneId: "w1:p1", count: 1)

        let second = Task { try await coordinator.run(paneId: "w1:p1") {
                await log.append("second-start")
                secondEntered.release(())
                try await secondPark.wait()
                await log.append("second-end")
        } }
        await waitUntilQueued(coordinator, paneId: "w1:p1", count: 2)

        let third = Task {
            try await coordinator.run(paneId: "w1:p1") {
                await log.append("third")
            }
        }
        await waitUntilQueued(coordinator, paneId: "w1:p1", count: 3)

        // Cancel before releasing the holder — first cannot have run its body.
        first.cancel()
        var firstError: Error?
        do { try await first.value } catch { firstError = error }
        #expect(firstError is CancellationError)
        #expect(await !log.snapshot().contains("first-body"))
        #expect(await coordinator.queuedCount(paneId: "w1:p1") == 2)

        holderPark.release(())
        try await holder.value

        try await secondEntered.wait()
        #expect(await !log.snapshot().contains("third"))

        secondPark.release(())
        try await second.value
        try await third.value
        #expect(await log.snapshot() == ["holder", "second-start", "second-end", "third"])
    }

}

@Suite("Pane input coordinator handoff")
struct PaneInputHandoffTests {
    @Test func handoffCancelRaceStillLetsLaterWaitersProgress() async throws {
        // Handoff vs cancel is a race: `first` may complete its body or be
        // cancelled before body. Either way, second and third must progress
        // in FIFO order after the holder. Never await `first` while `second`
        // is parked on an unreleased barrier.
        let coordinator = PaneInputCoordinator()
        let log = EventLog()
        let holderStarted = ExternallyReleasedWait<Void>()
        let holderPark = ExternallyReleasedWait<Void>()
        let secondEntered = ExternallyReleasedWait<Void>()
        let secondPark = ExternallyReleasedWait<Void>()
        let thirdDone = ExternallyReleasedWait<Void>()

        let holder = Task {
            try await coordinator.run(paneId: "w1:p1") {
                await log.append("holder")
                holderStarted.release(())
                try await holderPark.wait()
            }
        }
        try await holderStarted.wait()

        let first = Task {
            try await coordinator.run(paneId: "w1:p1") {
                await log.append("first-body")
            }
        }
        await waitUntilQueued(coordinator, paneId: "w1:p1", count: 1)

        let second = Task {
            try await coordinator.run(paneId: "w1:p1") {
                await log.append("second-start")
                secondEntered.release(())
                try await secondPark.wait()
                await log.append("second-end")
            }
        }
        await waitUntilQueued(coordinator, paneId: "w1:p1", count: 2)

        let third = Task { try await coordinator.run(paneId: "w1:p1") {
                await log.append("third")
                thirdDone.release(())
        } }
        await waitUntilQueued(coordinator, paneId: "w1:p1", count: 3)

        holderPark.release(())
        try await holder.value
        // Cancel around handoff — may or may not beat `first`'s body.
        first.cancel()

        // Unblock the lane chain before awaiting `first` (which may be behind
        // `second` if cancel lost the race to body start).
        try await secondEntered.wait()
        secondPark.release(())
        _ = try? await first.value
        try await second.value
        try await thirdDone.wait()
        try await third.value

        try expectFIFOEvents(await log.snapshot())
    }

    private func expectFIFOEvents(_ events: [String]) throws {
        #expect(events.contains("holder"))
        #expect(events.contains("second-start"))
        #expect(events.contains("second-end"))
        #expect(events.contains("third"))
        let secondStart = try #require(events.firstIndex(of: "second-start"))
        let secondEnd = try #require(events.firstIndex(of: "second-end"))
        let thirdIndex = try #require(events.firstIndex(of: "third"))
        #expect(secondStart < secondEnd)
        #expect(secondEnd < thirdIndex)
        if let firstBody = events.firstIndex(of: "first-body") {
            #expect(firstBody < secondStart)
        }
    }

    @Test func generationCapturedBeforeLaneWaitRejectsStaleUnlockedStart() async throws {
        // Production path: capture `owned = generation` before `paneInput.run`,
        // then validate at the start of the unlocked sequence — no gap via a
        // separate ensure await after the lane wait.
        var slot = ConnectionClientSlot<Int>()
        let (gen1, _) = slot.beginReplace()
        let install1 = slot.install(1, expected: gen1)
        #expect(install1 == nil)
        let ownedBeforeWait = slot.generation

        let coordinator = PaneInputCoordinator()
        let park = ExternallyReleasedWait<Void>()
        let holderStarted = ExternallyReleasedWait<Void>()
        let log = EventLog()

        let holder = Task {
            try await coordinator.run(paneId: "w1:p1") {
                holderStarted.release(())
                try await park.wait()
            }
        }
        try await holderStarted.wait()

        // Bump generation while a later op waits for the lane.
        switch slot.invalidate(gen1) {
        case .stale: Issue.record("expected invalidate")
        case .invalidated: break
        }
        let (gen2, _) = slot.beginReplace()
        let install2 = slot.install(2, expected: gen2)
        #expect(install2 == nil)
        let currentSlot = slot

        let stale = Task {
            // Captured BEFORE waiting for the lane (production pattern).
            let owned = ownedBeforeWait
            try await coordinator.run(paneId: "w1:p1") {
                await log.append("entered")
                guard currentSlot.matches(owned) else {
                    await log.append("rejected")
                    throw HerdrError.notConnected
                }
                await log.append("accepted")
            }
        }

        park.release(())
        try await holder.value
        var thrown: Error?
        do { try await stale.value } catch { thrown = error }
        #expect(thrown as? HerdrError == .notConnected)
        #expect(await log.snapshot() == ["entered", "rejected"])
    }

    @Test func beginLiveInputBarrierWaitsBehindInFlightMutationThenIssuesToken() async throws {
        // Contract mirrored by HerdrConnection.beginPaneLiveInput: capture
        // generation, acquire the pane lane as a no-op barrier (waits behind
        // Compose submit/escape), re-check generation, then
        // return the session token. Pi reads the pane after this barrier.
        var slot = ConnectionClientSlot<Int>()
        let (gen, _) = slot.beginReplace()
        let install = slot.install(1, expected: gen)
        #expect(install == nil)
        let owned = slot.generation
        let currentSlot = slot

        let coordinator = PaneInputCoordinator()
        let log = EventLog()
        let holderStarted = ExternallyReleasedWait<Void>()
        let holderPark = ExternallyReleasedWait<Void>()

        let enrich = Task {
            try await coordinator.run(paneId: "w1:p1") {
                await log.append("enrich-start")
                holderStarted.release(())
                try await holderPark.wait()
                await log.append("enrich-end")
            }
        }
        try await holderStarted.wait()

        let beginLive = Task {
            let captured = owned
            try requireConnected(currentSlot, captured)
            let session = try await coordinator.run(paneId: "w1:p1") { () -> PaneLiveInputSession in
                await log.append("barrier")
                try requireConnected(currentSlot, captured)
                return PaneLiveInputSession(paneId: "w1:p1", generation: captured)
            }
            await log.append("token")
            return session
        }

        await waitUntilQueued(coordinator, paneId: "w1:p1", count: 1)
        #expect(await !log.snapshot().contains("barrier"))
        #expect(await !log.snapshot().contains("token"))

        holderPark.release(())
        try await enrich.value
        let session = try await beginLive.value

        #expect(await log.snapshot() == ["enrich-start", "enrich-end", "barrier", "token"])
        #expect(session.paneId == "w1:p1")
        #expect(session.generation == owned)
    }

    @Test func beginLiveInputBarrierRejectsStaleGenerationAfterLaneWait() async throws {
        var slot = ConnectionClientSlot<Int>()
        let (gen1, _) = slot.beginReplace()
        #expect(slot.install(1, expected: gen1) == nil)
        let ownedBeforeWait = slot.generation
        let generationState = TestLiveGenerationState(ownedBeforeWait)

        let coordinator = PaneInputCoordinator()
        let log = EventLog()
        let holderStarted = ExternallyReleasedWait<Void>()
        let holderPark = ExternallyReleasedWait<Void>()

        let holder = Task {
            try await coordinator.run(paneId: "w1:p1") {
                holderStarted.release(())
                try await holderPark.wait()
            }
        }
        try await holderStarted.wait()

        let beginLive = Task {
            let captured = ownedBeforeWait
            try await generationState.require(captured)
            return try await coordinator.run(paneId: "w1:p1") { () -> PaneLiveInputSession in
                await log.append("barrier")
                try await generationState.require(captured)
                await log.append("accepted")
                return PaneLiveInputSession(paneId: "w1:p1", generation: captured)
            }
        }
        await waitUntilQueued(coordinator, paneId: "w1:p1", count: 1)

        // Generation bumps while Live begin is queued behind Compose enrichment.
        switch slot.invalidate(gen1) {
        case .stale: Issue.record("expected invalidate")
        case .invalidated: break
        }
        let (gen2, _) = slot.beginReplace()
        #expect(slot.install(2, expected: gen2) == nil)
        await generationState.replace(with: gen2)

        holderPark.release(())
        try await holder.value
        var thrown: Error?
        do { _ = try await beginLive.value } catch { thrown = error }
        #expect(thrown as? HerdrError == .notConnected)
        #expect(await log.snapshot() == ["barrier"])
    }
}

/// Mirrors `HerdrConnection.requireGeneration` against a test slot.
func requireConnected(_ slot: ConnectionClientSlot<Int>, _ owned: ConnectionGeneration) throws {
    guard slot.matches(owned), slot.current != nil else {
        throw HerdrError.notConnected
    }
}

/// Synchronizes a test generation that changes while a pane-lane waiter is suspended.
