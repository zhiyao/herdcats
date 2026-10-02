import Foundation
import Security
import NIOSSH
import SwiftUI
import Testing
@testable import Herdcats

actor TestLiveGenerationState {
    private var current: ConnectionGeneration

    init(_ current: ConnectionGeneration) {
        self.current = current
    }

    func require(_ owned: ConnectionGeneration) throws {
        guard current == owned else { throw HerdrError.notConnected }
    }

    func replace(with generation: ConnectionGeneration) {
        current = generation
    }
}

@Suite("Pane live input delivery")
struct PaneLiveInputDeliveryTests {
    @Test
    @MainActor
    func recordsWireOrderWithDelayedFirstSend() async throws {
        let gate = ExternallyReleasedWait<Void>()
        let sender = RecordingLiveSender(firstSendGate: gate)
        let queue = PaneLiveInputQueue(sender: sender, maxPending: 32)
        let session = PaneLiveInputSession(
            paneId: "w1:p1",
            generation: ConnectionGeneration(rawValue: 3)
        )

        #expect(queue.enqueue(.text("a"), session: session))
        #expect(queue.enqueue(.text("b"), session: session))
        #expect(queue.enqueue(.keys(["backspace"]), session: session))
        #expect(queue.enqueue(.text("c"), session: session))
        #expect(queue.enqueue(.keys(["enter"]), session: session))
        #expect(queue.enqueue(.keys(["esc"]), session: session))
        #expect(queue.enqueue(.keys(["1"]), session: session)) // blocked choice
        #expect(queue.enqueue(.keys(["up"]), session: session)) // command-pad shortcut
        #expect(queue.state == .sending)

        try await Task.sleep(for: .milliseconds(30))
        #expect(await sender.wire.isEmpty)

        gate.release(())
        try await waitUntilLiveIdle(queue)

        // Adjacent same-kind events coalesce; text/keys boundaries keep order.
        #expect(await sender.wire == [
            "text:ab",
            "keys:backspace",
            "text:c",
            "keys:enter,esc,1,up"
        ])
        #expect(queue.acknowledgedCount == 8)
        #expect(queue.state == .ready)
        #expect(queue.pendingCount == 0)
    }

    @Test
    @MainActor
    func acknowledgedCountIncrementsPerSuccessfulSendWhileLaterEventsRemainQueued() async throws {
        let firstGate = ExternallyReleasedWait<Void>()
        let secondGate = ExternallyReleasedWait<Void>()
        let sender = RecordingLiveSender(sendGates: [firstGate, secondGate])
        let queue = PaneLiveInputQueue(sender: sender, maxPending: 8)
        let session = PaneLiveInputSession(
            paneId: "w1:p1",
            generation: ConnectionGeneration(rawValue: 9)
        )

        #expect(queue.acknowledgedCount == 0)
        #expect(queue.enqueue(.text("a"), session: session))
        try await waitUntil { queue.isDraining && queue.pendingCount == 0 }
        #expect(queue.enqueue(.text("b"), session: session))
        #expect(queue.enqueue(.text("c"), session: session))
        #expect(queue.enqueue(.keys(["enter"]), session: session))
        #expect(queue.pendingCount == 2)

        firstGate.release(())
        try await waitUntil {
            queue.acknowledgedCount == 1 && queue.pendingCount >= 1 && queue.isDraining
        }

        #expect(queue.acknowledgedCount == 1)
        #expect(queue.pendingCount >= 1)
        #expect(queue.state == .sending)
        #expect(await sender.wire == ["text:a"])

        secondGate.release(())
        // Third send has no gate — drain finishes after second releases.
        try await waitUntilLiveIdle(queue)

        // The "bc" batch acknowledges both of its events.
        #expect(queue.acknowledgedCount == 4)
        #expect(await sender.wire == ["text:a", "text:bc", "keys:enter"])
        #expect(queue.pendingCount == 0)
    }

    @Test
    @MainActor
    func acknowledgedCountDoesNotIncrementOnFailedDelivery() async throws {
        let gate = ExternallyReleasedWait<Void>()
        let sender = RecordingLiveSender(sendGates: [gate])
        await sender.setFailAfterGateWith(HerdrError.timeout(HerdrConnection.herdrDiagnosticLabel))
        let queue = PaneLiveInputQueue(sender: sender, maxPending: 8)
        let session = PaneLiveInputSession(
            paneId: "w1:p1",
            generation: ConnectionGeneration(rawValue: 2)
        )

        #expect(queue.enqueue(.text("maybe"), session: session))
        #expect(queue.enqueue(.text("later"), session: session))
        gate.release(())
        try await waitUntil { queue.state == .needsResync }

        #expect(queue.acknowledgedCount == 0)
        #expect(await sender.attemptCount == 1)
    }

    @Test
    @MainActor
    func coalescesKeystrokeBurstWhileSendIsInFlight() async throws {
        let gate = ExternallyReleasedWait<Void>()
        let sender = RecordingLiveSender(firstSendGate: gate)
        let queue = PaneLiveInputQueue(sender: sender, maxPending: 2)
        let session = PaneLiveInputSession(
            paneId: "w1:p1",
            generation: ConnectionGeneration(rawValue: 1)
        )

        // First key after idle goes out immediately, alone.
        #expect(queue.enqueue(.text("h"), session: session))
        try await waitUntil { queue.isDraining && queue.pendingCount == 0 }
        #expect(await sender.wire.isEmpty)
        #expect(await sender.attemptCount == 1)

        // A burst longer than maxPending fits because it coalesces.
        for character in "ello, world" {
            #expect(queue.enqueue(.text(String(character)), session: session))
        }
        #expect(queue.pendingCount == 1)

        gate.release(())
        try await waitUntilLiveIdle(queue)

        #expect(await sender.wire == ["text:h", "text:ello, world"])
        #expect(queue.acknowledgedCount == 12)
    }

    @Test
    @MainActor
    func doesNotCoalesceAcrossSessions() async throws {
        let gate = ExternallyReleasedWait<Void>()
        let sender = RecordingLiveSender(firstSendGate: gate)
        let queue = PaneLiveInputQueue(sender: sender, maxPending: 8)
        let first = PaneLiveInputSession(
            paneId: "w1:p1",
            generation: ConnectionGeneration(rawValue: 1)
        )
        let second = PaneLiveInputSession(
            paneId: "w1:p1",
            generation: ConnectionGeneration(rawValue: 2)
        )

        #expect(queue.enqueue(.text("x"), session: first))
        try await waitUntil { queue.isDraining && queue.pendingCount == 0 }
        #expect(queue.enqueue(.text("a"), session: first))
        #expect(queue.enqueue(.text("b"), session: second))
        #expect(queue.pendingCount == 2)

        gate.release(())
        try await waitUntilLiveIdle(queue)

        #expect(await sender.wire == ["text:x", "text:a", "text:b"])
        #expect(queue.acknowledgedCount == 3)
    }

    @Test
    @MainActor
    func failedCoalescedBatchIsNotRetriedOrAcknowledged() async throws {
        let firstGate = ExternallyReleasedWait<Void>()
        let secondGate = ExternallyReleasedWait<Void>()
        let sender = RecordingLiveSender(sendGates: [firstGate, secondGate])
        let queue = PaneLiveInputQueue(sender: sender, maxPending: 8)
        let session = PaneLiveInputSession(
            paneId: "w1:p1",
            generation: ConnectionGeneration(rawValue: 1)
        )

        #expect(queue.enqueue(.text("a"), session: session))
        try await waitUntil { queue.isDraining && queue.pendingCount == 0 }
        #expect(queue.enqueue(.text("b"), session: session))
        #expect(queue.enqueue(.text("c"), session: session))
        #expect(queue.enqueue(.keys(["enter"]), session: session))

        firstGate.release(())
        try await waitUntil { queue.acknowledgedCount == 1 && queue.isDraining }
        await sender.setFailAfterGateWith(HerdrError.timeout(HerdrConnection.herdrDiagnosticLabel))
        secondGate.release(())
        try await waitUntil { queue.state == .needsResync }

        #expect(await sender.wire == ["text:a"])
        #expect(await sender.attemptCount == 2)
        #expect(queue.acknowledgedCount == 1)
        #expect(queue.pendingCount == 0)
    }

    @Test
    func liveCommandArgumentsEscapeShellMetacharactersUnicodeAndNewlines() {
        let pane = "w1:p1; rm -rf /"
        let text = "it's \"x\" $HOME `id`\n線"
        let textArgs = HerdrConnection.paneSendTextArguments(paneId: pane, text: text)
        let expectedTextArgs = "pane send-text \(HerdrConnection.shellSafeArgument(pane)) "
            + HerdrConnection.shellSafeArgument(text)
        #expect(textArgs == expectedTextArgs)
        #expect(!textArgs.contains("'"))
        #expect(!textArgs.contains(";"))
        #expect(!textArgs.contains("$HOME"))
        #expect(!textArgs.contains("`"))

        let keys = ["ctrl+c", "enter;evil", "線"]
        let keyArgs = HerdrConnection.paneSendKeysArguments(paneId: pane, keys: keys)
        let expectedKeyArgs = "pane send-keys \(HerdrConnection.shellSafeArgument(pane)) "
            + keys.map(HerdrConnection.shellSafeArgument).joined(separator: " ")
        #expect(keyArgs == expectedKeyArgs)
        #expect(!keyArgs.contains("'"))
        #expect(!keyArgs.contains(";"))
    }

    @Test
    @MainActor
    func fullQueueRefusesAdditionalEventsWithoutSilentDrop() async throws {
        let gate = ExternallyReleasedWait<Void>()
        let sender = RecordingLiveSender(firstSendGate: gate)
        let queue = PaneLiveInputQueue(sender: sender, maxPending: 2)
        let session = PaneLiveInputSession(
            paneId: "w1:p1",
            generation: ConnectionGeneration(rawValue: 1)
        )

        #expect(queue.enqueue(.text("a"), session: session))
        try await waitUntil { queue.isDraining && queue.pendingCount == 0 }
        #expect(queue.enqueue(.text("b"), session: session))
        #expect(queue.enqueue(.keys(["enter"]), session: session))
        #expect(!queue.enqueue(.text("c"), session: session))
        // Same-kind input still merges into the tail batch while full.
        #expect(queue.enqueue(.keys(["tab"]), session: session))
        #expect(queue.pendingCount == 2)

        gate.release(())
        try await waitUntilLiveIdle(queue)

        #expect(await sender.wire == ["text:a", "text:b", "keys:enter,tab"])
        #expect(queue.state == .ready)
    }

    @Test
    @MainActor
    func paneChangeDiscardsPendingWithoutDeliveryToNewPane() async throws {
        let gate = ExternallyReleasedWait<Void>()
        let sender = RecordingLiveSender(firstSendGate: gate)
        let queue = PaneLiveInputQueue(sender: sender, maxPending: 8)
        let oldSession = PaneLiveInputSession(
            paneId: "w1:p1",
            generation: ConnectionGeneration(rawValue: 1)
        )
        let newSession = PaneLiveInputSession(
            paneId: "w1:p2",
            generation: ConnectionGeneration(rawValue: 1)
        )

        #expect(queue.enqueue(.text("old"), session: oldSession))
        try await waitUntil { queue.isDraining && queue.pendingCount == 0 }
        #expect(queue.enqueue(.text("stale"), session: oldSession))
        queue.abandonQueuedInput()
        #expect(queue.pendingCount == 0)
        #expect(queue.enqueue(.text("new"), session: newSession))

        gate.release(())
        try await waitUntilLiveIdle(queue)

        let wire = await sender.wire
        #expect(wire == ["text:old", "text:new"])
        #expect(!wire.contains("text:stale"))
    }

    @Test
    @MainActor
    func generationMismatchStopsQueueAndDropsLaterEvents() async throws {
        let gate = ExternallyReleasedWait<Void>()
        let sender = RecordingLiveSender(firstSendGate: gate)
        await sender.setAcceptedGeneration(ConnectionGeneration(rawValue: 2))
        let queue = PaneLiveInputQueue(sender: sender, maxPending: 8)
        let stale = PaneLiveInputSession(
            paneId: "w1:p1",
            generation: ConnectionGeneration(rawValue: 1)
        )
        let newer = PaneLiveInputSession(
            paneId: "w1:p1",
            generation: ConnectionGeneration(rawValue: 2)
        )

        #expect(queue.enqueue(.text("a"), session: stale))
        #expect(queue.enqueue(.text("b"), session: newer))

        gate.release(())
        try await waitUntil { queue.state == .needsResync }

        #expect(queue.state == .needsResync)
        #expect(queue.pendingCount == 0)
        #expect(!queue.enqueue(.text("c"), session: newer))
        let wire = await sender.wire
        #expect(wire.isEmpty)
        #expect(await sender.attemptCount == 1)
    }

    @Test
    @MainActor
    func ambiguousTimeoutNeedsResyncWithoutRetryingInFlight() async throws {
        let gate = ExternallyReleasedWait<Void>()
        let sender = RecordingLiveSender(firstSendGate: gate)
        await sender.setFailAfterGateWith(HerdrError.timeout(HerdrConnection.herdrDiagnosticLabel))
        let queue = PaneLiveInputQueue(sender: sender, maxPending: 8)
        let session = PaneLiveInputSession(
            paneId: "w1:p1",
            generation: ConnectionGeneration(rawValue: 4)
        )

        #expect(queue.enqueue(.text("maybe"), session: session))
        #expect(queue.enqueue(.text("later"), session: session))
        #expect(queue.enqueue(.keys(["enter"]), session: session))

        gate.release(())
        try await waitUntil { queue.state == .needsResync }

        #expect(queue.state == .needsResync)
        #expect(queue.pendingCount == 0)
        #expect(await sender.attemptCount == 1)
        #expect(await sender.wire.isEmpty)
        #expect(!queue.enqueue(.text("more"), session: session))

        queue.noteResynced()
        #expect(queue.state == .ready)
        let fresh = PaneLiveInputSession(
            paneId: "w1:p1",
            generation: ConnectionGeneration(rawValue: 5)
        )
        await sender.setFailAfterGateWith(nil)
        #expect(queue.enqueue(.text("after"), session: fresh))
        try await waitUntilLiveIdle(queue)
        #expect(await sender.wire == ["text:after"])
        #expect(await sender.attemptCount == 2)
    }
}

actor RecordingLiveSender: PaneLiveInputSending {
    private(set) var wire: [String] = []
    private(set) var attemptCount = 0
    private var sendGates: [ExternallyReleasedWait<Void>]
    private var acceptedGeneration: ConnectionGeneration?
    private var failAfterGateWith: Error?

    init(
        firstSendGate: ExternallyReleasedWait<Void>? = nil,
        sendGates: [ExternallyReleasedWait<Void>] = []
    ) {
        if let firstSendGate, sendGates.isEmpty {
            self.sendGates = [firstSendGate]
        } else {
            self.sendGates = sendGates
        }
    }

    func setAcceptedGeneration(_ generation: ConnectionGeneration?) {
        acceptedGeneration = generation
    }

    func setFailAfterGateWith(_ error: Error?) {
        failAfterGateWith = error
    }

    func sendPaneLiveText(_ text: String, session: PaneLiveInputSession) async throws {
        try await beforeSend(session: session)
        wire.append("text:\(text)")
    }

    func sendPaneLiveKeys(_ keys: [String], session: PaneLiveInputSession) async throws {
        try await beforeSend(session: session)
        wire.append("keys:\(keys.joined(separator: ","))")
    }

    func beforeSend(session: PaneLiveInputSession) async throws {
        attemptCount += 1
        if !sendGates.isEmpty {
            let gate = sendGates.removeFirst()
            try await gate.wait()
        }
        if let acceptedGeneration, acceptedGeneration != session.generation {
            throw HerdrError.notConnected
        }
        if let failAfterGateWith {
            throw failAfterGateWith
        }
    }
}

@MainActor
func waitUntilLiveIdle(_ queue: PaneLiveInputQueue) async throws {
    try await waitUntil {
        queue.state == .ready && queue.pendingCount == 0 && !queue.isDraining
    }
}

@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ predicate: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !predicate() {
        if ContinuousClock.now >= deadline {
            Issue.record("Timed out waiting for live-input condition")
            return
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(5))
    }
}
