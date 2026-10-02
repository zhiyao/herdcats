import Foundation

/// Bounded timeout that returns as soon as the deadline fires.
///
/// Citadel 0.12.1 `SSHClient.executeCommand` awaits `EventLoopFuture.get()` with
/// no Swift concurrency cancellation handler (`ExecClient.swift`). Cancelling the
/// operation task therefore does not unblock a wedged exec. This helper:
/// 1. races a timer against the operation without a task-group wait-on-exit,
/// 2. **claims** the race atomically before any `onTimeout` teardown,
/// 3. resumes the caller immediately — it does not await the orphaned exec.
///
/// Parent-task cancellation resumes with `CancellationError` and does **not**
/// tear down transport (a cancelled pane reload must not drop the SSH session).
/// Pane mutations that need cleanup must run through `PaneInputCoordinator`
/// with cancellation shielding so the lane stays held until exec finishes.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    label: String,
    onTimeout: (@Sendable () async -> Void)? = nil,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = TimeoutRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            // Cancel may have raced ahead of install — resume immediately.
            guard race.install(continuation) else { return }

            // Do not start work/timer for an already-cancelled caller.
            if Task.isCancelled {
                race.cancelFromParent()
                return
            }

            let work = Task<Void, Never> {
                let result: Result<T, Error>
                do {
                    result = .success(try await operation())
                } catch {
                    result = .failure(error)
                }
                race.finishWork(result)
            }

            let timer = Task<Void, Never> {
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    return
                }
                guard race.claimTimeout() else { return }
                if let onTimeout {
                    await onTimeout()
                }
                race.finishTimeout(HerdrError.timeout(label))
            }

            race.attach(work: work, timer: timer)
        }
    } onCancel: {
        race.cancelFromParent()
    }
}

/// Synchronized race between work, timer, and parent cancellation.
final class TimeoutRace<T: Sendable>: @unchecked Sendable {
    private enum Winner {
        case none
        case work
        case timer
        case cancelled
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var winner: Winner = .none
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    /// Installs the caller's continuation. Returns `false` when the race was
    /// already cancelled — the continuation has been resumed with
    /// `CancellationError` and the caller must not start work/timer.
    @discardableResult
    func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        if winner == .cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    /// Stores tasks after both exist. If a winner already claimed, cancel losers.
    func attach(work: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        self.work = work
        self.timer = timer
        let current = winner
        lock.unlock()
        switch current {
        case .cancelled:
            work.cancel()
            timer.cancel()
        case .work:
            timer.cancel()
        case .timer:
            work.cancel()
        case .none:
            break
        }
    }

    func finishWork(_ result: Result<T, Error>) {
        let continuation: CheckedContinuation<T, Error>?
        let timerToCancel: Task<Void, Never>?
        lock.lock()
        if winner == .none {
            winner = .work
            continuation = self.continuation
            self.continuation = nil
            timerToCancel = timer
        } else {
            continuation = nil
            timerToCancel = nil
        }
        lock.unlock()
        timerToCancel?.cancel()
        continuation?.resume(with: result)
    }

    /// Timer deadline reached. Returns `true` only when this side may tear down.
    func claimTimeout() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard winner == .none else { return false }
        winner = .timer
        return true
    }

    func finishTimeout(_ error: Error) {
        let continuation: CheckedContinuation<T, Error>?
        let workToCancel: Task<Void, Never>?
        lock.lock()
        continuation = self.continuation
        self.continuation = nil
        workToCancel = work
        lock.unlock()
        workToCancel?.cancel()
        continuation?.resume(throwing: error)
    }

    /// Parent task cancelled: claim without transport teardown.
    /// Safe to call before `install` — a later `install` resumes immediately.
    func cancelFromParent() {
        let continuation: CheckedContinuation<T, Error>?
        let workToCancel: Task<Void, Never>?
        let timerToCancel: Task<Void, Never>?
        lock.lock()
        switch winner {
        case .none:
            winner = .cancelled
            continuation = self.continuation
            self.continuation = nil
            workToCancel = work
            timerToCancel = timer
        case .cancelled, .work, .timer:
            continuation = nil
            workToCancel = nil
            timerToCancel = nil
        }
        lock.unlock()
        workToCancel?.cancel()
        timerToCancel?.cancel()
        continuation?.resume(throwing: CancellationError())
    }
}

/// Monotonic ownership token for an SSH client installed in `HerdrConnection`.
struct ConnectionGeneration: Hashable, Sendable, Comparable {
    var rawValue: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    mutating func bump() -> ConnectionGeneration {
        rawValue += 1
        return self
    }
}
