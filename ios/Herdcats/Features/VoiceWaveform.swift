import SwiftUI

/// Recording waveform: one rounded bar per sampled mic level, filling left to
/// right over a row of dots, then scrolling once the row is full. Sampling
/// pauses with `isActive`, freezing the bars recorded so far.
struct VoiceWaveform: View {
    @State private var history = LevelHistory()
    var level: Float
    var isActive: Bool

    private static let barWidth: CGFloat = 3
    private static let spacing: CGFloat = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isActive)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let target = isActive ? CGFloat(level) : 0
            Canvas { context, size in
                let slots = min(LevelHistory.capacity,
                                Int((size.width + Self.spacing) / (Self.barWidth + Self.spacing)))
                if isActive { history.sample(target, at: time, slots: slots) }
                let midY = size.height / 2
                for slot in 0..<slots {
                    let x = CGFloat(slot) * (Self.barWidth + Self.spacing)
                    if let value = history.value(at: slot, slots: slots) {
                        let height = max(Self.barWidth, size.height * value)
                        let rect = CGRect(x: x, y: midY - height / 2, width: Self.barWidth, height: height)
                        context.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2),
                                     with: .color(Theme.text.opacity(0.85)))
                    } else {
                        let rect = CGRect(x: x, y: midY - Self.barWidth / 2,
                                          width: Self.barWidth, height: Self.barWidth)
                        context.fill(Path(ellipseIn: rect), with: .color(Theme.text.opacity(0.3)))
                    }
                }
            }
        }
        .onChange(of: isActive) { _, active in
            if active { history.resumeClock() }
        }
    }
}

/// Fixed-capacity ring of level samples, taken every `interval` seconds and
/// held by reference so the canvas can append while drawing.
private final class LevelHistory {
    static let capacity = 160
    private static let interval: TimeInterval = 0.07
    private var samples = [CGFloat](repeating: 0, count: capacity)
    private var count = 0
    private var head = 0
    private var lastSample: TimeInterval?
    private var peak: CGFloat = 0

    func sample(_ level: CGFloat, at time: TimeInterval, slots: Int) {
        // Keep the loudest level between samples so short syllables register.
        peak = max(peak, level)
        guard slots > 0 else { return }
        if let lastSample, time - lastSample < Self.interval { return }
        lastSample = time
        samples[head] = peak
        head = (head + 1) % Self.capacity
        count = min(count + 1, Self.capacity)
        peak = 0
    }

    /// Avoids a burst of samples when a paused timeline resumes.
    func resumeClock() { lastSample = nil }

    /// The sample shown in `slot` (0 = left), or nil for a not-yet-recorded dot.
    func value(at slot: Int, slots: Int) -> CGFloat? {
        let shown = min(count, slots)
        guard slot < shown else { return nil }
        let index = (head - shown + slot + Self.capacity * 2) % Self.capacity
        return samples[index]
    }
}
