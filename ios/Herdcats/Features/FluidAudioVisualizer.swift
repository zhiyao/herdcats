import SwiftUI

/// Soft, blurred accent blobs that drift slowly and swell with the microphone
/// level. The timeline pauses whenever `isActive` is false, leaving a subdued
/// still frame. Reduce Motion swaps the animation for a static wash and a
/// simple level bar.
struct FluidAudioVisualizer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var smoother = LevelSmoother()
    var level: Float
    var isActive: Bool

    private struct Blob {
        let color: Int
        let center: CGPoint
        let drift: CGSize
        let speed: Double
        let phase: Double
        let radius: CGFloat
        let swell: CGFloat
    }

    // Unit-space layout, biased toward the bottom so the transcript reads on top.
    private static let blobs = [
        Blob(color: 0, center: CGPoint(x: 0.22, y: 0.78), drift: CGSize(width: 0.12, height: 0.08),
             speed: 0.31, phase: 0, radius: 0.42, swell: 0.32),
        Blob(color: 1, center: CGPoint(x: 0.72, y: 0.82), drift: CGSize(width: 0.14, height: 0.06),
             speed: 0.23, phase: 1.7, radius: 0.38, swell: 0.4),
        Blob(color: 2, center: CGPoint(x: 0.5, y: 0.62), drift: CGSize(width: 0.2, height: 0.1),
             speed: 0.17, phase: 3.1, radius: 0.3, swell: 0.5),
        Blob(color: 0, center: CGPoint(x: 0.88, y: 0.4), drift: CGSize(width: 0.08, height: 0.12),
             speed: 0.27, phase: 4.4, radius: 0.24, swell: 0.28)
    ]

    var body: some View {
        if reduceMotion {
            staticWash
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isActive)) { timeline in
                canvas(time: timeline.date.timeIntervalSinceReferenceDate)
            }
            .accessibilityHidden(true)
        }
    }

    private var baseOpacity: Double {
        let opacity = colorScheme == .dark ? 0.55 : 0.38
        return (reduceTransparency ? opacity * 0.6 : opacity) * (isActive ? 1 : 0.5)
    }

    private func canvas(time: TimeInterval) -> some View {
        let colors = [Theme.accent, Theme.sky, Theme.statusDone]
        let opacity = baseOpacity
        let target = isActive ? CGFloat(level) : 0
        return Canvas { context, size in
            let level = smoother.value(toward: target, at: time)
            let scale = min(size.width, size.height)
            context.addFilter(.blur(radius: scale * 0.16))
            for blob in Self.blobs {
                let angle = time * blob.speed + blob.phase
                let x = (blob.center.x + blob.drift.width * CGFloat(sin(angle))) * size.width
                let y = (blob.center.y + blob.drift.height * CGFloat(cos(angle * 1.3))
                         - level * 0.18) * size.height
                let breathe = 1 + 0.06 * CGFloat(sin(angle * 2))
                let radius = scale * blob.radius * breathe * (1 + blob.swell * level)
                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect),
                             with: .color(colors[blob.color].opacity(opacity * (0.7 + 0.3 * Double(level)))))
            }
        }
    }

    private var staticWash: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Theme.accent.opacity(0), Theme.accent.opacity(baseOpacity * 0.6)],
                           startPoint: .top, endPoint: .bottom)
            GeometryReader { proxy in
                Capsule()
                    .fill(Theme.accent.opacity(isActive ? 0.8 : 0.3))
                    .frame(width: max(8, proxy.size.width * CGFloat(isActive ? level : 0)), height: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 4)
            .padding(.horizontal, 24)
            .padding(.bottom, 6)
        }
        .accessibilityHidden(true)
    }
}

/// Frame-rate independent easing of the published level, held by reference so
/// the canvas can advance it while drawing without invalidating the view.
private final class LevelSmoother {
    private var current: CGFloat = 0
    private var lastTime: TimeInterval?

    func value(toward target: CGFloat, at time: TimeInterval) -> CGFloat {
        let delta = lastTime.map { min(max(time - $0, 0), 0.1) } ?? 0
        lastTime = time
        let rate: CGFloat = target > current ? 14 : 5
        current += (target - current) * min(1, rate * CGFloat(delta))
        return current
    }
}
