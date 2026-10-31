import SwiftUI
import UIKit

// MARK: - Agent timeline view availability & Codex daemon helpers

extension AgentTimelineView {
    @ViewBuilder var availability: some View {
        switch timeline.presentationPhase(connection: connectionState, isActive: scenePhase == .active, paneId: paneId, agent: agent) {
        case .loading:
            timelineContentLoading
        case .suspended:
            if appModel.isOffline {
                timelineOfflineState
            } else if scenePhase == .active {
                timelineContentLoading
            }
        case .disconnected:
            ContentUnavailableView {
                Label("Timeline disconnected", systemImage: "wifi.slash")
            } description: {
                if !connectionState.isReady { Text("Reconnect to load current session messages.") }
            } actions: {
                Button("Check again") { retry += 1 }
                    .buttonStyle(.herdrSecondary)
                    .disabled(!connectionState.isReady)
                    .accessibilityIdentifier("timeline-helper-retry")
            }
        case .unavailable("transcript_unavailable"):
            // Claude writes its transcript only after the first prompt; the
            // helper keeps polling and swaps in the timeline once it exists.
            ContentUnavailableView("Send a message to start", systemImage: "bubble.left")
        case .unavailable(let code):
            let isCodex = agent == "codex"
            let isSupportedAgent = canPinnedInstallerSupportAgent
            let isNeedsUpgrade = Self.isNeedsUpgrade(code: code, agent: agent, bridgeVersion: bridgeVersion)
            let isMissing = code == "helper_missing"
            let showsInstallOrUpgrade = Self.showsInstallOrUpgrade(code: code, agent: agent, bridgeVersion: bridgeVersion)
            let showsProtocolMismatch = code == "protocol_mismatch" && isSupportedAgent
            let isNoSession = ["session_reference_unavailable", "ambiguous_session", "invalid_session_reference"].contains(code)
            let codexNoSession: CodexNoSessionAction? = isCodex && isNoSession
                ? Self.codexNoSessionAction(
                    agent: agent,
                    code: code,
                    capabilities: bridgeCapabilities,
                    codexDaemon: timeline.codexDaemon)
                : nil

            ContentUnavailableView {
                Label(codexNoSession.map(Self.codexNoSessionTitle) ?? title(code), systemImage: Self.availabilitySymbol(code: code, agent: agent,
                    capabilities: bridgeCapabilities, codexDaemon: timeline.codexDaemon, bridgeVersion: bridgeVersion))
            } description: {
                if codexNoSession != nil, let outcome = codexDaemonStopOutcome {
                    Text(outcome.message)
                } else if let codexNoSession {
                    if let explanation = Self.codexNoSessionExplanation(codexNoSession, code: code, agent: agent) {
                        Text(explanation)
                    }
                } else {
                    Text(explanation(code))
                }
            } actions: {
                if showsInstallOrUpgrade || showsProtocolMismatch {
                    Button(isNeedsUpgrade ? "Upgrade Herdcats Bridge" : (isMissing ? "Install Herdcats Bridge" : "Set up Timeline")) {
                        beginSetup(reason: isNeedsUpgrade ? .updateRequired : .missing)
                    }
                    .buttonStyle(.herdrPrimary)
                    .accessibilityIdentifier("timeline-helper-setup")
                }
                if let codexNoSession {
                    ForEach(
                        Self.codexNoSessionRecovery(outcome: codexDaemonStopOutcome, action: codexNoSession),
                        id: \.self
                    ) { recovery in
                        switch recovery {
                        case .turnOffServer:
                            Button {
                                showsCodexDaemonConfirm = true
                            } label: {
                                HStack {
                                    if isDisablingCodexDaemon { ProgressView() }
                                    Text(isDisablingCodexDaemon ? "Turning off…" : "Turn off Codex's shared background server")
                                }.frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.herdrPrimary)
                            .accessibilityIdentifier("timeline-codex-disable-daemon")
                            .disabled(isDisablingCodexDaemon)
                        case .upgradeBridge:
                            Button("Upgrade Herdcats Bridge") {
                                beginSetup(reason: .updateRequired)
                            }
                            .buttonStyle(.herdrPrimary)
                            .accessibilityIdentifier("timeline-codex-upgrade-bridge")
                        case .manualFallback:
                            codexManualFallback
                        case .stopCommand:
                            codexStopCommandFallback
                        case .updaterStopCommand:
                            codexUpdaterStopFallback
                        }
                    }
                }
                // The bridge re-resolves every poll, so a session that starts
                // replaces this state on its own; retrying adds nothing.
                if codexNoSession != .waitForSession,
                   Self.showsPaneCheckAgain(code: code, agent: agent, bridgeVersion: bridgeVersion) {
                    Button("Check again") { retry += 1 }.buttonStyle(.herdrSecondary)
                        .accessibilityIdentifier("timeline-helper-retry")
                }
            }
        case .ready: EmptyView()
        }
    }

    /// Intrinsic, finite content fits above the floating composer even with the keyboard open.
    private var timelineOfflineState: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.jost(.title2))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("The herd got loose")
                .font(.jost(.headline))
            Text("You're offline. Reconnect to bring the cats back.")
                .font(.jost(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-offline-state")
    }

    private var timelineContentLoading: some View {
        LazyCatLoadingView(message: "Connecting to timeline…")
            .frame(height: max(200, viewportHeight - topOverlayInset - bottomOverlayInset - 48))
            .accessibilityIdentifier("timeline-content-loading")
    }

    static func availabilitySymbol(code: String, agent: String?, capabilities: AgentBridgeCapabilities?,
                                   codexDaemon: String?, bridgeVersion: String? = nil) -> String {
        if isNeedsUpgrade(code: code, agent: agent, bridgeVersion: bridgeVersion) { return "bubble.left" }
        let noSession = ["session_reference_unavailable", "ambiguous_session", "invalid_session_reference"].contains(code)
        if agent == "codex", noSession {
            return codexNoSessionAction(agent: agent, code: code, capabilities: capabilities, codexDaemon: codexDaemon) == .waitForSession
                ? "bubble.left" : "questionmark.bubble"
        }
        if (agent == "cursor" && noSession) || (agent == "codex" && code == "session_cwd_mismatch") {
            return "questionmark.bubble"
        }
        return "bubble.left"
    }

    func explanation(_ code: String) -> String {
        Self.explanation(
            code,
            agent: agent,
            installedVersion: bridgeVersion,
            pinnedVersion: HostHelperSetupPlan.version,
            supportedAgents: Set(HostHelperSetupPlan.agents)
        )
    }

    func title(_ code: String) -> String {
        Self.unavailableTitle(
            code: code,
            agent: agent,
            bridgeVersion: bridgeVersion,
            supportedAgents: Set(HostHelperSetupPlan.agents)
        )
    }

    /// The pane options menu's optional upgrade item reads `bridgeUpgrade`,
    /// which outlives this view's runs. Every refresh of the handshake-derived
    /// Bridge version must reach it, but only while `owner` still owns the run
    /// — a superseded run must not clobber a newer handshake's version.
    @MainActor
    static func publishBridgeVersion(
        _ version: String?, to upgrade: TimelineBridgeUpgrade, owner: UUID, activeOwner: UUID?
    ) {
        guard activeOwner == owner else { return }
        upgrade.bridgeVersion = version
    }

    static func isNeedsUpgrade(
        code: String,
        agent: String?,
        bridgeVersion: String? = nil,
        supportedAgents: Set<String> = Set(HostHelperSetupPlan.agents)
    ) -> Bool {
        let isSupported = canPinnedInstallerSupport(agent: agent, supportedAgents: supportedAgents)
        guard isSupported else { return false }
        return code == "helper_update_required"
            || (HostHelperProbe.isOlderThanMinimum(bridgeVersion)
                && ["record_too_large", "unsupported_agent", "pi_bridge_required", "agy_bridge_required", "cursor_bridge_required"].contains(code))
    }

    static func upgradePitch(
        agent: String?,
        installedVersion: String?,
        pinnedVersion: String = HostHelperSetupPlan.version
    ) -> String {
        let isCodex = agent == "codex"
        let installedBelowMinimum = !HostHelperProbe.isAtLeastMinimum(installedVersion)
        if installedBelowMinimum {
            return "This app requires Herdcats Bridge \(HostHelperSetupPlan.minimumVersion) or later. Your agent keeps running while you upgrade."
        } else {
            let feature = isCodex ? "fixes for Codex conversations" : "fixes for session history"
            return "Version \(pinnedVersion) includes \(feature). Your agent keeps running while you upgrade."
        }
    }

    static func showsInstallOrUpgrade(
        code: String,
        agent: String?,
        bridgeVersion: String? = nil,
        supportedAgents: Set<String> = Set(HostHelperSetupPlan.agents)
    ) -> Bool {
        let isSupported = canPinnedInstallerSupport(agent: agent, supportedAgents: supportedAgents)
        guard isSupported else { return false }
        return code == "helper_missing" || isNeedsUpgrade(code: code, agent: agent, bridgeVersion: bridgeVersion, supportedAgents: supportedAgents)
    }

    static func showsPaneCheckAgain(
        code: String,
        agent: String?,
        bridgeVersion: String? = nil,
        supportedAgents: Set<String> = Set(HostHelperSetupPlan.agents)
    ) -> Bool {
        return !showsInstallOrUpgrade(code: code, agent: agent, bridgeVersion: bridgeVersion, supportedAgents: supportedAgents)
    }

    /// What the pane can do about a Codex pane with no identified session,
    /// decided from what the installed bridge can actually do.
    enum CodexNoSessionAction: Equatable, CaseIterable {
        /// The bridge (0.2.2+) can stop the server and it is running or unverifiable.
        case turnOffServer
        /// The server is off and there is no session reference yet.
        case waitForSession
        /// The server is off but the existing reference cannot identify a session.
        case identifySession
        /// The bridge (0.2.0/0.2.1) can only change the config; upgrading adds
        /// the in-app stop.
        case upgradeBridge
        /// Older bridge or nothing to do: keep the manual fallback.
        case manualFallback
    }

    static func codexNoSessionAction(
        agent: String?,
        code: String,
        capabilities: AgentBridgeCapabilities?,
        codexDaemon: String?
    ) -> CodexNoSessionAction {
        guard agent == "codex",
            ["session_reference_unavailable", "ambiguous_session", "invalid_session_reference"].contains(code)
        else { return .manualFallback }
        if capabilities?.codexDaemonStop == true {
            if codexDaemon == "running" || codexDaemon == "unknown" { return .turnOffServer }
            return code == "session_reference_unavailable" ? .waitForSession : .identifySession
        }
        if capabilities?.codexDaemonConfig == true {
            return .upgradeBridge
        }
        return .manualFallback
    }

    static let codexDaemonRunningExplanation =
        "Codex's shared background server is running, so Herdcats can't tell which session belongs to this pane."

    /// The title says what the user has to do: "Waiting" only fits when the
    /// session will arrive on its own, which it never does while the shared
    /// server is running.
    static func codexNoSessionTitle(_ action: CodexNoSessionAction) -> String {
        switch action {
        case .turnOffServer, .upgradeBridge, .identifySession: return "Codex session not identified"
        case .waitForSession: return "Send a message to start"
        case .manualFallback: return "Waiting for Codex session"
        }
    }
    static let codexDaemonUpgradeExplanation =
        "Upgrade Herdcats Bridge to turn off Codex's shared background server from here."

    /// Only a missing session reference needs no explanation beyond the title.
    static func codexNoSessionExplanation(_ action: CodexNoSessionAction, code: String, agent: String?) -> String? {
        switch action {
        case .turnOffServer: return codexDaemonRunningExplanation
        case .waitForSession: return nil
        case .identifySession: return "Restart Codex in this pane, then check again."
        case .upgradeBridge: return codexDaemonUpgradeExplanation
        case .manualFallback: return explanation(code, agent: agent)
        }
    }

    /// One recovery control offered under a no-session Codex state.
    enum CodexRecoveryAction: Hashable {
        case turnOffServer, upgradeBridge, manualFallback, stopCommand, updaterStopCommand
    }

    /// Which recovery actions the pane offers. A recorded stop outcome drives
    /// its own recovery regardless of the live daemon action — after an
    /// updater-only failure the not_running re-emit moves the pane to waiting
    /// while the updater may still restart the server, so the command the
    /// message points at must stay reachable — and an outcome error replaces,
    /// never duplicates, the action's own fallbacks. Without an outcome the
    /// live action decides.
    static func codexNoSessionRecovery(
        outcome: CodexDaemonStopOutcome?, action: CodexNoSessionAction
    ) -> [CodexRecoveryAction] {
        if let outcome {
            if outcome.errorOccurred { return [.manualFallback] }
            if outcome.showsStopCommand { return [.stopCommand] }
            if outcome.showsUpdaterStopCommand { return [.updaterStopCommand] }
            return []
        }
        switch action {
        case .turnOffServer: return [.turnOffServer]
        case .upgradeBridge: return [.upgradeBridge, .manualFallback]
        case .manualFallback: return [.manualFallback]
        case .waitForSession, .identifySession: return []
        }
    }

    /// The stop is destructive, so it may run only while the live pane still
    /// asks for it: a no-session Codex pane whose bridge can stop the server
    /// and currently reports it as running or unverifiable. Anything else —
    /// the session was identified, the pane reconnected, the server is
    /// already off, or an older bridge — must not stop anything.
    static func canRunCodexDaemonStop(
        phase: AgentTimelineState.Phase,
        agent: String?,
        capabilities: AgentBridgeCapabilities?,
        codexDaemon: String?
    ) -> Bool {
        guard case .unavailable(let code) = phase else { return false }
        return codexNoSessionAction(
            agent: agent, code: code, capabilities: capabilities, codexDaemon: codexDaemon
        ) == .turnOffServer
    }

    /// The recorded stop result for the current no-session episode. Keeps the
    /// per-process outcome: `codex_daemon` events report only the daemon
    /// process, so an updater-only failure is not contradicted by them.
    struct CodexDaemonStopOutcome: Equatable {
        let message: String
        let errorOccurred: Bool
        let showsStopCommand: Bool
        /// The daemon stopped but its updater survived or is unverified;
        /// recovery needs the updater-aware bridge command, not Codex's own
        /// `daemon stop`.
        let showsUpdaterStopCommand: Bool
        /// The result reported the daemon process itself as still running
        /// (stop_failed) or alive-but-unverifiable (unknown).
        let daemonStillRunning: Bool

        init(result: CodexDaemonConfigResult) {
            self.message = CodexDaemonConfigResult.message(for: result)
            self.errorOccurred = result.error != nil
            self.showsStopCommand = CodexDaemonConfigResult.showsStopCommand(for: result)
            self.showsUpdaterStopCommand = CodexDaemonConfigResult.showsUpdaterStopCommand(for: result)
            self.daemonStillRunning = result.daemon == "stop_failed" || result.daemon == "unknown"
        }

        /// The stop command failed before any result came back.
        init(errorDescription: String) {
            self.message = errorDescription
            self.errorOccurred = true
            self.showsStopCommand = false
            self.showsUpdaterStopCommand = false
            self.daemonStillRunning = false
        }
    }

    /// A stop result survives only within the unavailable episode it answered;
    /// once the pane is ready (or reconnecting) again, a later no-session
    /// episode must not inherit its feedback.
    static func codexDaemonResultIsCurrent(phase: AgentTimelineState.Phase) -> Bool {
        if case .unavailable = phase { return true }
        return false
    }

    /// Whether a fresh `codex_daemon` report retires a recorded stop result.
    /// The event reports only the daemon process:
    /// - Both processes failed: no daemon-only report can contradict the
    ///   recorded updater failure, so only the episode end retires it.
    /// - Only the updater failed (the daemon was stopped): the daemon being
    ///   alive again (running or unverifiable) contradicts it.
    /// - Only the daemon failed, or nothing was stopped (an error): a
    ///   not_running report resolves it.
    /// - A successful stop: the daemon being alive again retires it.
    static func codexDaemonResultIsStale(outcome: CodexDaemonStopOutcome?, codexDaemon: String?) -> Bool {
        guard let outcome, let codexDaemon else { return false }
        if outcome.showsUpdaterStopCommand {
            if outcome.daemonStillRunning { return false }
            return codexDaemon == "running" || codexDaemon == "unknown"
        }
        if outcome.errorOccurred || outcome.daemonStillRunning {
            return codexDaemon == "not_running"
        }
        return codexDaemon == "running" || codexDaemon == "unknown"
    }

    /// A stop command can run for up to 90 s, and its result belongs to the
    /// no-session episode that initiated it. The episode token is captured
    /// before awaiting and bumped by every clear, so a completion that lands
    /// after the pane moved on (ready, a re-run, a later episode) is
    /// discarded instead of replacing the live guidance. A daemon report
    /// that never changed during the flight carries no new information —
    /// the completion's own result is the freshest evidence — so the
    /// staleness comparison applies only to a report that changed after the
    /// stop started; an updater failure recorded then is not retired by a
    /// daemon-only value the bridge never re-emitted.
    static func shouldRecordStopOutcome(
        initiatedEpisode: Int,
        currentEpisode: Int,
        initiatedReportSeq: Int,
        currentReportSeq: Int,
        outcome: CodexDaemonStopOutcome,
        latestCodexDaemon: String?
    ) -> Bool {
        guard initiatedEpisode == currentEpisode else { return false }
        guard initiatedReportSeq != currentReportSeq else { return true }
        return !codexDaemonResultIsStale(outcome: outcome, codexDaemon: latestCodexDaemon)
    }

    static let codexManualConfigLine = "daemon_auto_start = false"
    static let codexDaemonStopCommand = "codex app-server daemon stop"
    /// Recovery for a surviving or unverified updater: Codex's own
    /// `daemon stop` cannot address it, and only the bridge stops the
    /// updater before the daemon. The lookup mirrors the app's helper
    /// discovery exactly — the managed ~/.local/bin path first, then PATH,
    /// then the remaining known locations — so it runs the same bridge
    /// binary that advertised codex_daemon_stop instead of an older copy
    /// left on PATH.
    static let codexUpdaterStopCommand = "B=\"$HOME/.local/bin/herdcats-bridge\"; [ -x \"$B\" ] || B=$(command -v herdcats-bridge 2>/dev/null); [ -n \"$B\" ] || for P in \"$HOME/.cargo/bin/herdcats-bridge\" /opt/homebrew/bin/herdcats-bridge /usr/local/bin/herdcats-bridge; do [ -x \"$P\" ] && { B=\"$P\"; break; }; done; \"$B\" codex-config disable-daemon --stop-running"

    static func codexManualFallbackText() -> String {
        "Add `daemon_auto_start = false` under `[features]` in `~/.codex/config.toml`, or start Codex with `codex --no-daemon`."
    }

    static func unavailableTitle(
        code: String,
        agent: String?,
        bridgeVersion: String? = nil,
        supportedAgents: Set<String> = Set(HostHelperSetupPlan.agents)
    ) -> String {
        let isNeedsUpgrade = isNeedsUpgrade(code: code, agent: agent, bridgeVersion: bridgeVersion, supportedAgents: supportedAgents)
        let isCodex = agent == "codex"
        let isNoSession = ["session_reference_unavailable", "ambiguous_session", "invalid_session_reference"].contains(code)
        let isCwdMismatch = code == "session_cwd_mismatch"
        let isMissing = code == "helper_missing"
        if isNeedsUpgrade { return "Upgrade Herdcats Bridge" }
        if agent == "pi" && code == "pi_extension_unavailable" { return "Load Herdcats Pi extension" }
        if agent == "pi" && code == "unsafe_transcript_path" { return "Session history could not be read safely" }
        if isCodex && isNoSession { return "Waiting for Codex session" }
        if agent == "cursor" && isNoSession { return "Cursor chat not identified" }
        if isCodex && isCwdMismatch { return "This pane’s Codex session could not be confirmed" }
        if isMissing { return "Set up Timeline" }
        return "Timeline unavailable"
    }

    static func explanation(
        _ code: String,
        agent: String?,
        installedVersion: String? = nil,
        pinnedVersion: String = HostHelperSetupPlan.version,
        supportedAgents: Set<String> = Set(HostHelperSetupPlan.agents)
    ) -> String {
        let capabilityErrors = ["pi": "pi_bridge_required", "antigravity_cli": "agy_bridge_required", "cursor": "cursor_bridge_required"]
        if let canonical = TimelineAgentAvailability.canonical(agent), capabilityErrors[canonical] == code,
           HostHelperProbe.isAtLeastMinimum(installedVersion) {
            if canonical == "pi" {
                return "Herdcats Bridge could not open this host’s Pi session directory. Check its permissions, start Pi 1.4.0 and load the Herdcats Pi extension in this pane, then check again. You can continue in Terminal."
            }
            let name = TimelineAgentAvailability.displayName(for: canonical)
            return "Herdcats Bridge could not open this host’s \(name) session directory. Start \(name) on this SSH computer and check the directory permissions, then check again. You can continue in Terminal."
        }
        if agent == "pi" {
            if ["helper_missing", "helper_update_required", "unsupported_agent", "pi_bridge_required"].contains(code) {
                if canPinnedInstallerSupport(agent: agent, supportedAgents: supportedAgents) {
                    return "Install or upgrade Herdcats Bridge to \(pinnedVersion), then load the Herdcats Pi extension in this pane’s Pi 1.4.0 TUI and check again. The bridge installer does not install the Pi extension. You can continue in Terminal."
                }
                return "Pi conversations require a source build of Herdcats Bridge and the Herdcats Pi extension. The published \(pinnedVersion) installer supports Claude and Codex. Set up Pi on this SSH computer, then check again. You can continue in Terminal."
            }
            if code == "session_reference_unavailable" || code == "unsupported_session_source" {
                return "Herdr did not provide an exact Pi session reference for this pane. Keep using Terminal; Herdcats will not guess which Pi session to open."
            }
            if code == "transcript_unavailable" || code == "invalid_transcript" || code == "session_mismatch" {
                return "Herdcats could not verify this pane's Pi session file. Check the Pi session and bridge agent directory, then check again."
            }
            if code == "pi_extension_unavailable" {
                return "Install the Herdcats extension on this SSH host, then load it in the Pi 1.4.0 TUI for this pane. Copy `bridge/pi-extension/index.ts` and `runtime.mjs` to `~/.pi/agent/extensions/herdcats/` (or `$PI_CODING_AGENT_DIR/extensions/herdcats/`), then run `/reload` in this same TUI and tap Check again."
            }
            if code == "invalid_pi_response" {
                return "The Herdcats extension returned an unrecognized response. Check that this Pi TUI has the extension version from the same source checkout, then run `/reload` and check again."
            }
            if code.hasPrefix("pi_") {
                return "Load the Herdcats extension in the existing Pi TUI, using Pi 1.4.0, then check again. No second Pi process is started. Use Terminal to continue."
            }
        }
        if TimelineAgentAvailability.canonical(agent) == "antigravity_cli",
           ["helper_missing", "helper_update_required", "unsupported_agent", "agy_bridge_required"].contains(code) {
            if canPinnedInstallerSupport(agent: agent, supportedAgents: supportedAgents) {
                return "Install or upgrade Herdcats Bridge to \(pinnedVersion) on this SSH computer, then check again. You can continue in Terminal."
            }
            return "Agy conversations require a source build of Herdcats Bridge with Agy support. The published \(pinnedVersion) installer supports Claude and Codex. Install the source bridge manually on this SSH computer, then check again. You can continue in Terminal."
        }
        if agent == "cursor",
           ["helper_missing", "helper_update_required", "unsupported_agent", "cursor_bridge_required"].contains(code) {
            if canPinnedInstallerSupport(agent: agent, supportedAgents: supportedAgents) {
                return "Install or upgrade Herdcats Bridge to \(pinnedVersion) on this SSH computer, then check again. You can continue in Terminal."
            }
            return "Cursor conversations require a source build of Herdcats Bridge with Cursor support. The published \(pinnedVersion) installer supports Claude and Codex. Install the source bridge manually on this SSH computer, then check again. You can continue in Terminal."
        }
        if agent == "cursor", ["session_reference_unavailable", "ambiguous_session", "invalid_session_reference"].contains(code) {
            return "Herdr hasn't reported which Cursor chat this pane is showing. This happens after resuming a chat with --resume. Start a new Cursor session in this pane to see its messages here, or continue in Terminal."
        }
        let isCodex = agent == "codex"
        let canSupportCodex = supportedAgents.contains("codex")
        switch code {
        case "helper_missing":
            if isCodex {
                return canSupportCodex
                    ? "Install Herdcats Bridge to see this session as native messages."
                    : "This version of Herdcats can't install a version of Herdcats Bridge that supports Codex yet."
            }
            return "Install Herdcats Bridge to see this session as native messages."
        case "helper_update_required":
            if let agent, !canPinnedInstallerSupport(agent: agent, supportedAgents: supportedAgents) {
                return "This version of Herdcats can't install a version of Herdcats Bridge that supports \(agent.capitalized) yet."
            }
            if let installed = installedVersion, !installed.isEmpty {
                return "Herdcats Bridge \(installed) on this computer needs an upgrade. This app requires version \(HostHelperSetupPlan.minimumVersion) or later. Upgrade to \(pinnedVersion)."
            } else {
                return "The Herdcats Bridge on this computer needs an upgrade. This app requires version \(HostHelperSetupPlan.minimumVersion) or later. Upgrade to \(pinnedVersion)."
            }
        case "unsupported_agent":
            if isCodex {
                if isNeedsUpgrade(code: code, agent: agent, bridgeVersion: installedVersion, supportedAgents: supportedAgents),
                   let installedVersion {
                    return "Herdcats Bridge \(installedVersion) on this computer can't show Codex conversations. Upgrade to \(pinnedVersion)."
                }
                if !canSupportCodex {
                    return "This version of Herdcats can't install a version of Herdcats Bridge that supports Codex yet."
                }
            }
            return "Timeline isn't available for this agent yet."
        case "session_reference_unavailable", "ambiguous_session", "invalid_session_reference":
            if isCodex {
                return "If this stays after Codex replies, restart Codex with `codex --no-daemon`."
            }
            return "This pane has no verified session history."
        case "session_cwd_mismatch":
            if isCodex {
                return "The session folder does not match the pane’s folder, so Herdcats will not guess."
            }
            return "This pane's session folder does not match the verified session."
        case "transcript_root_unavailable":
            return "Session history is unavailable on this host."
        case "source_changing": return "Session history is being updated. Try again in a moment."
        case "record_too_large":
            if isNeedsUpgrade(code: code, agent: agent, bridgeVersion: installedVersion, supportedAgents: supportedAgents) {
                return "Herdcats Bridge cannot read an oversized session record. Upgrade Herdcats Bridge to reload history."
            }
            return "Herdcats Bridge cannot read an oversized session record."
        case "source_too_large": return "This session exceeds the current history size limit."
        case "unsafe_transcript_path", "invalid_transcript", "session_mismatch":
            return "Session history could not be read safely."
        case "herdr_unavailable": return "Herdcats Bridge cannot reach Herdr on this host. Check the host session, then try again."
        case "unsupported_herdr_protocol", "protocol_mismatch":
            return "Herdcats Bridge and the Herdr version are not compatible."
        default:
            return "Check that the optional Herdcats Bridge is available on your host, then try again."
        }
    }

    @ViewBuilder var codexManualFallback: some View {
        VStack(spacing: 8) {
            Text(Self.codexManualFallbackText())
                .font(.jost(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
            Button {
                UIPasteboard.general.string = Self.codexManualConfigLine
                copiedCodexConfig = true
            } label: {
                Label(copiedCodexConfig ? "Setting copied" : "Copy setting", systemImage: copiedCodexConfig ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.herdrSecondary)
            .accessibilityIdentifier("timeline-codex-copy-setting")
        }
    }

    @ViewBuilder var codexStopCommandFallback: some View {
        Button {
            UIPasteboard.general.string = Self.codexDaemonStopCommand
            copiedCodexStop = true
        } label: {
            Label(copiedCodexStop ? "Command copied" : "Copy stop command", systemImage: copiedCodexStop ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.herdrPrimary)
        .accessibilityIdentifier("timeline-codex-copy-stop")
    }

    @ViewBuilder var codexUpdaterStopFallback: some View {
        Button {
            UIPasteboard.general.string = Self.codexUpdaterStopCommand
            copiedCodexUpdaterStop = true
        } label: {
            Label(copiedCodexUpdaterStop ? "Command copied" : "Copy turn-off command", systemImage: copiedCodexUpdaterStop ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.herdrPrimary)
        .accessibilityIdentifier("timeline-codex-copy-updater-stop")
    }

    func clearCodexDaemonResult() {
        codexDaemonStopOutcome = nil
        codexDaemonEpisode += 1
    }

    /// The confirmation sheet can outlive the state that offered it; if the
    /// pane no longer asks for the stop (session identified, server already
    /// off, stream re-ran), close it instead of stopping a working server.
    func dismissStaleCodexDaemonConfirm() {
        guard showsCodexDaemonConfirm else { return }
        guard matchesLiveTimeline else { showsCodexDaemonConfirm = false; return }
        if !Self.canRunCodexDaemonStop(
            phase: timeline.phase,
            agent: agent,
            capabilities: bridgeCapabilities,
            codexDaemon: timeline.codexDaemon
        ) {
            showsCodexDaemonConfirm = false
        }
    }

    func disableCodexDaemon() {
        guard matchesLiveTimeline, scenePhase == .active, connectionState.isReady,
              !isDisablingCodexDaemon else { return }
        // The sheet may have stayed open after the pane moved on; revalidate
        // the live state so confirming a stale sheet never stops a server the
        // pane no longer reports as running.
        guard Self.canRunCodexDaemonStop(
            phase: timeline.phase,
            agent: agent,
            capabilities: bridgeCapabilities,
            codexDaemon: timeline.codexDaemon
        ) else { return }
        guard let generation = connectionState.generation else { return }
        // Bind the up-to-90 s stop to the episode that started it. Any clear
        // while it runs — the pane left the unavailable state, the stream
        // re-ran, or a fresh daemon report retired the previous result — ends
        // that episode, and the late answer must not replace newer guidance.
        let initiatedEpisode = codexDaemonEpisode
        let initiatedReportSeq = codexDaemonReportSeq
        isDisablingCodexDaemon = true
        Task {
            let outcome: CodexDaemonStopOutcome
            do {
                let result = try await connection.disableCodexDaemon(
                    target: setupTarget,
                    owned: generation,
                    stopRunning: true
                )
                // No retry: the bridge re-emits timeline.unavailable when
                // codex_daemon changes, and a re-run would clear this feedback,
                // which tells the user to restart this pane's Codex.
                outcome = CodexDaemonStopOutcome(result: result)
            } catch {
                outcome = CodexDaemonStopOutcome(
                    errorDescription: "Could not turn off Codex's shared background server: \(error.localizedDescription)")
            }
            if Self.shouldRecordStopOutcome(
                initiatedEpisode: initiatedEpisode,
                currentEpisode: codexDaemonEpisode,
                initiatedReportSeq: initiatedReportSeq,
                currentReportSeq: codexDaemonReportSeq,
                outcome: outcome,
                latestCodexDaemon: timeline.codexDaemon
            ) {
                codexDaemonStopOutcome = outcome
            }
            isDisablingCodexDaemon = false
        }
    }
}
