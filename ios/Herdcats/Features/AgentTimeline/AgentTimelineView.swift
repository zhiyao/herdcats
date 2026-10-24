import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import QuickLook

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
    @Environment(AppModel.self) var appModel
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
    @State var entryFrames: [String: CGRect] = [:]
    @State var viewportHeight: CGFloat = 0
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

    var approvalInset: CGFloat { showsWaitingRow ? waitingRowHeight + 8 : 0 }
    private var hooksKey: PhoneAnswersStore.Key? {
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
                ready: timeline.phase == .ready && connectionState.isReady && appModel.supportsHostServices,
                blocked: timeline.agentStatus == "blocked", pending: timeline.pendingApproval != nil || showsQuestion,
                active: scenePhase == .active && appModel.isSceneActive))
    }
    private var showsWaitingRow: Bool { waitingTaskKey.eligible && waitingKey == waitingTaskKey }
    func hooksContextIsCurrent(_ key: PhoneAnswersStore.Key) -> Bool {
        scenePhase == .active && appModel.isSceneActive && connectionState.isReady && appModel.supportsHostServices
            && setupTarget == key.target && connectionState.generation == key.generation
            && bridgeCapabilities?.approvals == true
    }
    var showsApproval: Bool {
        ApprovalResponseState.isVisible(pending: timeline.pendingApproval, approvals: bridgeCapabilities?.approvals)
    }

    var showsQuestion: Bool {
        QuestionAnswerState.isVisible(pending: timeline.pendingQuestion, questions: bridgeCapabilities?.questions)
    }

    var conversationItems: [TimelineConversationItem] {
        TimelineConversationItem.group(timeline.entries, showsRecords: agent == "codex")
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
    private var taskKey: TaskKey {
        TaskKey(paneId: paneId, agent: agent, connection: connectionState, isActive: scenePhase == .active, retry: retry)
    }
    var canPinnedInstallerSupportAgent: Bool {
        Self.canPinnedInstallerSupport(agent: agent)
    }
    static func canPinnedInstallerSupport(agent: String?, supportedAgents: Set<String> = Set(HostHelperSetupPlan.agents)) -> Bool {
        agent.map { supportedAgents.contains($0) } ?? true
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
    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if timeline.phase == .ready {
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
                                ContentUnavailableView("No messages yet", systemImage: "text.bubble")
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
                                .id("\(scope):\(item.id)")
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
                            if showsApproval, let pending = timeline.pendingApproval {
                                ApprovalCard(pending: pending, response: approvalResponse) { option in
                                    respondToApproval(pending, option: option)
                                }
                                .id("\(contentScope):approval:\(pending.requestId)")
                                .disabled(approvalResponse.isDisabled)
                            }
                            if showsQuestion, let pending = timeline.pendingQuestion {
                                QuestionCard(pending: pending, response: questionResponse,
                                    onSubmit: { respondToQuestion(pending) },
                                    onSkip: { respondToQuestion(pending, skip: true) })
                                    .id("\(contentScope):question:\(pending.requestId)")
                            }
                        } else {
                            availability
                        }
                        // Clear scroll space lets the final entry sit above the
                        // floating Compose bubble without an opaque dock panel.
                        Color.clear
                            .frame(height: bottomOverlayInset + approvalInset)
                            .padding(.bottom, DesignSystem.Spacing.base)
                            .id("timeline-bottom")
                    }
                    .scrollTargetLayout()
                    .padding([.horizontal, .top], DesignSystem.Spacing.base)
                    .padding(.top, topOverlayInset)
                    .frame(minHeight: viewport.size.height + 1, alignment: .top)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(key: TimelineAtBottomPreferenceKey.self,
                                value: content.frame(in: .named("timeline-viewport")).maxY <= viewport.size.height + 8)
                        }
                    }
                }
                .coordinateSpace(name: "timeline-viewport")
                .onChange(of: viewport.size.height, initial: true) { _, height in
                    viewportHeight = height
                    if following && showsApproval { proxy.scrollTo("timeline-bottom", anchor: .bottom) }
                }
                .onChange(of: timeline.pendingApproval?.requestId, initial: true) { _, requestId in
                    guard requestId != nil, showsApproval else { return }
                    following = true
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) {
                        proxy.scrollTo("timeline-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: showsQuestion ? timeline.pendingQuestion?.requestId : nil, initial: true) { _, requestId in
                    guard requestId != nil, showsQuestion else { return }
                    following = true
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) {
                        proxy.scrollTo("timeline-bottom", anchor: .bottom)
                    }
                }
                .onPreferenceChange(TimelineEntryFramesPreferenceKey.self) { entryFrames = $0 }
                .onChange(of: historyScrollAnchor) { _, anchor in
                    guard let anchor else { return }
                    following = false
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo("\(contentScope):\(anchor.id)", anchor: UnitPoint(x: 0, y: anchor.unitY))
                    }
                }
                .onPreferenceChange(TimelineAtBottomPreferenceKey.self) { bottom in
                    atBottom = bottom
                    if bottom { following = true }
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
                            let firstFrame = conversationItems.first.flatMap { entryFrames[$0.id] }
                            let atHistoryTop = conversationItems.isEmpty || (firstFrame.map { $0.minY >= topOverlayInset - 8 } ?? false)
                            let loadHistory = atHistoryTop && value.translation.height > 60
                            if loadHistory && timeline.hasMore {
                                Task { await refreshHistory() }
                            } else if atBottom { following = true }
                        }
                )
                .onChange(of: timeline.revision) { _, _ in
                    guard following, timeline.pendingQuestion == nil, (!conversationItems.isEmpty || showsApproval) else { return }
                    proxy.scrollTo("timeline-bottom", anchor: .bottom)
                }
                .onChange(of: timeline.identity) { _, _ in
                    following = true
                    #if DEBUG && targetEnvironment(simulator)
                        if ScreenshotFixtures.enabled && ScreenshotFixtures.screen == "timeline-history-position" {
                            following = false
                        }
                    #endif
                }
                .onChange(of: bottomOverlayInset) { _, _ in
                    if following && (!conversationItems.isEmpty || showsApproval) {
                        proxy.scrollTo("timeline-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: approvalInset) { _, _ in
                    if following && (!conversationItems.isEmpty || showsApproval) {
                        proxy.scrollTo("timeline-bottom", anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Group {
                    if !atBottom && timeline.phase == .ready {
                        Button {
                            following = true
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) {
                                proxy.scrollTo("timeline-bottom", anchor: .bottom)
                            }
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
        // Let messages scroll behind the pane cards, but keep them below
        // the navigation bar and status area.
        .overlay(alignment: .bottom) {
            Group {
                if showsWaitingRow, let key = hooksKey, let agent = ApprovalAgent(rawValue: key.agent) {
                    PhoneAnswersWaitingRow(agent: agent, result: appModel.phoneAnswers.result(for: key)) { mode in
                        phoneAnswersSelection = PhoneAnswersSelection(key: key, mode: mode)
                    }
                }
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in waitingRowHeight = height }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, bottomOverlayInset + 8)
        }
        .clipped()
        .background(Theme.background)
        .onChange(of: timeline.pendingApproval, initial: true) { _, pending in approvalResponse.sync(pending) }
        .onChange(of: timeline.pendingQuestion, initial: true) { _, pending in questionResponse.sync(pending) }
        .task(id: taskKey) { await run() }
        .task(id: "\(activeClient?.id.uuidString ?? "none"):\(contentScope)") {
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
            case .loading: break
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
            entryFrames = [:]
            historyScrollAnchor = nil
            contentFiles.reset()
        }
        .onChange(of: taskKey) { _, _ in historyLoader.cancel(); updateTimelineSheet() }
        .onDisappear {
            approvalViewVisible = false
            approvalResponse.reset()
            questionResponse.reset()
            updateTimelineSheet()
            historyLoader.cancel(); cancelHelperInstallation(); contentFiles.reset()
        }
        .sheet(item: timelineSheetBinding, onDismiss: timelineSheetDismissed) { sheet in timelineSheet(sheet) }
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
                canInstall: connectionState.isReady && appModel.supportsHostServices && appModel.connectionIdentity == setupTarget && canPinnedInstallerSupportAgent,
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
        sheetState.sync(visible: approvalViewVisible && scenePhase == .active,
            phone: phoneAnswersSelection != nil, helper: showsSetup, codex: showsCodexDaemonConfirm)
    }
    private var contentScope: String {
        "\(activeOwner?.uuidString ?? "none"):\(timeline.generation ?? 0):\(timeline.identity?.nativeSessionId ?? "")"
    }
    @MainActor private func loadContent(_ reference: String, scope: String) async throws -> Data {
        guard scope == contentScope, timeline.phase == .ready else { throw AgentBridgeError.closed }
        let result = try await contentFiles.data(key: "\(scope):\(reference)") {
            #if DEBUG && targetEnvironment(simulator)
            if ScreenshotFixtures.enabled { return try AgentTimelineScreenshotFixture.content(reference: reference) }
            #endif
            guard let client = activeClient, let identity = timeline.identity, let generation = timeline.generation else { throw AgentBridgeError.closed }
            return try await client.content(reference: reference, generation: generation, identity: identity)
        }
        try Task.checkCancellation()
        guard scope == contentScope, timeline.phase == .ready else { throw AgentBridgeError.closed }
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
