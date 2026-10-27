import SwiftUI

/// The expanded recording surface: a fluid level visualizer behind the live
/// transcript, with exactly one action, the checkmark that finishes dictation.
struct VoiceRecordingPanel: View {
    enum Phase: Equatable {
        case preparing
        case recording
        case finishing
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var phase: Phase
    var level: Float
    /// Full merged transcript; `partial` is its trailing, not-yet-final suffix.
    var text: String
    var partial: String
    var onFinish: () -> Void

    static let height: CGFloat = 248

    var body: some View {
        let shape = RoundedRectangle.continuous(DesignSystem.CornerRadius.lg)
        ZStack {
            FluidAudioVisualizer(level: level, isActive: phase == .recording)
            VStack(alignment: .leading, spacing: 8) {
                statusRow
                transcript
                HStack {
                    Spacer(minLength: 0)
                    finishButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
        }
        .frame(height: Self.height)
        .background(shape.fill(Theme.cardBackground))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.hairline, lineWidth: reduceTransparency ? 1 : 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pane-recording-bar")
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            indicator
            Text(statusText)
                .font(.jost(.subheadline, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityHidden(true)
    }

    private var statusText: String {
        switch phase {
        case .preparing: return "Starting…"
        case .recording: return "Recording"
        case .finishing: return "Finishing…"
        }
    }

    private var indicator: some View {
        ZStack {
            if phase == .recording && !reduceMotion {
                Circle()
                    .fill(Theme.destructive.opacity(0.4))
                    .frame(width: 18, height: 18)
                    .phaseAnimator([false, true]) { content, expanded in
                        content
                            .scaleEffect(expanded ? 1.5 : 0.6)
                            .opacity(expanded ? 0 : 0.9)
                    } animation: { expanded in
                        expanded ? .easeOut(duration: 1.15) : .linear(duration: 0.01)
                    }
            }
            Circle()
                .fill(phase == .recording ? Theme.destructive : Color.secondary)
                .frame(width: 8, height: 8)
        }
        .frame(width: 18, height: 18)
    }

    private var committed: Substring {
        guard !partial.isEmpty, text.hasSuffix(partial) else { return Substring(text) }
        return text.dropLast(partial.count)
    }

    private var placeholder: String? {
        guard text.isEmpty else { return nil }
        switch phase {
        case .preparing: return nil
        case .recording: return "Listening…"
        case .finishing: return nil
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    if let placeholder {
                        Text(placeholder)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(committed).foregroundStyle(Theme.text)
                            + Text(text.dropFirst(committed.count))
                            .foregroundStyle(Theme.text.opacity(0.55))
                    }
                }
                .font(.jost(.title3, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                Color.clear.frame(height: 1).id("end")
            }
            .defaultScrollAnchor(.bottom)
            .scrollDisabled(text.isEmpty)
            .onChange(of: text) {
                if reduceMotion {
                    proxy.scrollTo("end", anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                   .init(color: .black, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTranscript)
        .accessibilityIdentifier("pane-recording-transcript")
    }

    private var accessibilityTranscript: String {
        switch phase {
        case .preparing: return "Starting recording"
        case .finishing: return text.isEmpty ? "Finishing recording" : "Finishing recording, \(text)"
        case .recording: return text.isEmpty ? "Recording, listening" : "Recording, \(text)"
        }
    }

    private var finishButton: some View {
        Button {
            HapticFeedback.impact(.light)
            onFinish()
        } label: {
            Image(systemName: "checkmark.circle.fill")
                .font(.jost(34))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(phase == .finishing)
        .accessibilityLabel("Finish recording")
        .accessibilityIdentifier("pane-recording-finish-button")
    }
}

/// Grows the recording panel up out of the composer row.
struct VoiceRecordingPanelReveal: ViewModifier {
    var isCollapsed: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: isCollapsed ? 0.2 : 1, anchor: .bottom)
            .opacity(isCollapsed ? 0 : 1)
    }
}

#Preview {
    VStack {
        Spacer()
        VoiceRecordingPanel(phase: .recording, level: 0.5,
                            text: "Split the reconnect logic into its own type and add a test",
                            partial: "and add a test", onFinish: {})
            .padding()
    }
    .background(Theme.background)
}
