import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import QuickLook

@MainActor final class TimelineEntryFrameStore {
    var frames: [String: CGRect] = [:]
}

/// Native session content; the owning pane supplies its composition dock.
struct AgentTimelineView: View {
    let paneId: String
    var agent: String? = nil
    let connection: HerdrConnection
    let timeline: AgentTimelineState
    var bridgeUpgrade: TimelineBridgeUpgrade = TimelineBridgeUpgrade()
    let topOverlayInset: CGFloat
    let bottomOverlayInset: CGFloat
    let onOutputInteraction: () -> Void
    let setupTarget: ConnectionIdentity
    let onUseTerminal: () -> Void
    let onSetupComplete: () -> Void
    var onFocusComposer: () -> Void = {}
    /// Herdr's status for this pane; gates typing `/reload` into Pi.
    var paneAgentStatus: String? = nil
    /// Shows Terminal for this pane without remembering a Terminal preference.
    var onOpenTerminal: () -> Void = {}
    @Environment(AppModel.self) var appModel
    @Environment(ActiveMachine.self) var activeMachine: ActiveMachine?
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State var waitingKey: WaitingTaskKey?
    @State var phoneAnswersSelection: PhoneAnswersSelection?
    @State var approvalResponse = ApprovalResponseState()
    @State var questionResponse = QuestionAnswerState()
    @State var waitingRowHeight: CGFloat = 0
    @State var sheetState = TimelineSheetState()
    @State var approvalViewVisible = false
    @State var activeClient: AgentBridgeClient?
    @State var activeOwner: UUID?
    @State var showsSetup = false
    @State var setupReason: HostHelperSetupReason = .missing
    @State var setupShouldUseTerminal = true
    @State var isCheckingSetup = false
    @State var setupFeedback: String?
    @State var helperStage: HostHelperSetupStage = .idle
    @State var helperInstallTask: Task<Void, Never>?
    @State var helperInstallToken: UUID?
    @State var fixtureHelperInstalled = false
    @State var helperMayHaveInstalled = false
    @State var retry = 0
    @State private var contentFiles = TimelineContentFiles()
    @State var historyLoader = TimelineHistoryLoader()
    @State var isPaging = false
    @State var pageError: String?
    @State var following = true
    @State var atBottom = true
    @State private var piScrollPosition = PiTimelineScrollPosition()
    @State private var latestScrollRequest = 0
    @State private var tailVisible = false
    @State private var tailLayoutEpoch = 0
    @State private var recoveredTailRequest = -1
    @State private var tailReplayScope: String?
    @State var entryFrames = TimelineEntryFrameStore()
    @State var viewportHeight: CGFloat = 0
    @State private var focusedQuestionField: QuestionFieldTarget?
    @State private var questionFieldFrames: [QuestionFieldTarget: CGRect] = [:]
    @State private var questionKeyboardFrame: CGRect = .null
    @State var historyScrollAnchor: TimelineHistoryScrollAnchor?
    @State var bridgeCapabilities: AgentBridgeCapabilities?
    @State var bridgeVersion: String?
    @State var showsCodexDaemonConfirm = false
    @State var isDisablingCodexDaemon = false
    @State var codexDaemonStopOutcome: CodexDaemonStopOutcome?
    /// Episode token for the recorded outcome: bumped on every clear, so a
    /// stop command still in flight can detect that its episode ended.
    @State var codexDaemonEpisode = 0
    /// Sequence of `codex_daemon` report changes; lets a completing stop tell
    /// an unchanged pre-stop report from one that changed while it ran.
    @State var codexDaemonReportSeq = 0
    @State var copiedCodexConfig = false
    @State var copiedCodexStop = false
    @State var copiedCodexUpdaterStop = false
    @State var piExtension: PiExtensionResult?
    @State var isRunningPiExtension = false
    @State var piExtensionFeedback: String?

    var approvalInset: CGFloat { showsWaitingRow ? waitingRowHeight + 8 : 0 }
    private var hooksKey: PhoneAnswersStore.Key? {
        #if DEBUG && targetEnvironment(simulator)
        if ScreenshotFixtures.enabled && ScreenshotFixtures.screen == "timeline-audit-hooks" {
            return .init(target: setupTarget, generation: .init(rawValue: 1), agent: "codex")
        }
        #endif
        guard let generation = connectionState.generation,
            let agent = timeline.identity?.agent, ApprovalAgent(rawValue: agent) != nil else { return nil }
        return .init(target: setupTarget, generation: generation, agent: agent)
    }
    struct WaitingTaskKey: Equatable {
        let hooks: PhoneAnswersStore.Key?
        let owner: UUID?
        let identity: AgentTimelineIdentity?
        let generation: UInt64?
        let eligible: Bool
    }
    var waitingTaskKey: WaitingTaskKey {
        WaitingTaskKey(hooks: hooksKey, owner: activeOwner, identity: timeline.identity, generation: timeline.generation,
            eligible: PhoneAnswersPresentation.eligible(approvals: bridgeCapabilities?.approvals,
                ready: matchesLiveTimeline && timeline.phase == .ready && connectionState.isReady,
                blocked: timeline.agentStatus == "blocked", pending: timeline.pendingApproval != nil || showsQuestion,
                active: scenePhase == .active && appModel.isSceneActive))
    }
    private var showsWaitingRow: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if ScreenshotFixtures.enabled && ScreenshotFixtures.screen == "timeline-audit-hooks" { return true }
        #endif
        return waitingTaskKey.eligible && waitingKey == waitingTaskKey
    }
    func hooksContextIsCurrent(_ key: PhoneAnswersStore.Key) -> Bool {
        matchesLiveTimeline && scenePhase == .active && appModel.isSceneActive && connectionState.isReady
            && setupTarget == key.target && connectionState.generation == key.generation
            && bridgeCapabilities?.approvals == true
    }
    var matchesLiveTimeline: Bool { timeline.matchesLivePane(paneId: paneId, agent: agent, connection: connectionState) }

    var showsApproval: Bool {
        matchesLiveTimeline && scenePhase == .active && connectionState.isReady && timeline.phase == .ready
            && ApprovalResponseState.isVisible(pending: timeline.pendingApproval, approvals: bridgeCapabilities?.approvals)
    }

    var showsQuestion: Bool {
        matchesLiveTimeline && scenePhase == .active && connectionState.isReady && timeline.phase == .ready
            && QuestionAnswerState.isVisible(pending: timeline.pendingQuestion, questions: bridgeCapabilities?.questions)
    }

    var conversationItems: [TimelineConversationItem] {
        TimelineConversationItem.group(timeline.visibleEntries, showsRecords: agent == "codex" || agent == "pi")
    }

    var connectionState: AgentTimelineConnectionState {
        AgentTimelineConnectionState(
            phase: appModel.phase, generation: appModel.ownership.transportGeneration)
    }
    struct TaskKey: Equatable {
        let paneId: String
        let agent: String?
        let connection: AgentTimelineConnectionState
        let isActive: Bool
        let retry: Int
    }
    var taskKey: TaskKey {
        TaskKey(paneId: paneId, agent: agent, connection: connectionState, isActive: scenePhase == .active, retry: retry)
    }
    var canPinnedInstallerSupportAgent: Bool {
        Self.canPinnedInstallerSupport(agent: agent)
    }
    static func canPinnedInstallerSupport(agent: String?, supportedAgents: Set<String> = Set(HostHelperSetupPlan.agents)) -> Bool {
        agent.map { supportedAgents.contains(TimelineAgentAvailability.canonical($0) ?? $0) } ?? true
    }
    static func installLabel(
        stage: HostHelperSetupStage,
        reason: HostHelperSetupReason = .missing,
        pinnedVersion: String = HostHelperSetupPlan.version
    ) -> String {
        HostHelperSetupPlan.installLabel(stage: stage, reason: reason, pinnedVersion: pinnedVersion)
    }
    static func replacementFeedback(probe: HostHelperProbe) -> String? {
        HostHelperSetupPlan.replacementFeedback(probe: probe)
    }
    private func revealQuestionField(using proxy: ScrollViewProxy, viewport: GeometryProxy) {
        guard let target = focusedQuestionField, showsQuestion,
              target.scope == contentScope,
              target.requestId == timeline.pendingQuestion?.requestId else { return }
        let height = viewport.size.height
        let viewportFrame = viewport.frame(in: .global)
        var visibleBottom = height - viewport.safeAreaInsets.bottom
        if questionKeyboardFrame.intersects(viewportFrame) {
            visibleBottom = min(visibleBottom, questionKeyboardFrame.minY - viewportFrame.minY)
        }
        let top = topOverlayInset + 8
        let bottom = visibleBottom - bottomOverlayInset - approvalInset - 8
        if let frame = questionFieldFrames[target], frame.minY >= top, frame.maxY <= bottom { return }
        // Center the selected field in the usable area, not the card's bottom:
        // a later question can be much taller than the keyboard viewport.
        let anchorY = height > 0 ? max(0, min(1, (top + max(top, bottom)) / (2 * height))) : 0.5
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
            proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: anchorY))
        }
    }

    private var usesPiMessageList: Bool { agent == "pi" }

    @ViewBuilder private var messageRows: some View {
        if timeline.hasSnapshot(for: connectionState, paneId: paneId, agent: agent) {
            if timeline.hasMore {
                Text(isPaging ? "Loading earlier messages…" : (pageError ?? "Pull down to load earlier messages"))
                    .font(.jost(.caption))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("timeline-history-hint")
                    .accessibilityAction(named: "Load earlier messages") {
                        Task { await refreshHistory() }
                    }
            }
            if conversationItems.isEmpty {
                ContentUnavailableView("No messages yet", systemImage: "bubble.left")
            }
            ForEach(conversationItems) { item in
                let scope = contentScope
                Group {
                    if item.isActivity {
                        TimelineActivityView(entries: item.entries,
                            loadContent: { reference in try await loadContent(reference, scope: scope) })
                    } else if let entry = item.entries.first {
                        AgentTimelineEntryView(entry: entry, files: contentFiles, scope: scope,
                            loadContent: { reference in try await loadContent(reference, scope: scope) })
                    }
                }
                .background {
                    GeometryReader { row in
                        Color.clear.preference(
                            key: TimelineEntryFramesPreferenceKey.self,
                            value: [item.id: row.frame(in: .named("timeline-viewport"))])
                    }
                }
            }
            if timeline.delayed {
                Text("Source update delayed; showing verified history.")
                    .font(.jost(.caption)).foregroundStyle(Theme.textMuted)
            }
            if let dialog = timeline.pendingPiDialog {
                PiDialogCard(dialog: dialog, isSending: timeline.isPiActionPending,
                    onSubmit: { answer in Task { await timeline.respondPiDialog(dialog, value: answer) } },
                    onUseTerminal: onUseTerminal)
                    .id("\(contentScope):pi-dialog:\(dialog.requestId)")
            }
            if let message = timeline.piActionError {
                Text(message).font(.jost(.caption)).foregroundStyle(Theme.textMuted)
            }
            if showsApproval, let pending = timeline.pendingApproval {
                ApprovalCard(pending: pending, response: approvalResponse) { option in
                    respondToApproval(pending, option: option)
                }
                .id("\(contentScope):approval:\(pending.requestId)")
                .disabled(approvalResponse.isDisabled)
            }
            if showsQuestion, let pending = timeline.pendingQuestion {
                let questionScope = contentScope
                QuestionCard(pending: pending, response: questionResponse,
                    onSubmit: { respondToQuestion(pending) },
                    onSkip: { respondToQuestion(pending, skip: true) },
                    scope: questionScope,
                    onFieldFocus: { target in
                        if let target {
                            guard target.scope == contentScope,
                                  target.requestId == timeline.pendingQuestion?.requestId else { return }
                            focusedQuestionField = target
                        } else if focusedQuestionField?.scope == questionScope,
                                  focusedQuestionField?.requestId == pending.requestId {
                            focusedQuestionField = nil
                        }
                    })
                    .id("\(contentScope):question:\(pending.requestId)")
            }
        } else {
            availability
        }
        Color.clear.frame(height: 0).id("timeline-bottom")
    }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                let firstID = conversationItems.first?.id
                let lastID = conversationItems.last?.id
                Group {
                    if usesPiMessageList {
                        PiTimelineMessageList(
                            position: piScrollPosition,
                            following: following,
                            bottomInset: bottomScrollMargin,
                            onViewport: { frames, bottom in
                                entryFrames.frames = frames
                                let visible = lastID.flatMap { frames[$0] }.map(tailIntersectsViewport) ?? false
                                if tailVisible != visible { tailVisible = visible }
                                if atBottom != bottom { atBottom = bottom }
                                if bottom && !following { following = true }
                            },
                            onDrag: {
                                following = false
                                onOutputInteraction()
                            },
                            onPull: {
                                let firstFrame = firstID.flatMap { entryFrames.frames[$0] }
                                if firstFrame.map({ $0.minY >= topOverlayInset - 8 }) ?? (firstID == nil),
                                   timeline.hasMore {
                                    Task { await refreshHistory() }
                                }
                            }
                        ) {
                            VStack(alignment: .leading, spacing: 16) { messageRows }
                                .padding([.horizontal, .top], DesignSystem.Spacing.base)
                                .padding(.top, topOverlayInset)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .coordinateSpace(name: "timeline-viewport")
                                .environment(appModel)
                        }
                    } else {
                        swiftUIMessageList(viewport: viewport, proxy: proxy)
                    }
                }
                .onChange(of: viewport.size.height, initial: true) { _, height in
                    viewportHeight = height
                    if focusedQuestionField != nil {
                        revealQuestionField(using: proxy, viewport: viewport)
                    } else if following && showsApproval { scrollToLatest(using: proxy) }
                }
                .onChange(of: viewport.safeAreaInsets.bottom) { _, _ in
                    revealQuestionField(using: proxy, viewport: viewport)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                    guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                    questionKeyboardFrame = frame
                    revealQuestionField(using: proxy, viewport: viewport)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                    questionKeyboardFrame = .null
                }
                .onChange(of: timeline.pendingPiDialog?.requestId, initial: true) { _, requestId in
                    guard requestId != nil else { return }
                    following = true
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) {
                        scrollToLatest(using: proxy)
                    }
                }
                .onChange(of: timeline.pendingApproval?.requestId, initial: true) { _, requestId in
                    guard requestId != nil, showsApproval else { return }
                    following = true
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) {
                        scrollToLatest(using: proxy)
                    }
                }
                .onChange(of: showsQuestion ? timeline.pendingQuestion?.requestId : nil, initial: true) { _, requestId in
                    focusedQuestionField = nil
                    guard requestId != nil, showsQuestion else { return }
                    following = true
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) {
                        scrollToLatest(using: proxy)
                    }
                }
                .onChange(of: focusedQuestionField) { _, target in
                    guard target != nil else { return }
                    following = false
                    revealQuestionField(using: proxy, viewport: viewport)
                }
                .onChange(of: contentScope) { _, _ in
                    focusedQuestionField = nil
                    questionFieldFrames = [:]
                }
                .onPreferenceChange(QuestionFieldFramesPreferenceKey.self) { frames in
                    questionFieldFrames = frames
                    revealQuestionField(using: proxy, viewport: viewport)
                }
                .onChange(of: historyScrollAnchor) { _, anchor in
                    guard let anchor else { return }
                    following = false
                    if usesPiMessageList {
                        piScrollPosition.prependAnchor = anchor
                        return
                    }
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(anchor.id, anchor: UnitPoint(x: 0, y: anchor.unitY))
                    }
                }
                .onChange(of: timeline.revision) { _, _ in
                    guard following, timeline.pendingQuestion == nil, timeline.pendingPiDialog == nil, (!conversationItems.isEmpty || showsApproval) else { return }
                    scrollToLatest(using: proxy)
                }
                .onChange(of: contentScope) { _, _ in
                    following = true
                    #if DEBUG && targetEnvironment(simulator)
                        if ScreenshotFixtures.enabled && ScreenshotFixtures.screen == "timeline-history-position",
                           timeline.generation == 1 {
                            following = false
                        }
                    #endif
                }
                .onChange(of: bottomOverlayInset) { _, _ in
                    if focusedQuestionField != nil {
                        revealQuestionField(using: proxy, viewport: viewport)
                    } else if following && (!conversationItems.isEmpty || showsApproval) {
                        scrollToLatest(using: proxy)
                    }
                }
                .onChange(of: approvalInset) { _, _ in
                    if focusedQuestionField != nil {
                        revealQuestionField(using: proxy, viewport: viewport)
                    } else if following && (!conversationItems.isEmpty || showsApproval) {
                        scrollToLatest(using: proxy)
                    }
                }
                .overlay(alignment: .bottom) {
                    if showsAvailabilityNotice, !timeline.hasSnapshot(for: connectionState, paneId: paneId, agent: agent) {
                        NoticeViewport(
                            maximumHeight: viewport.size.height - topOverlayInset - bottomOverlayInset - 16,
                            identifier: "timeline-exception-scroll"
                        ) {
                            availabilityNotice.padding(.vertical, 4)
                        }
                        .padding(.top, topOverlayInset + 8)
                        .padding(.bottom, bottomOverlayInset + 8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Group {
                    if (!atBottom || (!tailVisible && !conversationItems.isEmpty && latestTargetID != "timeline-bottom")) && timeline.phase == .ready {
                        Button {
                            following = true
                            scrollToLatest(using: proxy)
                        } label: {
                            latestIcon
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Jump to latest messages")
                        .accessibilityIdentifier("timeline-latest")
                        .padding(.trailing, 16)
                        .padding(.bottom, bottomOverlayInset + approvalInset + 8)
                        .transition(.opacity)
                    }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: !atBottom && timeline.phase == .ready)
                }
            }
        }
        // Rebuild stale lazy geometry only for a new source or a blank Latest
        // destination. Ordinary history prepends retain their reading anchor.
        .id("\(contentScope):\(tailLayoutEpoch)")
        // Let messages scroll behind the pane cards, but keep them below
        // the navigation bar and status area.
        .overlay(alignment: .bottom) {
            Group {
                if showsWaitingRow, let key = hooksKey, let agent = ApprovalAgent(rawValue: key.agent) {
                    NoticeViewport(
                        maximumHeight: viewportHeight - topOverlayInset - bottomOverlayInset - 16,
                        identifier: "phone-answers-notice-scroll"
                    ) {
                        PhoneAnswersWaitingRow(agent: agent, result: appModel.phoneAnswers.result(for: key)) { mode in
                            phoneAnswersSelection = PhoneAnswersSelection(key: key, mode: mode)
                        }
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { waitingRowHeight = $0 }
            .padding(.bottom, bottomOverlayInset + 8)
        }
        .clipped()
        .background(Theme.background)
        .onChange(of: timeline.pendingApproval, initial: true) { _, pending in approvalResponse.sync(pending) }
        .onChange(of: timeline.pendingQuestion, initial: true) { _, pending in questionResponse.sync(pending) }
        .task(id: taskKey) { await run() }
        .task(id: "\(activeClient?.id.uuidString ?? "none"):\(contentScope)") {
            #if DEBUG && targetEnvironment(simulator)
            // The picker fixture owns its first failing discovery, then Retry
            // succeeds. A background read must not consume that scripted failure.
            if ScreenshotFixtures.enabled && ScreenshotFixtures.screen == "timeline-model-agy-retry" { return }
            #endif
            await timeline.modelControl.refresh()
        }
        .task(id: waitingTaskKey) { await prepareWaitingRow() }
        .onAppear { approvalViewVisible = true; updateTimelineSheet() }
        .onChange(of: bridgeCapabilities?.approvals) { _, _ in updateTimelineSheet() }
        .onChange(of: phoneAnswersSelection?.id) { _, _ in updateTimelineSheet() }
        .onChange(of: showsSetup) { _, _ in updateTimelineSheet() }
        .onChange(of: showsCodexDaemonConfirm) { _, _ in updateTimelineSheet() }
        .onChange(of: timeline.revision, initial: true) { _, _ in
            switch timeline.phase {
            case .ready:
                onSetupComplete()
                isCheckingSetup = false
                if showsSetup {
                    setupShouldUseTerminal = false
                    showsSetup = false
                }
            case .unavailable(let code):
                if isCheckingSetup {
                    isCheckingSetup = false
                    setupFeedback = code == "helper_missing"
                        ? "Herdcats Bridge was not found yet. Run the command on your SSH host, then check again."
                        : explanation(code)
                }
                let isNeedsUpgrade = Self.isNeedsUpgrade(code: code, agent: agent, bridgeVersion: bridgeVersion)
                let isMissing = code == "helper_missing"
                if (isMissing || isNeedsUpgrade) && !showsSetup && canPinnedInstallerSupportAgent {
                    #if DEBUG && targetEnvironment(simulator)
                    if ScreenshotFixtures.enabled && ProcessInfo.processInfo.arguments.contains("-hc.timeline-suppress-drawer") {
                        // Suppress drawer auto-presentation for pane screenshots
                    } else {
                        beginSetup(reason: isNeedsUpgrade ? .updateRequired : .missing)
                    }
                    #else
                    beginSetup(reason: isNeedsUpgrade ? .updateRequired : .missing)
                    #endif
                }
            case .disconnected:
                if isCheckingSetup {
                    isCheckingSetup = false
                    setupFeedback = "Reconnect to your SSH host, then check again."
                }
            case .loading, .suspended: break
            }
        }
        .onChange(of: connectionState) { _, _ in cancelHelperInstallation() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancelHelperInstallation() } }
        .onChange(of: timeline.phase) { _, newPhase in
            // A stop result only describes the no-session episode it answered;
            // a later episode (after the pane was ready again) starts fresh.
            if !Self.codexDaemonResultIsCurrent(phase: newPhase) { clearCodexDaemonResult() }
            dismissStaleCodexDaemonConfirm()
        }
        .onChange(of: timeline.codexDaemon) { _, codexDaemon in
            codexDaemonReportSeq += 1
            // A fresh daemon report that contradicts the recorded result (the
            // server came back after "off", or was stopped despite "still
            // running") hands the pane back to the live state.
            if Self.codexDaemonResultIsStale(outcome: codexDaemonStopOutcome, codexDaemon: codexDaemon) {
                clearCodexDaemonResult()
            }
            dismissStaleCodexDaemonConfirm()
        }
        .onChange(of: bridgeUpgrade.requested) { _, requested in
            if requested {
                bridgeUpgrade.requested = false
                // The menu item is offered while Timeline is working; dismissing
                // the optional upgrade must not dump a working Timeline.
                beginSetup(reason: .updateRequired, shouldUseTerminalOnDismiss: timeline.phase != .ready)
            }
        }
        .onChange(of: contentScope) { _, _ in
            historyLoader.cancel()
            entryFrames.frames = [:]
            historyScrollAnchor = nil
            piScrollPosition.prependAnchor = nil
            contentFiles.reset()
        }
        .onChange(of: taskKey) { _, _ in historyLoader.cancel(); updateTimelineSheet() }
        .onDisappear {
            if let activeOwner { timeline.retire(owner: activeOwner) }
            approvalViewVisible = false
            approvalResponse.reset()
            questionResponse.reset()
            updateTimelineSheet()
            historyLoader.cancel(); cancelHelperInstallation(); contentFiles.reset()
        }
        .sheet(item: timelineSheetBinding, onDismiss: timelineSheetDismissed) { sheet in timelineSheet(sheet) }
    }
    private func swiftUIMessageList(viewport: GeometryProxy, proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) { messageRows }
                .scrollTargetLayout()
                .padding([.horizontal, .top], DesignSystem.Spacing.base)
                .padding(.top, topOverlayInset)
                .frame(minHeight: max(0, viewport.size.height - bottomScrollMargin + 1), alignment: .top)
                .background {
                    GeometryReader { content in
                        Color.clear.preference(key: TimelineAtBottomPreferenceKey.self,
                            value: content.frame(in: .named("timeline-viewport")).maxY <= viewport.size.height - bottomScrollMargin + 8)
                    }
                }
        }
        // Keep overlay clearance outside the lazy targets: Latest names
        // a message row, rather than an estimated empty spacer below it.
        .contentMargins(.bottom, bottomScrollMargin, for: .scrollContent)
        .timelineInitialScrollAnchor(initialScrollAnchor)
        .task(id: "\(contentScope):\(latestScrollRequest):\(following):\(atBottom):\(tailVisible)") {
            await ensureVisibleTail()
        }
        .coordinateSpace(name: "timeline-viewport")
        .onPreferenceChange(TimelineEntryFramesPreferenceKey.self) { frames in
            entryFrames.frames = frames
            tailVisible = conversationItems.last.flatMap { frames[$0.id] }.map(tailIntersectsViewport) ?? false
        }
        .onPreferenceChange(TimelineAtBottomPreferenceKey.self) { bottom in
            atBottom = bottom
            if bottom { following = true }
            if let scope = tailReplayScope {
                tailReplayScope = nil
                if scope == contentScope, following, recoveredTailRequest == latestScrollRequest,
                   let target = latestTargetID {
                    // Replay the existing request after the rebuilt list lays out.
                    proxy.scrollTo(target, anchor: .bottom)
                }
            }
        }
        .accessibilityIdentifier("agent-timeline-scroll")
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(
            DragGesture()
                .onChanged { value in
                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                    following = false
                    onOutputInteraction()
                }
                .onEnded { value in
                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                    let firstFrame = conversationItems.first.flatMap { entryFrames.frames[$0.id] }
                    let atHistoryTop = conversationItems.isEmpty || (firstFrame.map { $0.minY >= topOverlayInset - 8 } ?? false)
                    let loadHistory = atHistoryTop && value.translation.height > 60
                    if loadHistory && timeline.hasMore {
                        Task { await refreshHistory() }
                    } else if atBottom { following = true }
                }
        )
    }

    private var timelineSheetBinding: Binding<TimelineSheetState.Sheet?> {
        Binding(get: { sheetState.presented }, set: { value in
            guard value == nil else { return }
            switch sheetState.presented {
            case .phoneAnswers: phoneAnswersSelection = nil
            case .helper: showsSetup = false
            case .codexDaemon: showsCodexDaemonConfirm = false
            default: break
            }
            sheetState.close()
        })
    }
    @MainActor private func timelineSheetDismissed() {
        let dismissed = sheetState.dismissing
        sheetState.didDismiss()
        if dismissed == .helper {
            cancelHelperInstallation()
            if setupShouldUseTerminal { onUseTerminal() }
        }
        updateTimelineSheet()
    }
    @ViewBuilder private func timelineSheet(_ sheet: TimelineSheetState.Sheet) -> some View {
        switch sheet {
        case .phoneAnswers:
            if let selection = phoneAnswersSelection {
                PhoneAnswersSheet(selection: selection, connection: connection, store: appModel.phoneAnswers,
                    isCurrent: { hooksContextIsCurrent(selection.key) })
            }
        case .helper:
            AgentBridgeSetupView(
                reason: setupReason, agent: agent, installedVersion: bridgeVersion,
                isChecking: isCheckingSetup, feedback: setupFeedback,
                stage: helperStage, target: setupTarget,
                canInstall: connectionState.isReady && appModel.connectionIdentity == setupTarget && canPinnedInstallerSupportAgent,
                onInstall: startHelperInstallation,
                onCheckAgain: { setupFeedback = nil; isCheckingSetup = true; retry += 1 },
                onUseTerminal: { cancelHelperInstallation(); showsSetup = false }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        case .codexDaemon:
            CodexDaemonConfirmSheet(
                onConfirm: { showsCodexDaemonConfirm = false; disableCodexDaemon() },
                onCancel: { showsCodexDaemonConfirm = false }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
    }
    @MainActor func updateTimelineSheet() {
        sheetState.sync(visible: matchesLiveTimeline && approvalViewVisible && scenePhase == .active,
            phone: phoneAnswersSelection != nil, helper: showsSetup, codex: showsCodexDaemonConfirm)
    }
    var bottomScrollMargin: CGFloat {
        bottomOverlayInset + approvalInset + DesignSystem.Spacing.base
    }
    private var latestTargetID: String? {
        if showsApproval || showsQuestion || timeline.pendingPiDialog != nil || timeline.piActionError != nil || timeline.delayed {
            return "timeline-bottom"
        }
        return conversationItems.last?.id
    }
    private func scrollToLatest(using proxy: ScrollViewProxy) {
        if usesPiMessageList {
            piScrollPosition.revealLatest()
            return
        }
        // A bound scrollPosition can corrupt lazy height estimates when a tall
        // unmeasured row precedes the target. Scroll directly to the actual row.
        if let target = latestTargetID { proxy.scrollTo(target, anchor: .bottom) }
        latestScrollRequest += 1
    }
    private func tailIntersectsViewport(_ frame: CGRect) -> Bool {
        frame.maxY > topOverlayInset && frame.minY < viewportHeight - bottomScrollMargin
    }
    @MainActor private func ensureVisibleTail() async {
        guard following, atBottom, !tailVisible, let target = latestTargetID,
              target == conversationItems.last?.id,
              recoveredTailRequest != latestScrollRequest else { return }
        let request = latestScrollRequest
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        guard !Task.isCancelled, following, atBottom, latestTargetID == target,
              latestScrollRequest == request,
              !entryFrames.frames.values.contains(where: tailIntersectsViewport) else { return }
        // Lazy layout can retain an estimated bottom with no rows
        // mounted after a large insert. Discard that layout cache once per
        // Latest request, without replacing the timeline or its held history.
        recoveredTailRequest = request
        tailReplayScope = contentScope
        entryFrames.frames = [:]
        tailLayoutEpoch += 1
    }
    private var initialScrollAnchor: UnitPoint {
        #if DEBUG && targetEnvironment(simulator)
        if ScreenshotFixtures.enabled && ScreenshotFixtures.screen == "timeline-history-position",
           timeline.generation == 1 { return .top }
        #endif
        return .bottom
    }
    private var contentScope: String {
        "\(activeOwner?.uuidString ?? "none"):\(timeline.generation ?? 0):\(timeline.identity?.nativeSessionId ?? "")"
    }
    @MainActor private func loadContent(_ reference: String, scope: String) async throws -> Data {
        guard matchesLiveTimeline, scope == contentScope, timeline.phase == .ready else { throw AgentBridgeError.closed }
        let result = try await contentFiles.data(key: "\(scope):\(reference)") {
            #if DEBUG && targetEnvironment(simulator)
            if ScreenshotFixtures.enabled { return try AgentTimelineScreenshotFixture.content(reference: reference) }
            #endif
            guard let client = activeClient, let identity = timeline.identity, let generation = timeline.generation else { throw AgentBridgeError.closed }
            return try await client.content(reference: reference, generation: generation, identity: identity)
        }
        try Task.checkCancellation()
        guard matchesLiveTimeline, scope == contentScope, timeline.phase == .ready else { throw AgentBridgeError.closed }
        return result
    }

    @ViewBuilder private var latestIcon: some View {
        let icon = Image(systemName: "arrow.down")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Theme.text)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        if reduceTransparency {
            icon.background(Theme.cardBackground, in: Circle())
        } else if #available(iOS 26.0, *) {
            icon.glassEffect(.regular.interactive(), in: Circle())
        } else {
            icon.background(.ultraThinMaterial, in: Circle())
        }
    }

}

@MainActor private final class PiTimelineScrollPosition {
    var prependAnchor: TimelineHistoryScrollAnchor? {
        didSet { if prependAnchor != nil { scheduleLayout?() } }
    }
    var scheduleLayout: (() -> Void)?

    func revealLatest() {
        prependAnchor = nil
        scheduleLayout?()
    }
}

/// UIKit scrolls the measured Pi message content, including replies taller
/// than the viewport. The surrounding pane and message views are SwiftUI.
private struct PiTimelineMessageList<Rows: View>: UIViewControllerRepresentable {
    let position: PiTimelineScrollPosition
    let following: Bool
    let bottomInset: CGFloat
    let onViewport: ([String: CGRect], Bool) -> Void
    let onDrag: () -> Void
    let onPull: () -> Void
    @ViewBuilder let rows: () -> Rows

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller(position: position)
        controller.loadViewIfNeeded()
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(self)
    }

    @MainActor final class Controller: UIViewController, UIScrollViewDelegate {
        private let position: PiTimelineScrollPosition
        private let scroll = UIScrollView()
        private let host = UIHostingController(rootView: AnyView(EmptyView()))
        private var options: PiTimelineMessageList?
        private var frames: [String: CGRect] = [:]
        private var layoutScheduled = false
        private var dragging = false

        init(position: PiTimelineScrollPosition) {
            self.position = position
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidLoad() {
            super.viewDidLoad()
            scroll.delegate = self
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.keyboardDismissMode = .interactive
            scroll.alwaysBounceVertical = true
            scroll.accessibilityIdentifier = "agent-timeline-scroll"
            scroll.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(scroll)
            addChild(host)
            host.safeAreaRegions = []
            host.sizingOptions = [.intrinsicContentSize]
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(host.view)
            host.didMove(toParent: self)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: view.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                host.view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            ])
            position.scheduleLayout = { [weak self] in self?.scheduleLayout() }
        }

        func update(_ options: PiTimelineMessageList) {
            self.options = options
            if scroll.contentInset.bottom != options.bottomInset {
                scroll.contentInset.bottom = options.bottomInset
                scroll.verticalScrollIndicatorInsets.bottom = options.bottomInset
            }
            host.rootView = AnyView(options.rows()
                .onPreferenceChange(TimelineEntryFramesPreferenceKey.self) { [weak self] frames in
                    self?.frames = frames
                    self?.scheduleLayout()
                })
            scheduleLayout()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            scheduleLayout()
        }

        private var maxOffset: CGFloat {
            max(0, scroll.contentSize.height + scroll.contentInset.bottom - scroll.bounds.height)
        }

        private func scheduleLayout() {
            guard !layoutScheduled else { return }
            layoutScheduled = true
            DispatchQueue.main.async { [weak self] in self?.applyPosition() }
        }

        private func applyPosition() {
            view.layoutIfNeeded()
            layoutScheduled = false
            guard let options, scroll.bounds.height > 0 else { return }
            if !dragging, !scroll.isDecelerating {
                if let anchor = position.prependAnchor, let frame = frames[anchor.id] {
                    let visibleHeight = scroll.bounds.height - scroll.contentInset.bottom
                    let destination = frame.minY - (visibleHeight - frame.height) * anchor.unitY
                    position.prependAnchor = nil
                    scroll.contentOffset.y = min(max(0, destination), maxOffset)
                } else if options.following, abs(scroll.contentOffset.y - maxOffset) > 0.1 {
                    scroll.contentOffset.y = maxOffset
                }
            }
            publishViewport()
        }

        private func publishViewport() {
            guard let options, scroll.bounds.height > 0 else { return }
            let offset = scroll.contentOffset.y
            let viewport = CGRect(x: 0, y: offset, width: scroll.bounds.width, height: scroll.bounds.height)
            let visible = frames.filter { viewport.intersects($0.value) }
                .mapValues { $0.offsetBy(dx: 0, dy: -offset) }
            options.onViewport(visible, !dragging && offset >= maxOffset - 1)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            scheduleLayout()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            dragging = true
            options?.onDrag()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            let translation = scrollView.panGestureRecognizer.translation(in: scrollView)
            dragging = false
            if translation.y > 60, translation.y > abs(translation.x), scrollView.contentOffset.y <= 8 {
                options?.onPull()
            }
            scheduleLayout()
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            scheduleLayout()
        }
    }
}


/// Render only Pi's standard dialog contract. Option strings are sent back
/// verbatim, including permission scopes supplied by the originating extension.
private struct PiDialogCard: View {
    let dialog: AgentPiDialog
    let isSending: Bool
    let onSubmit: (AgentPiDialogValue) -> Void
    let onUseTerminal: () -> Void
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: dialog.title)
                    .font(.jost(.title3, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if isSending { ProgressView().accessibilityLabel("Sending answer") }
            }
            if let message = dialog.message, !message.isEmpty {
                Text(verbatim: message)
                    .font(.jost(.subheadline))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            switch dialog.kind {
            case "confirm":
                VStack(spacing: 10) {
                    option("Yes") { onSubmit(.boolean(true)) }.buttonStyle(.herdrPrimary())
                    option("No") { onSubmit(.boolean(false)) }.buttonStyle(ApprovalOptionButtonStyle())
                }
            case "select":
                VStack(spacing: 10) {
                    ForEach(Array(dialog.options.enumerated()), id: \.element) { index, label in
                        if index == 0 {
                            option(label) { onSubmit(.text(label)) }.buttonStyle(.herdrPrimary())
                        } else {
                            option(label) { onSubmit(.text(label)) }.buttonStyle(ApprovalOptionButtonStyle())
                        }
                    }
                }
            case "input":
                TextField("Answer", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("timeline-pi-dialog-answer")
                Button("Submit") { onSubmit(.text(text)) }.buttonStyle(.herdrPrimary)
            default:
                Text("This custom Pi dialog needs Terminal.").font(.jost(.body))
                Button("Use Terminal", action: onUseTerminal).buttonStyle(.herdrSecondary)
            }
        }
        .padding(16)
        .foregroundStyle(Theme.text)
        .herdrCard()
        .disabled(isSending)
        .onAppear { text = dialog.value ?? "" }
        .accessibilityIdentifier("timeline-pi-dialog")
    }
    private func option(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: label).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension View {
    @ViewBuilder func timelineInitialScrollAnchor(_ anchor: UnitPoint) -> some View {
        if #available(iOS 18, *) {
            defaultScrollAnchor(anchor, for: .initialOffset)
        } else {
            defaultScrollAnchor(anchor)
        }
    }
}
