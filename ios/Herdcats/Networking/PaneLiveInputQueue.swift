import Foundation
import Observation

/// Committed Live keyboard / accessory events, in arrival order.
enum PaneLiveInputEvent: Sendable, Equatable {
    case text(String)
    case keys([String])
}

/// Generation-scoped token for Live pane input. Invalidate after pane switch,
/// disconnect, or SSH generation change; never reuse across panes.
struct PaneLiveInputSession: Sendable, Equatable {
    let paneId: String
    let generation: ConnectionGeneration
}

/// Observable delivery phase for Live input.
enum PaneLiveInputQueueState: Sendable, Equatable {
    case ready
    case sending
    case needsResync
}

/// SSH lane used by `PaneLiveInputQueue`. Production uses `HerdrConnection`.
protocol PaneLiveInputSending: Sendable {
    func sendPaneLiveText(_ text: String, session: PaneLiveInputSession) async throws
    func sendPaneLiveKeys(_ keys: [String], session: PaneLiveInputSession) async throws
}

/// Main-actor bounded FIFO for Live events. Enqueue is synchronous so separate
/// `Task`s cannot reorder keystrokes before they enter the queue. One drain
/// loop sends through `PaneLiveInputSending` (which must use
/// `PaneInputCoordinator`). Ambiguous failures stop the queue; uncertain
/// events are never retried.
///
/// Nagle-style coalescing: while a send is in flight, a new event merges into
/// the last queued (not yet sent) batch when both are text, or both are keys,
/// for the same session. The first event after idle still goes out at once;
/// on a slow link a typing burst costs one round trip instead of one per key.
/// Text and keys never merge across each other, so wire order is preserved.
@MainActor
@Observable
final class PaneLiveInputQueue {
    /// Maximum queued sends (coalesced batches), not individual keystrokes.
    static let maxPendingEvents = 32

    private(set) var state: PaneLiveInputQueueState = .ready
    /// Number of queued sends (coalesced batches), excluding the in-flight one.
    private(set) var pendingCount = 0
    /// True while a drain task owns the send loop (including in-flight SSH).
    private(set) var isDraining = false
    /// Monotonic count of successfully delivered Live events. Increments by the
    /// number of events in each acknowledged send, before the next queued send
    /// starts. Failures and abandoned events do not increment.
    private(set) var acknowledgedCount: UInt64 = 0

    private let sender: any PaneLiveInputSending
    private let maxPending: Int
    private var pending: [Queued] = []
    private var drainTask: Task<Void, Never>?
    private var epoch: UInt64 = 0

    private struct Queued {
        var event: PaneLiveInputEvent
        let session: PaneLiveInputSession
        /// Accepted events merged into this send.
        var eventCount = 1

        /// Folds `next` into this batch when both are the same kind for the
        /// same session. Returns false, leaving the batch unchanged, otherwise.
        mutating func coalesce(_ next: PaneLiveInputEvent, session nextSession: PaneLiveInputSession) -> Bool {
            guard session == nextSession else { return false }
            switch (event, next) {
            case let (.text(queued), .text(added)):
                event = .text(queued + added)
            case let (.keys(queued), .keys(added)):
                event = .keys(queued + added)
            default:
                return false
            }
            eventCount += 1
            return true
        }
    }

    init(sender: any PaneLiveInputSending, maxPending: Int = maxPendingEvents) {
        self.sender = sender
        self.maxPending = max(1, maxPending)
    }

    /// Appends an event synchronously, merging it into the last queued batch
    /// when possible. Returns `false` when the queue is full, stopped for
    /// resync, or the event is empty — never silently drops an accepted event.
    @discardableResult
    func enqueue(_ event: PaneLiveInputEvent, session: PaneLiveInputSession) -> Bool {
        guard state != .needsResync else { return false }
        guard isDeliverable(event) else { return false }

        if let last = pending.indices.last, pending[last].coalesce(event, session: session) {
            // Merged into a queued batch; the drain loop is already scheduled.
            return true
        }
        guard pending.count < maxPending else { return false }
        pending.append(Queued(event: event, session: session))
        pendingCount = pending.count
        if state == .ready {
            state = .sending
        }
        startDrainIfNeeded()
        return true
    }

    /// Drops queued (not yet acknowledged) events on pane switch or disconnect.
    /// An in-flight send is not retried; remaining events never reach a new pane.
    func abandonQueuedInput() {
        epoch &+= 1
        pending.removeAll(keepingCapacity: false)
        pendingCount = 0
        if state != .needsResync {
            state = isDraining ? .sending : .ready
        }
    }

    /// Call after a fresh pane read and `beginPaneLiveInput` token.
    func noteResynced() {
        guard state == .needsResync else { return }
        epoch &+= 1
        pending.removeAll(keepingCapacity: false)
        pendingCount = 0
        state = isDraining ? .sending : .ready
    }

    private func isDeliverable(_ event: PaneLiveInputEvent) -> Bool {
        switch event {
        case let .text(text):
            !text.isEmpty
        case let .keys(keys):
            !keys.isEmpty && keys.allSatisfy { !$0.isEmpty }
        }
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        isDraining = true
        let myEpoch = epoch
        drainTask = Task { @MainActor in
            await self.runDrain(epoch: myEpoch)
        }
    }

    private func runDrain(epoch myEpoch: UInt64) async {
        defer {
            if self.epoch == myEpoch {
                self.drainTask = nil
                self.isDraining = false
                if self.state == .sending && self.pending.isEmpty {
                    self.state = .ready
                }
            } else {
                self.drainTask = nil
                self.isDraining = false
                if self.state != .needsResync {
                    if self.pending.isEmpty {
                        self.state = .ready
                    } else {
                        self.state = .sending
                        self.startDrainIfNeeded()
                    }
                }
            }
        }

        while epoch == myEpoch {
            guard let next = pending.first else { break }
            pending.removeFirst()
            pendingCount = pending.count

            do {
                switch next.event {
                case let .text(text):
                    try await sender.sendPaneLiveText(text, session: next.session)
                case let .keys(keys):
                    try await sender.sendPaneLiveKeys(keys, session: next.session)
                }
            } catch {
                guard epoch == myEpoch else { return }
                // Uncertain or failed delivery: never retry; discard the rest.
                pending.removeAll(keepingCapacity: false)
                pendingCount = 0
                state = .needsResync
                return
            }

            guard epoch == myEpoch else { return }
            // Ack every event in the batch before starting the next queued send.
            acknowledgedCount &+= UInt64(next.eventCount)
        }
    }
}
