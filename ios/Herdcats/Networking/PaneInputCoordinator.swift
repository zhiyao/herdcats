import Foundation

/// Serializes remote composer mutations for a single pane.
///
/// Submit, replace-pending, and escape all mutate the same remote input.
/// Each pane gets an exclusive lane.
///
/// Once the lane is acquired, the mutation body runs **detached from parent
/// cancellation** so a cancelled view task cannot release the lane while a
/// Citadel exec (and generation-scoped cleanup) is still in flight. Waiters
/// still respect cancellation before they start.
///
/// Ownership transfer is atomic FIFO: `release` keeps the lane busy and hands
/// it to the next waiter. If that waiter is cancelled after handoff (before
/// running its body), `run`'s `defer` releases to the following waiter — so a
/// cancelled handoff never parks the rest of the queue forever.
actor PaneInputCoordinator {
    private var busy: Set<String> = []
    private var waiters: [String: [Waiter]] = [:]

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Number of tasks waiting for `paneId`'s lane (not including the holder).
    /// Test seam for establishing FIFO enqueue order without sleep races.
    func queuedCount(paneId: String) -> Int {
        waiters[paneId]?.count ?? 0
    }

    func isBusy(_ paneId: String) -> Bool {
        busy.contains(paneId)
    }

    /// Runs `operation` exclusively for `paneId`.
    func run<T: Sendable>(
        paneId: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(paneId: paneId)
        // If cancelled after FIFO handoff, defer still releases to the next waiter.
        defer { release(paneId) }
        await Task.yield()
        try Task.checkCancellation()
        // Shield the mutating body: parent cancel must not unwind `defer release`
        // while SSH work / cleanup is still active.
        return try await Self.runIgnoringParentCancellation(operation)
    }

    private func acquire(paneId: String) async throws {
        if busy.contains(paneId) {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    waiters[paneId, default: []].append(Waiter(id: id, continuation: continuation))
                }
            } onCancel: {
                Task { await self.cancelWaiter(paneId: paneId, id: id) }
            }
            // Resumed from `release` = ownership already transferred; lane stays busy.
            return
        }
        try Task.checkCancellation()
        busy.insert(paneId)
    }

    private func cancelWaiter(paneId: String, id: UUID) {
        guard var queue = waiters[paneId],
              let index = queue.firstIndex(where: { $0.id == id }) else {
            // Already handed ownership (removed from queue by `release`) — the
            // cancelled task's `defer { release }` will pass the lane onward.
            return
        }
        let waiter = queue.remove(at: index)
        waiters[paneId] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Releases the lane or atomically hands it to the next FIFO waiter.
    private func release(_ paneId: String) {
        guard var queue = waiters[paneId], !queue.isEmpty else {
            busy.remove(paneId)
            waiters[paneId] = nil
            return
        }
        // Keep busy=true and transfer ownership to the next waiter.
        let next = queue.removeFirst()
        waiters[paneId] = queue.isEmpty ? nil : queue
        next.continuation.resume()
    }

    /// Runs `operation` on a detached task so parent cancellation cannot abort
    /// mid-mutation; the lane stays held until the body returns.
    private static func runIgnoringParentCancellation<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    continuation.resume(returning: try await operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
