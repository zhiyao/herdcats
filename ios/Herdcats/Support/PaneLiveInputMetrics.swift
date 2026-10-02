import Foundation
import Observation

/// One percentile row of the aggregate Live input diagnostic summary.
///
/// Values are durations in milliseconds. Sample counts are included so a
/// p95 over three samples is never mistaken for a stable measurement.
struct PaneLiveInputMetricPercentiles: Equatable, Sendable {
    let sampleCount: Int
    let p50Millis: Double?
    let p95Millis: Double?

    static let empty = PaneLiveInputMetricPercentiles(sampleCount: 0, p50Millis: nil, p95Millis: nil)

    /// Nearest-rank percentiles over an unordered sample list. Values are
    /// rounded to whole milliseconds; an empty list yields `nil` percentiles.
    static func compute(_ samples: [Double]) -> PaneLiveInputMetricPercentiles {
        guard !samples.isEmpty else { return .empty }
        let sorted = samples.map { ($0 * 100).rounded() / 100 }.sorted()
        func nearestRank(_ percentile: Double) -> Double {
            let rank = max(0, min(sorted.count - 1, Int((percentile * Double(sorted.count)).rounded(.up)) - 1))
            return sorted[rank]
        }
        return PaneLiveInputMetricPercentiles(
            sampleCount: sorted.count,
            p50Millis: nearestRank(0.5),
            p95Millis: nearestRank(0.95)
        )
    }
}

/// Snapshot of the aggregate Live input diagnostics for one test run.
///
/// Deliberately contains no text, keystrokes, pane output, hostnames, pane
/// IDs, machine names, or credentials — only durations, depths, and counts.
/// `ackToOutputChange` is an output-change proxy, not a guaranteed visible
/// character echo (the changed read can be unrelated TUI activity).
struct PaneLiveInputMetricsSummary: Equatable, Sendable {
    /// Enqueue → Herdr input acknowledgement, per accepted event batch.
    let enqueueToAck: PaneLiveInputMetricPercentiles
    /// Herdr acknowledgement → next changed pane read (output-change proxy).
    let ackToOutputChange: PaneLiveInputMetricPercentiles
    let maxQueueDepth: Int
    let timeoutCount: Int
    let failureCount: Int
    let discardedEventCount: Int

    var isEmpty: Bool {
        enqueueToAck.sampleCount == 0
            && ackToOutputChange.sampleCount == 0
            && maxQueueDepth == 0
            && timeoutCount == 0
            && failureCount == 0
            && discardedEventCount == 0
    }

    static let empty = PaneLiveInputMetricsSummary(
        enqueueToAck: .empty,
        ackToOutputChange: .empty,
        maxQueueDepth: 0,
        timeoutCount: 0,
        failureCount: 0,
        discardedEventCount: 0
    )
}

/// In-memory aggregate diagnostics for the Live pane input path.
///
/// Off by default and enabled only for a deliberate local test run; nothing
/// is persisted, uploaded, or logged. Records monotonic-clock durations for
/// enqueue → Herdr acknowledgement and acknowledgement → next changed pane
/// read, plus maximum queue depth and counts of timeouts, failures, and
/// discarded events. Individual input events are never retained: only
/// anonymous timestamps live long enough to compute a duration, and the
/// samples are cleared when the test run ends.
///
/// Acknowledgement timing: the queue's observable `acknowledgedCount`
/// increments once per successfully delivered event, and each increment is
/// paired with one FIFO-consumed enqueue timestamp here — so per-event
/// enqueue→ack durations are recorded even while later events are still in
/// flight. When a drain ends in `needsResync`, the batch counts as failed
/// and its undelivered events contribute no acknowledgement samples.
///
/// `@Observable` so the DEBUG diagnostics footer re-renders live during a
/// test run (toggle state and samples are read directly from this object).
@MainActor
@Observable
final class PaneLiveInputMetrics {
    static let shared = PaneLiveInputMetrics()
    static let isEnabledByDefault = false
    /// Hard cap so a long test run cannot grow memory without bound.
    static let maxSamplesPerMetric = 10_000

    /// SwiftUI may observe several queue acknowledgements at once. A queue
    /// replacement resets its counter, which contributes no new samples.
    static func acknowledgedDelta(from oldCount: UInt64, to newCount: UInt64) -> Int {
        guard newCount > oldCount else { return 0 }
        return min(Int(clamping: newCount - oldCount), 256)
    }

    /// Monotonic milliseconds from an injectable clock (tests pass a fake).
    private let clock: () -> Double

    private(set) var isEnabled: Bool

    private var enqueueToAckMillis: [Double] = []
    private var ackToOutputChangeMillis: [Double] = []
    /// Enqueue timestamps (ms) awaiting an acknowledgement, FIFO.
    private var awaitingAckClockMs: [Double] = []
    private var lastAckClockMs: Double?
    private(set) var maxQueueDepth = 0
    private(set) var timeoutCount = 0
    private(set) var failureCount = 0
    private(set) var discardedEventCount = 0

    init(clock: (@Sendable () -> Double)? = nil) {
        isEnabled = PaneLiveInputMetrics.isEnabledByDefault
        if let clock {
            self.clock = clock
        } else {
            self.clock = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
        }
    }

    /// Enables or disables collection for a test run. Disabling clears all
    /// samples and anonymous timestamps immediately.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !isEnabled {
            clear()
        }
    }

    /// Clears every sample and count. Called when the test run ends.
    func clear() {
        enqueueToAckMillis.removeAll()
        ackToOutputChangeMillis.removeAll()
        awaitingAckClockMs.removeAll()
        lastAckClockMs = nil
        maxQueueDepth = 0
        timeoutCount = 0
        failureCount = 0
        discardedEventCount = 0
    }

    /// Records one accepted event at `depth` (queue depth after enqueue).
    func noteEnqueued(depth: Int) {
        guard isEnabled else { return }
        maxQueueDepth = max(maxQueueDepth, depth)
        appendClock(&awaitingAckClockMs, clock())
    }

    /// Records one Herdr acknowledgement — one delivered event. Consumes the
    /// oldest outstanding enqueue timestamp (FIFO) and records its enqueue→ack
    /// duration; with no outstanding enqueue it still refreshes the
    /// acknowledgement clock used by the output-change proxy.
    func noteAcknowledged() {
        guard isEnabled else { return }
        let now = clock()
        if !awaitingAckClockMs.isEmpty {
            let enqueuedAt = awaitingAckClockMs.removeFirst()
            appendSample(&enqueueToAckMillis, now - enqueuedAt)
        }
        lastAckClockMs = now
    }

    /// Records a drain that ended in `needsResync`: one delivery attempt
    /// failed and every still-unacknowledged accepted event is discarded
    /// (never replayed), so it counts toward discarded events too.
    func noteDeliveryFailure() {
        guard isEnabled else { return }
        failureCount += 1
        discardedEventCount += awaitingAckClockMs.count
        awaitingAckClockMs.removeAll()
        lastAckClockMs = nil
    }

    /// Records the acknowledgement → next changed pane read duration (the
    /// output-change proxy). Only the FIRST changed read after an
    /// acknowledgement is sampled; the ack timestamp is consumed so later
    /// unrelated reads do not re-sample the same acknowledgement.
    func noteOutputChangedRead() {
        guard isEnabled, let ackedAt = lastAckClockMs else { return }
        appendSample(&ackToOutputChangeMillis, clock() - ackedAt)
        lastAckClockMs = nil
    }

    func noteTimeout() {
        guard isEnabled else { return }
        timeoutCount += 1
    }

    /// Records UI-accepted events that were discarded before delivery
    /// (rejected by a full/stopped queue or dropped on invalidation).
    func noteDiscardedEvents(_ count: Int) {
        guard isEnabled, count > 0 else { return }
        discardedEventCount += count
    }

    /// Discards every still-unacknowledged accepted event (pane switch,
    /// disconnect, leaving the pane) and counts them as discarded.
    func noteAbandoned() {
        guard isEnabled, !awaitingAckClockMs.isEmpty else { return }
        discardedEventCount += awaitingAckClockMs.count
        awaitingAckClockMs.removeAll()
    }

    var summary: PaneLiveInputMetricsSummary {
        PaneLiveInputMetricsSummary(
            enqueueToAck: PaneLiveInputMetricPercentiles.compute(enqueueToAckMillis),
            ackToOutputChange: PaneLiveInputMetricPercentiles.compute(ackToOutputChangeMillis),
            maxQueueDepth: maxQueueDepth,
            timeoutCount: timeoutCount,
            failureCount: failureCount,
            discardedEventCount: discardedEventCount
        )
    }

    private func appendSample(_ samples: inout [Double], _ value: Double) {
        guard value >= 0 else { return }
        guard samples.count < Self.maxSamplesPerMetric else { return }
        samples.append(value)
    }

    private func appendClock(_ samples: inout [Double], _ value: Double) {
        guard samples.count < Self.maxSamplesPerMetric else { return }
        samples.append(value)
    }
}
