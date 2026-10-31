import SwiftUI

// MARK: - Herd cat sprite

/// The running cat shared by the loading and offline states, drawn in sprite units
/// around its body so callers only translate and scale the context.
private enum HerdCatSprite {
    static let furs: [Color] = [
        Color(red: 0.78, green: 0.64, blue: 0.48),
        Color(red: 0.62, green: 0.67, blue: 0.73),
        Color(red: 0.91, green: 0.69, blue: 0.39)
    ]

    static func draw(in context: GraphicsContext, fur: Color, stride: Int) {
        func block(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ color: Color) {
            context.fill(Path(CGRect(x: x, y: y, width: width, height: height)), with: .color(color))
        }
        // Hooked tail, stretched body, ears, and alternating running paws.
        block(-13, -7, 2, 7, fur)
        block(-15, -8, 4, 2, fur)
        block(-11, -2, 15, 6, fur)
        block(1, -6, 7, 8, fur)
        block(1, -9, 2, 4, fur)
        block(6, -9, 2, 4, fur)
        block(-9 - stride, 3, 3, 4, fur)
        block(1 + stride, 3, 3, 4, fur)
        block(5, -4, 1, 2, Color.black.opacity(0.8))
        block(7, 0, 2, 1, Color(red: 0.85, green: 0.53, blue: 0.49))
    }
}

// MARK: - Loading cat

/// A single herd cat trotting across, matching the offline herd's sprite and motion.
struct LazyCatLoadingView: View {
    let message: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedAt = Date()

    var body: some View {
        VStack(spacing: 20) {
            TimelineView(.animation(minimumInterval: 1.0 / 12, paused: reduceMotion || scenePhase != .active)) { timeline in
                Canvas { context, size in
                    let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
                    let scale: CGFloat = 2
                    // Sprite spans x -15...8, so the cat is 23 units wide.
                    let width = 23 * scale
                    let groundY = size.height / 2 + 7 * scale + 3
                    // Start in view so even a quick load gets a glimpse of the cat.
                    let travel = (elapsed * 40 + width + size.width * 0.12)
                        .truncatingRemainder(dividingBy: size.width + width)
                    let x = reduceMotion ? size.width / 2 + 3.5 * scale : travel - width + 15 * scale
                    let stride = reduceMotion ? 0 : [0, 2, 0, -2][Int(elapsed * 10) % 4]
                    let bounce = reduceMotion ? 0 : abs(sin(elapsed * 14)) * 3

                    var ground = Path()
                    ground.move(to: CGPoint(x: size.width / 2 - 60, y: groundY))
                    ground.addLine(to: CGPoint(x: size.width / 2 + 60, y: groundY))
                    context.stroke(ground, with: .color(Theme.border), style: StrokeStyle(lineWidth: 5, lineCap: .round))

                    var cat = context
                    cat.translateBy(x: x, y: size.height / 2 - bounce)
                    cat.scaleBy(x: scale, y: scale)
                    HerdCatSprite.draw(in: cat, fur: HerdCatSprite.furs[0], stride: stride)
                }
            }
            .frame(height: 92)
            .clipped()
            .accessibilityHidden(true)

            Text(message)
                .font(.jost(.footnote))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
        .accessibilityIdentifier("lazy-cat-loading")
    }
}

#Preview("Loading cat — dark") {
    LazyCatLoadingView(message: "Loading spaces…")
        .background(Theme.backgroundGradient)
        .preferredColorScheme(.dark)
}

#Preview("Loading cat — light") {
    LazyCatLoadingView(message: "Loading spaces…")
        .background(Theme.backgroundGradient)
        .preferredColorScheme(.light)
}

// MARK: - Wandering herd canvas

/// Center ring with pixel cats. Radial (offline) or scattered (launch) layouts.
struct HerdWanderCanvas: View {
    enum Layout {
        /// Cats radiate from the ring — used by the offline empty state.
        case radial
        /// Cats are jittered across the canvas and stroll locally — launch overlay.
        case scattered
    }

    var catCount: Int = 6
    var layout: Layout = .radial
    /// Max radial travel for `.radial`. Ignored when scattered.
    var travelRadius: CGFloat = 124

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: reduceMotion || scenePhase != .active)) { timeline in
            Canvas { context, size in
                let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let ring = CGRect(x: center.x - 60, y: center.y - 36, width: 120, height: 72)
                context.stroke(Path(ellipseIn: ring), with: .color(Theme.border), lineWidth: 5)

                let count = max(1, catCount)
                switch layout {
                case .radial:
                    drawRadial(context: context, elapsed: elapsed, center: center, count: count)
                case .scattered:
                    drawScattered(context: context, elapsed: elapsed, size: size, count: count)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func drawRadial(
        context: GraphicsContext, elapsed: Double, center: CGPoint, count: Int
    ) {
        for index in 0..<count {
            let phase = reduceMotion
                ? 0.45 + Double(index % 3) * 0.15
                : (elapsed / 2.8 + Double(index) / Double(count))
                    .truncatingRemainder(dividingBy: 1)
            let angle = Double(index) * (.pi * 2) / Double(count) + 0.25
            let distance = 12 + phase * travelRadius
            let stride = reduceMotion ? 0 : [0, 2, 0, -2][Int(elapsed * 10 + Double(index)) % 4]
            let bounce = reduceMotion ? 0 : abs(sin(elapsed * 14 + Double(index))) * 3
            var cat = context
            cat.opacity = reduceMotion ? 1 : min(1, (1 - phase) * 5)
            cat.translateBy(
                x: center.x + cos(angle) * distance,
                y: center.y + sin(angle) * distance * 0.5 - bounce
            )
            cat.scaleBy(x: cos(angle) < 0 ? -2 : 2, y: 2)
            HerdCatSprite.draw(
                in: cat, fur: HerdCatSprite.furs[index % HerdCatSprite.furs.count], stride: stride
            )
        }
    }

    private func drawScattered(
        context: GraphicsContext, elapsed: Double, size: CGSize, count: Int
    ) {
        // Keep cats clear of the ring and the bottom message band.
        let marginX: CGFloat = 36
        let marginTop: CGFloat = 72
        let marginBottom: CGFloat = 110
        let usableW = max(1, size.width - marginX * 2)
        let usableH = max(1, size.height - marginTop - marginBottom)

        for index in 0..<count {
            let ux = Self.unit(index, salt: 1.17)
            let uy = Self.unit(index, salt: 7.91)
            let speed = Self.unit(index, salt: 3.33)
            let homeX = marginX + CGFloat(ux) * usableW
            let homeY = marginTop + CGFloat(uy) * usableH

            let wander = reduceMotion ? 0 : elapsed * (0.55 + speed * 0.9) + Double(index) * 1.7
            let dx = reduceMotion ? 0 : sin(wander) * (24 + uy * 52)
            let dy = reduceMotion ? 0 : cos(wander * 0.73 + ux * 2) * (14 + ux * 28)
            let stride = reduceMotion ? 0 : [0, 2, 0, -2][Int(elapsed * 10 + Double(index) * 1.3) % 4]
            let bounce = reduceMotion ? 0 : abs(sin(elapsed * 14 + Double(index))) * 3
            let facingLeft = dx < 0

            var cat = context
            cat.translateBy(x: homeX + dx, y: homeY + dy - bounce)
            cat.scaleBy(x: facingLeft ? -2 : 2, y: 2)
            HerdCatSprite.draw(
                in: cat, fur: HerdCatSprite.furs[index % HerdCatSprite.furs.count], stride: stride
            )
        }
    }

    /// Stable 0…1 hash so scatter positions stay fixed across launches.
    private static func unit(_ index: Int, salt: Double) -> Double {
        let value = sin(Double(index + 1) * 12.9898 + salt) * 43758.5453
        return value - floor(value)
    }
}

// MARK: - Launch herd loading

/// Full-screen wandering herd used during auto-connect handoff from the splash.
struct LaunchHerdLoadingView: View {
    let message: String

    var body: some View {
        ZStack {
            HerdWanderCanvas(catCount: 16, layout: .scattered)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            VStack {
                Spacer()
                Text(message)
                    .font(.jost(.footnote))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 48)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
        .accessibilityIdentifier("lazy-cat-loading")
    }
}

#Preview("Launch herd — dark") {
    LaunchHerdLoadingView(message: "Connecting…")
        .background(Theme.backgroundGradient)
        .preferredColorScheme(.dark)
}

// MARK: - Offline herd

/// Decorative motion stays local to the empty state and never drives networking.
struct OfflineHerdView: View {
    var body: some View {
        ConnectionRecoveryViewport {
            recoveryCard
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("offline-herd")
    }

    private var recoveryCard: some View {
        VStack(spacing: 12) {
            HerdWanderCanvas(catCount: 6, layout: .radial, travelRadius: 124)
                .frame(maxWidth: 320)
                .frame(height: 190)
                .clipped()

            Text("The herd got loose")
                .font(.jost(.headline))
            Text("You're offline. Reconnect to bring the cats back.")
                .font(.jost(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            ConnectionContentRetryButton()
        }
        .padding(24)
        .frame(maxWidth: 360)
        .modifier(PaneInputGlassSurface(cornerRadius: 24, backgroundOpacity: 0.98))
        .padding(16)
    }
}

#Preview("Offline herd") {
    OfflineHerdView()
        .background(Theme.backgroundGradient)
}

#Preview("Offline herd — dark") {
    OfflineHerdView()
        .background(Theme.backgroundGradient)
        .preferredColorScheme(.dark)
}

// MARK: - Working status icon

/// Keeps activity inside the status indicator instead of animating the card edge.
struct WorkingStatusIcon: View {
    var size: CGFloat = 14

    var body: some View {
        CircularArcSpinner(size: size)
            .accessibilityLabel("Working")
    }
}

// MARK: - Circular arc spinner

/// Unified circular arc spinner matching the Live activity style in yellow.
struct CircularArcSpinner: View {
    var label: String? = nil
    var size: CGFloat = 16
    var lineWidth: CGFloat? = nil
    var color: Color = AgentStatus.working.color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var effectiveLineWidth: CGFloat {
        lineWidth ?? max(1.5, size * 0.13)
    }

    var body: some View {
        let spinner = TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { context in
            let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.8) / 1.8
            Circle()
                .trim(from: 0.12, to: 0.82)
                .stroke(color, style: StrokeStyle(lineWidth: effectiveLineWidth, lineCap: .round))
                .rotationEffect(.degrees(phase * 360))
                .frame(width: size, height: size)
        }
        .accessibilityLabel(label ?? "Loading")

        if let label {
            VStack(spacing: 8) {
                spinner
                Text(label)
                    .font(.jost(.footnote))
                    .foregroundStyle(.secondary)
            }
        } else {
            spinner
        }
    }
}

extension CircularArcSpinner {
    init(_ label: String, size: CGFloat = 24, color: Color = AgentStatus.working.color) {
        self.label = label
        self.size = size
        self.lineWidth = nil
        self.color = color
    }
}
