import PhotosUI
import SwiftUI
import UIKit

// MARK: - Bar Mode & Modifier Enums

/// Visual and interaction modes of `PaneVoiceComposeBar`.
enum PaneVoiceComposeBarMode: String, CaseIterable, Identifiable, Sendable {
    case live
    case recording
    case compose

    var id: String { rawValue }
}

/// One-shot modifier keys available in Live input.
enum PaneLiveModifier: String, CaseIterable, Identifiable, Hashable, Sendable {
    case ctrl
    case alt
    case shift

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .ctrl: return "Ctrl"
        case .alt: return "Alt"
        case .shift: return "Shift"
        }
    }
}

/// Shared surface for pane input and offline recovery. Input controls keep
/// their plain style so the Live row does not turn into separate pills.
/// Uses the theme surface and border, with optional translucency.
struct PaneInputGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    var backgroundOpacity: Double = 1
    var usesGlassBorder = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle.continuous(cornerRadius)
        let opacity = reduceTransparency ? 1 : backgroundOpacity
        content
            .background {
                if usesGlassBorder && !reduceTransparency {
                    shape.fill(
                        Theme.cardBackground.opacity(opacity)
                            .shadow(.inner(
                                color: .black.opacity(colorScheme == .dark ? 0.16 : 0.035),
                                radius: 10, x: 0, y: 4
                            ))
                    )
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.05),
                            radius: 12, x: 0, y: 6)
                } else {
                    shape.fill(Theme.cardBackground.opacity(opacity))
                }
            }
            .overlay {
                if usesGlassBorder && !reduceTransparency {
                    // A fine outer rim and inset highlight give the edge depth
                    // while preserving the nearly opaque field background.
                    shape.strokeBorder(
                        .black.opacity(colorScheme == .dark ? 0.45 : 0.18),
                        lineWidth: 0.5
                    )
                    .allowsHitTesting(false)
                } else {
                    shape.strokeBorder(Theme.hairline, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if usesGlassBorder && !reduceTransparency {
                    shape.inset(by: 0.75).strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(colorScheme == .dark ? 0.4 : 0.95), location: 0),
                                .init(color: .clear, location: 0.15),
                                .init(color: .clear, location: 0.85),
                                .init(color: .white.opacity(colorScheme == .dark ? 0.35 : 0.85), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Attachment Info

/// Image attachment metadata for the Compose bar.
struct PaneAttachmentInfo: Identifiable, Sendable {
    var id: UUID
    var preview: UIImage
    var remotePath: String?
    var uploadError: String?
    var isUploading: Bool

    init(
        id: UUID = UUID(),
        preview: UIImage,
        remotePath: String? = nil,
        uploadError: String? = nil,
        isUploading: Bool = false
    ) {
        self.id = id
        self.preview = preview
        self.remotePath = remotePath
        self.uploadError = uploadError
        self.isUploading = isUploading
    }
}

enum PaneKeySwipeHintPreference {
    static let storageKey = "paneLiveKeySwipeHintDismissed.v1"
}

private struct PaneLiveKeyStripMetrics: Equatable {
    var minX: CGFloat = 0
    var contentWidth: CGFloat = 0
}

private struct PaneLiveKeyStripMetricsKey: PreferenceKey {
    static var defaultValue: PaneLiveKeyStripMetrics? = nil
    static func reduce(value: inout PaneLiveKeyStripMetrics?, nextValue: () -> PaneLiveKeyStripMetrics?) {
        if let next = nextValue() { value = next }
    }
}

// MARK: - PaneVoiceComposeBar

/// A unified SwiftUI input bar for Herdr terminal panes supporting:
/// 1. Live mode: swipeable terminal keys with fixed Image, Voice and Keyboard controls.
/// 2. Recording mode: cancel, a scrolling level waveform, Stop (edit in Compose), and Send.
/// 3. Compose mode: message bubble with editable 1-to-6-row field, external image picker,
///    Voice immediately left of Send, and Send hidden for blank/whitespace text.
struct PaneVoiceComposeBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsModelConfiguration = false
    var modelControl: AgentModelControlState? = nil
    var showsTerminalControls = false
    var onToggleLiveInput: (() -> Void)? = nil
    @State private var visibleKeyID: String?
    @State private var keyStripMetrics = PaneLiveKeyStripMetrics()
    @State private var keyStripViewportWidth: CGFloat = 0
    @State private var swipeStartOffset: CGFloat?
    @AppStorage(PaneKeySwipeHintPreference.storageKey) private var dismissedKeySwipeHint = false

    private func liveKeyWidth(for viewport: CGFloat) -> CGFloat {
        max(28, viewport / 7.5)
    }

    private var expectedKeyContentWidth: CGFloat {
        guard keyStripViewportWidth > 0 else { return 0 }
        return CGFloat(liveKeys.count) * liveKeyWidth(for: keyStripViewportWidth)
    }

    private var hasMoreKeysLeft: Bool { keyStripMetrics.minX < -2 }
    private var hasMoreKeysRight: Bool {
        keyStripMetrics.minX + expectedKeyContentWidth > keyStripViewportWidth + 2
    }
    private var keyStripOverflows: Bool { expectedKeyContentWidth > keyStripViewportWidth + 2 }

    private struct LiveKey: Identifiable {
        let id: String
        let label: String
        let token: String
        var modifier: PaneLiveModifier? = nil
    }

    /// Stable IDs keep repeated labels independent and retain the scroll position.
    private var liveKeys: [LiveKey] {
        [
            LiveKey(id: "esc", label: "Esc", token: "esc"),
            LiveKey(id: "tab", label: "Tab", token: "tab"),
            LiveKey(id: "up", label: "↑", token: "up"),
            LiveKey(id: "down", label: "↓", token: "down"),
            LiveKey(id: "left", label: "←", token: "left"),
            LiveKey(id: "right", label: "→", token: "right"),
            LiveKey(id: "ctrl", label: "Ctrl", token: "", modifier: .ctrl),
            LiveKey(id: "alt", label: "Alt", token: "", modifier: .alt),
            LiveKey(id: "home", label: "Home", token: "home"),
            LiveKey(id: "end", label: "End", token: "end"),
            LiveKey(id: "pageup", label: "Pg↑", token: "pageup"),
            LiveKey(id: "pagedown", label: "Pg↓", token: "pagedown"),
            LiveKey(id: "delete", label: "Del", token: "delete"),
            LiveKey(id: "insert", label: "Ins", token: "insert"),
            LiveKey(id: "backspace", label: "Bksp", token: "backspace"),
            LiveKey(id: "enter", label: "↵", token: "enter"),
            LiveKey(id: "shift", label: "Shift", token: "", modifier: .shift)
        ] + (1...12).map { LiveKey(id: "f\($0)", label: "F\($0)", token: "f\($0)") }
    }

    // Mode & Draft
    @Binding var mode: PaneVoiceComposeBarMode
    @Binding var draft: String

    // Focus state (explicit mode toggle and dismissal via gestures/hooks)
    @Binding var isLiveKeyboardFocused: Bool
    @FocusState.Binding var isComposeFieldFocused: Bool

    // Live row state & modifier routing to Pi/Cursor's PaneLiveModifierComposer
    var isLiveEnabled: Bool
    @Binding var armedModifiers: Set<PaneLiveModifier>
    var composeFieldIdentifier = "pane-compose-field"
    var composeSendIdentifier = "pane-compose-send-button"
    var onLiveKey: (String) -> Void
    var onLiveModifier: ((PaneLiveModifier) -> Void)?
    var onLiveEvent: (PaneLiveInputEvent) -> Void

    // Voice & Dictation (Pi owns dictation lifecycle and mode transitions)
    var dictation: PaneDictation?
    var isVoiceDraining: Bool
    @Binding var dictationError: String?
    var onStartVoice: () -> Void
    var onFinishVoice: () -> Void
    var onSendVoice: () -> Void
    var onCancelVoice: () -> Void
    var onOpenCompose: () -> Void

    // Photo & Attachment
    var photoItem: Binding<PhotosPickerItem?>?
    @Binding var isPhotoPickerPresented: Bool
    var attachment: PaneAttachmentInfo?
    var onRemoveAttachment: (() -> Void)?

    // Compose actions (visibility = hasDraftText || isSending; disabled = !canSend || isSending)
    var placeholder: String
    var canSend: Bool
    var isSending: Bool
    var onSend: () -> Void

    // Keyboard dismissal hook
    var onDismissKeyboard: (() -> Void)?

    init(
        mode: Binding<PaneVoiceComposeBarMode>,
        draft: Binding<String>,
        isLiveKeyboardFocused: Binding<Bool>,
        isComposeFieldFocused: FocusState<Bool>.Binding,
        isLiveEnabled: Bool = true,
        armedModifiers: Binding<Set<PaneLiveModifier>>,
        onLiveKey: @escaping (String) -> Void,
        onLiveModifier: ((PaneLiveModifier) -> Void)? = nil,
        onLiveEvent: @escaping (PaneLiveInputEvent) -> Void,
        dictation: PaneDictation? = nil,
        isVoiceDraining: Bool = false,
        dictationError: Binding<String?> = .constant(nil),
        onStartVoice: @escaping () -> Void,
        onFinishVoice: @escaping () -> Void,
        onSendVoice: @escaping () -> Void = {},
        onCancelVoice: @escaping () -> Void = {},
        onOpenCompose: @escaping () -> Void,
        photoItem: Binding<PhotosPickerItem?>? = nil,
        isPhotoPickerPresented: Binding<Bool>,
        attachment: PaneAttachmentInfo? = nil,
        onRemoveAttachment: (() -> Void)? = nil,
        placeholder: String = "Message the agent…",
        canSend: Bool = true,
        isSending: Bool = false,
        onSend: @escaping () -> Void,
        onDismissKeyboard: (() -> Void)? = nil
    ) {
#if DEBUG && targetEnvironment(simulator)
        if ScreenshotFixtures.enabled && ScreenshotFixtures.screen == "keys" {
            _visibleKeyID = State(initialValue: "f1")
        }
#endif
        self._mode = mode
        self._draft = draft
        self._isLiveKeyboardFocused = isLiveKeyboardFocused
        self._isComposeFieldFocused = isComposeFieldFocused
        self.isLiveEnabled = isLiveEnabled
        self._armedModifiers = armedModifiers
        self.onLiveKey = onLiveKey
        self.onLiveModifier = onLiveModifier
        self.onLiveEvent = onLiveEvent
        self.dictation = dictation
        self.isVoiceDraining = isVoiceDraining
        self._dictationError = dictationError
        self.onStartVoice = onStartVoice
        self.onFinishVoice = onFinishVoice
        self.onSendVoice = onSendVoice
        self.onCancelVoice = onCancelVoice
        self.onOpenCompose = onOpenCompose
        self.photoItem = photoItem
        self._isPhotoPickerPresented = isPhotoPickerPresented
        self.attachment = attachment
        self.onRemoveAttachment = onRemoveAttachment
        self.placeholder = placeholder
        self.canSend = canSend
        self.isSending = isSending
        self.onSend = onSend
        self.onDismissKeyboard = onDismissKeyboard
    }

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .live:
                liveBar
                    .modifier(PaneInputGlassSurface(cornerRadius: DesignSystem.CornerRadius.lg))
                    .transition(.opacity)
            case .recording:
                recordingBar
                    .transition(.opacity)
            case .compose:
                composeBar
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            // Invisible Live keyboard capture surface wired to live events
            PaneLiveKeyboardCaptureView(
                isEnabled: isLiveEnabled && mode == .live,
                isFocused: $isLiveKeyboardFocused,
                onCompositionChanged: nil,
                onEvent: { event in
                    onLiveEvent(event)
                }
            )
        }
        .animation(.snappy(duration: 0.22), value: mode)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pane-voice-compose-bar")
        .sheet(isPresented: $showsModelConfiguration) {
            if let modelControl { AgentModelConfigurationSheet(state: modelControl) }
        }
        .onChange(of: modelControl?.isVisible) { _, visible in
            if visible != true { showsModelConfiguration = false }
        }
    }

    // MARK: - 1. Live Mode Bar

    /// Only the left key area scrolls. Image, Voice and Keyboard stay fixed on the right.
    private var liveBar: some View {
        VStack(spacing: 4) {
            if !dismissedKeySwipeHint && keyStripOverflows {
                Text("Swipe for more keys")
                    .font(.jost(11, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 6)
                    .accessibilityIdentifier("pane-live-key-swipe-hint")
            }
            liveRail
        }
    }

    private var liveRail: some View {
        GeometryReader { railGeometry in
            // Fixed controls use the same cell width as the scrolling keys.
            let controlWidth = max(28, (railGeometry.size.width - 1) / 10.5)
            HStack(spacing: 0) {
                GeometryReader { geometry in
                    // Seven and a half equal cells leave Alt partially visible at rest.
                    let keyWidth = liveKeyWidth(for: geometry.size.width)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 0) {
                            ForEach(liveKeys) { key in
                                liveStripButton(key, width: keyWidth)
                                    .id(key.id)
                            }
                        }
                        .scrollTargetLayout()
                        .background {
                            GeometryReader { content in
                                Color.clear.preference(key: PaneLiveKeyStripMetricsKey.self,
                                    value: PaneLiveKeyStripMetrics(
                                        minX: content.frame(in: .named("pane-live-key-strip-space")).minX,
                                        contentWidth: content.size.width))
                            }
                        }
                    }
                    .coordinateSpace(name: "pane-live-key-strip-space")
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $visibleKeyID)
                    .simultaneousGesture(DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            if swipeStartOffset == nil && abs(value.translation.width) > 8 {
                                swipeStartOffset = keyStripMetrics.minX
                            }
                        }
                        .onEnded { _ in
                            if let start = swipeStartOffset,
                               abs(keyStripMetrics.minX - start) > 2 {
                                dismissedKeySwipeHint = true
                            }
                            swipeStartOffset = nil
                        })
                    .overlay(alignment: .leading) {
                        if hasMoreKeysLeft {
                            LinearGradient(colors: [Theme.cardBackground, .clear],
                                startPoint: .leading, endPoint: .trailing)
                                .frame(width: 8)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if hasMoreKeysRight {
                            LinearGradient(colors: [.clear, Theme.cardBackground],
                                startPoint: .leading, endPoint: .trailing)
                                .frame(width: 8)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .onAppear { keyStripViewportWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in keyStripViewportWidth = width }
                    .onPreferenceChange(PaneLiveKeyStripMetricsKey.self) { metrics in
                        guard let metrics else { return }
                        keyStripMetrics = metrics
                        if let start = swipeStartOffset, abs(metrics.minX - start) > 2 {
                            dismissedKeySwipeHint = true
                        }
                    }
                    .accessibilityIdentifier("pane-live-key-strip")
                    .accessibilityValue(hasMoreKeysLeft ?
                        (hasMoreKeysRight ? "More keys to left and right" : "More keys to left") :
                        (hasMoreKeysRight ? "More keys to right" : "All keys visible"))
                }
                .frame(minWidth: 0, maxWidth: .infinity)

                liveDivider

                photoPickerButton(width: controlWidth, height: 42)

                Button {
                    HapticFeedback.impact(.light)
                    onStartVoice()
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.jost(16, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: controlWidth, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSending)
                .accessibilityLabel("Start voice recording")
                .accessibilityIdentifier("pane-live-voice-button")

                // Explicitly toggle terminal input; a draft survives both directions.
                Button {
                    HapticFeedback.impact(.light)
                    if let onToggleLiveInput { onToggleLiveInput() }
                    else { onOpenCompose() }
                } label: {
                    Image(systemName: mode == .live ? "keyboard.fill" : "keyboard")
                        .font(.jost(16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: controlWidth, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode == .live ? "Turn off live input" : "Turn on live input")
                .accessibilityValue(mode == .live ? "Live input on" : "Live input off")
                .accessibilityIdentifier("pane-live-keyboard-button")
            }
        }
        .frame(height: 42)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pane-live-bar")
    }

    private func liveStripButton(_ key: LiveKey, width: CGFloat) -> some View {
        let isArmed = key.modifier.map { armedModifiers.contains($0) } ?? false
        return Button {
            HapticFeedback.impact(.light)
            if let modifier = key.modifier {
                if let onLiveModifier { onLiveModifier(modifier) }
                else if isArmed { armedModifiers.remove(modifier) }
                else { armedModifiers.insert(modifier) }
            } else {
                onLiveKey(key.token)
            }
        } label: {
            Text(key.label)
                .font(.jost(.caption, weight: .semibold).monospaced())
                .foregroundStyle(isArmed ? Theme.accent : (key.id == "esc" ? Theme.destructive : Color.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: width, height: 42)
                .background(isArmed ? Theme.accent.opacity(0.16) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isLiveEnabled)
        .opacity(isLiveEnabled ? 1 : 0.45)
        .accessibilityLabel(key.modifier.map { "\($0.displayLabel) modifier" } ?? "Send \(key.label)")
        .accessibilityValue(key.modifier == nil ? "" : (isArmed ? "Armed for next key" : "Off"))
        .accessibilityAddTraits(isArmed ? .isSelected : [])
        .accessibilityIdentifier(key.modifier == nil ?
            (key.id == "esc" ? "pane-live-key-esc" : key.id == "tab" ? "pane-live-key-tab" : key.id == "up" ? "pane-live-key-up" : "pane-live-extra-key-\(key.id)") :
            "pane-live-key-\(key.id)")
    }

    private var liveDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.22))
            .frame(width: 1, height: 24)
            .accessibilityHidden(true)
    }

    // MARK: - 2. Recording Mode Bar

    /// One row: cancel, live waveform, Stop, Send. Stop and Send both drain
    /// final recognition first; Pi owns finalization and the mode transition,
    /// opening Compose after Stop or sending the transcript after Send.
    private var recordingBar: some View {
        HStack(spacing: 10) {
            recordingCircleButton(systemName: "xmark", label: "Cancel recording",
                                  identifier: "pane-recording-cancel-button", action: onCancelVoice)
                .disabled(isVoiceDraining)

            VoiceWaveform(level: dictation?.audioLevel ?? 0, isActive: isRecordingActive)
                .frame(height: 36)
                .accessibilityElement()
                .accessibilityLabel(recordingAccessibilityLabel)
                .accessibilityIdentifier("pane-recording-waveform")

            if isVoiceDraining {
                ProgressView()
                    .frame(width: 34, height: 34)
                    .accessibilityLabel("Finishing dictation")
            } else {
                recordingCircleButton(systemName: "stop.fill", label: "Stop recording",
                                      identifier: "pane-recording-finish-button", action: onFinishVoice)
            }

            Button {
                HapticFeedback.impact(.light)
                onSendVoice()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.jost(34))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isVoiceDraining)
            .opacity(isVoiceDraining ? 0.45 : 1)
            .accessibilityLabel("Send recording")
            .accessibilityIdentifier("pane-recording-send-button")
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .modifier(PaneInputGlassSurface(cornerRadius: 25))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pane-recording-bar")
    }

    private func recordingCircleButton(systemName: String, label: String, identifier: String,
                                       action: @escaping () -> Void) -> some View {
        Button {
            HapticFeedback.impact(.light)
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.subtleFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var isRecordingActive: Bool {
        dictation?.isBusy == true && dictation?.isPreparing == false && !isVoiceDraining
    }

    private var recordingAccessibilityLabel: String {
        if isVoiceDraining { return "Finishing dictation" }
        if dictation?.isPreparing == true { return "Starting recording" }
        let text = dictation?.liveText ?? ""
        return text.isEmpty ? "Recording, listening" : "Recording, \(text)"
    }

    // MARK: - 3. Compose Mode Bar

    /// Terminal Compose has a message row above the shared key rail. Timeline
    /// keeps its existing message and model controls in the same glass card.
    private var composeBar: some View {
        VStack(spacing: 0) {
            if let attachment {
                attachmentChip(attachment)
            }

            // Conversation panes put the field on its own full-width row and
            // the photo, model and voice controls on the row under it. The
            // choice depends only on the surface, so the field keeps its
            // identity (and focus) when the model control appears.
            if showsTerminalControls {
                VStack(spacing: 0) {
                    HStack(alignment: .bottom, spacing: 4) {
                        messageField
                        sendButton
                    }
                    .padding(.horizontal, 8)
                    liveRail
                }
                .padding(.vertical, 4)
            } else if modelControl != nil {
                VStack(alignment: .leading, spacing: 0) {
                    messageField
                    HStack(alignment: .center, spacing: 4) {
                        photoPickerButton()
                        Spacer(minLength: 0)
                        messageActions
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    photoPickerButton()
                    messageBubble
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .modifier(PaneInputGlassSurface(
            cornerRadius: modelControl != nil ? 24 : DesignSystem.CornerRadius.lg,
            backgroundOpacity: modelControl != nil ? 0.98 : 1,
            usesGlassBorder: true
        ))
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    guard isComposeFieldFocused || isLiveKeyboardFocused,
                          value.translation.height > 5,
                          value.translation.height > abs(value.translation.width)
                    else { return }
                    isComposeFieldFocused = false
                    isLiveKeyboardFocused = false
                    onDismissKeyboard?()
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pane-compose-bar")
    }

    @ViewBuilder
    private func photoPickerButton(width: CGFloat = 38, height: CGFloat = 38) -> some View {
        if let photoItem {
            Button {
                isPhotoPickerPresented = true
            } label: {
                Image(systemName: "photo")
                    .font(.jost(height == 42 ? 16 : 20))
                    .foregroundStyle(Color.secondary)
                    .frame(width: width, height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .photosPicker(
                isPresented: $isPhotoPickerPresented,
                selection: photoItem,
                matching: .images,
                photoLibrary: .shared()
            )
            .disabled(isSending)
            .accessibilityLabel("Attach Image")
            .accessibilityIdentifier("pane-compose-attach-button")
        }
    }

    /// Send is visible if the draft has non-whitespace text OR a send is currently in progress.
    /// With the model control showing it stays visible (disabled while blank) so
    /// the action row keeps its shape; otherwise it hides for blank idle drafts.
    private var showsSendButton: Bool {
        isSending || modelControl?.isVisible == true
            || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var messageBubble: some View {
        HStack(alignment: .bottom, spacing: 4) {
            messageField
            messageActions
        }
        .padding(.trailing, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pane-compose-bubble")
    }

    private var messageField: some View {
        // Editable 1-to-6-row field
        TextField(placeholder, text: $draft, axis: .vertical)
            // Conversation composers match the timeline's body text size.
            .font(.jost(modelControl != nil ? .body : .subheadline))
            .lineLimit(1...6)
            .focused($isComposeFieldFocused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(false)
            .background(ComposeTextInputMarker())
            .disabled(isSending)
            .submitLabel(.send)
            .onSubmit {
                guard canSend && !isSending else { return }
                onSend()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .accessibilityLabel("Message text")
            .accessibilityIdentifier(composeFieldIdentifier)
    }

    @ViewBuilder private var messageActions: some View {
        if let modelControl, modelControl.isVisible {
            Button { showsModelConfiguration = true } label: {
                (Text(modelControl.modelName).bold()
                    + Text(modelControl.effortText.map { " " + $0 } ?? ""))
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.jost(.subheadline))
                .foregroundStyle(Color.secondary)
                // Hug the text: the mic glyph sits ~10pt inside its 32pt frame and
                // Send's circle ~4pt inside its 34pt frame, so 3pt here makes the
                // label-to-mic gap match the mic-to-Send gap (measured ~18pt each).
                .padding(.trailing, 3)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(-1)
            .accessibilityLabel(modelControl.accessibilityLabel)
            .accessibilityHint("Configure model and effort")
            .accessibilityIdentifier("timeline-model-control")
        }

        // Voice button inside bubble, immediately left of Send
        Button {
            HapticFeedback.impact(.light)
            onStartVoice()
        } label: {
            Image(systemName: "mic.fill")
                .font(.jost(18))
                .foregroundStyle(Color.secondary)
                .frame(width: 32, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSending)
        .accessibilityLabel("Dictate message")
        .accessibilityIdentifier("pane-compose-voice-button")
        .fixedSize()

        sendButton
    }

    @ViewBuilder private var sendButton: some View {
        // Send button: visible when text is present or when sending; shows spinner during send
        if showsSendButton {
            Button {
                HapticFeedback.impact(.light)
                onSend()
            } label: {
                Group {
                    if isSending {
                        CircularArcSpinner(size: 18)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.jost(26))
                            .foregroundStyle(canSend ? Theme.accent : Color.secondary)
                    }
                }
                .frame(width: 34, height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend || isSending)
            .accessibilityLabel("Send Message")
            .accessibilityIdentifier(composeSendIdentifier)
            .fixedSize()
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
    }

    private func attachmentChip(_ attachment: PaneAttachmentInfo) -> some View {
        HStack(spacing: 10) {
            Image(uiImage: attachment.preview)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle.continuous(DesignSystem.CornerRadius.sm))

            VStack(alignment: .leading, spacing: 2) {
                if attachment.isUploading {
                    Text("Uploading…")
                        .font(.jost(.caption, weight: .medium))
                    CircularArcSpinner(size: 12)
                } else if let error = attachment.uploadError {
                    Text(error)
                        .font(.jost(.caption))
                        .foregroundStyle(Theme.destructive)
                        .lineLimit(2)
                } else if let path = attachment.remotePath {
                    Text("Image ready")
                        .font(.jost(.caption, weight: .medium))
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.jost(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Image attached")
                        .font(.jost(.caption, weight: .medium))
                }
            }
            Spacer(minLength: 0)
            Button {
                onRemoveAttachment?()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.jost(18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove Attached Image")
            .accessibilityIdentifier("pane-attachment-remove-button")
        }
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pane-attachment-chip")
    }
}


private struct AgentModelConfigurationSheet: View {
    let state: AgentModelControlState
    @State private var path: [String] = []
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    NavigationLink(value: "Model") {
                        row("Model", value: state.pair.model == nil ? "Unknown" : state.modelName)
                    }
                    .accessibilityIdentifier("model-configuration-model")
                    if !state.efforts.isEmpty {
                        NavigationLink(value: "Effort") {
                            row("Effort", value: state.effortLabel)
                        }
                        .accessibilityIdentifier("model-configuration-effort")
                    }
                }
                .listRowBackground(Theme.cardBackground)
                .disabled(state.isChanging)
                catalogStatus
                if state.persistsAcrossSessions {
                    Section {} footer: {
                        Text("Cursor saves this choice to its own settings, so it also applies to new Cursor sessions on this computer.")
                            .accessibilityIdentifier("model-persists-note")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
            .background(Theme.background)
            .navigationTitle("Configure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The app's spinner sits in front of the title while a change applies.
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        if state.isChanging { CircularArcSpinner(size: 14) }
                        Text("Configure").font(.jost(.headline))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
            }
            .navigationDestination(for: String.self) { destination in
                List {
                    if destination == "Model" {
                        catalogStatus
                        ForEach(state.models) { model in
                            option(model.label, selected: state.selectedModelID == model.id) {
                                Task { await state.change(model: model.id) }
                            }
                        }
                    } else {
                        ForEach(state.efforts) { effort in
                            option(effort.label, selected: state.pair.effort == effort.id) {
                                Task { await state.change(effort: effort.id) }
                            }
                        }
                    }
                }
                .disabled(state.isChanging || state.isLoadingModels)
                .scrollContentBackground(.hidden)
                .background(Theme.background)
                .navigationTitle(destination)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .bottomNotice { catalogNotice }
        .font(.jost(.body))
        .tint(Theme.accent)
        .presentationDetents(path.isEmpty && !typeSize.isAccessibilitySize && !hasCatalogNotice ? [.height(300)] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await state.refresh() }
    }

    @ViewBuilder private var catalogStatus: some View {
        if state.isLoadingModels {
            HStack(spacing: 10) {
                ProgressView().accessibilityLabel("Loading model choices")
                Text("Loading model choices…")
            }
            .listRowBackground(Theme.cardBackground)
        }
    }

    private var hasCatalogNotice: Bool {
        !state.isLoadingModels && (state.errorMessage != nil || state.models.isEmpty || state.catalogInfo?.note != nil)
    }

    @ViewBuilder private var catalogNotice: some View {
        if hasCatalogNotice {
            RecoveryNotice(title: state.errorMessage == nil ? "Model choices" : "Couldn't load model choices", systemImage: "slider.horizontal.3", identifier: "model-choices-notice") {
                if let error = state.errorMessage {
                    Text(error).accessibilityIdentifier("model-choices-error")
                } else if state.models.isEmpty {
                    Text("Model choices haven't loaded yet.")
                } else if let note = state.catalogInfo?.note {
                    Text(note).accessibilityIdentifier("model-choices-catalog-note")
                }
            } actions: {
                Button("Retry") { Task { await state.refresh() } }
                    .disabled(state.isChanging || state.isLoadingModels)
                    .accessibilityIdentifier("model-choices-retry")
            }
            .padding(.vertical, 4)
        }
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.text)
            Spacer()
            Text(value).foregroundStyle(Theme.textMuted).multilineTextAlignment(.trailing)
        }
    }
    private func option(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            path = []
            action()
        } label: {
            HStack {
                Text(label).foregroundStyle(Theme.text)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
        }
        .listRowBackground(Theme.cardBackground)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
