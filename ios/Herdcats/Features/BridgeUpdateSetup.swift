import Observation
import SwiftUI

/// Machine-level, explicit Herdcats Bridge update for the connected host. It
/// needs no agent pane: it reuses the existing host-helper setup flow with
/// `agent: nil`. Owned by one (host, connection generation); it cancels itself
/// when either changes, and never runs without an explicit tap.
@MainActor @Observable
final class BridgeUpdateSetup: Identifiable {
    typealias Runner = @MainActor (
        _ replace: Bool, _ checkOnly: Bool, _ release: BridgeRelease,
        _ onStage: @escaping @Sendable (HostHelperSetupStage) async -> Void
    ) async throws -> HostHelperSetupDecision

    typealias Prober = @MainActor () async throws -> String?

    let id = UUID()
    let prompt: BridgeUpdatePrompt
    let generation: ConnectionGeneration
    private(set) var stage: HostHelperSetupStage = .idle
    private(set) var feedback: String?
    private(set) var isFinished = false
    private let runner: Runner
    private let prober: Prober
    private let onInstalled: @MainActor () -> Void
    private var task: Task<Void, Never>?
    private var token: UUID?
    private var mayHaveInstalled = false

    init(prompt: BridgeUpdatePrompt, generation: ConnectionGeneration,
         runner: @escaping Runner, prober: @escaping Prober, onInstalled: @escaping @MainActor () -> Void) {
        self.prompt = prompt
        self.generation = generation
        self.runner = runner
        self.prober = prober
        self.onInstalled = onInstalled
    }

    var isBusy: Bool { stage.isBusy }
    var installRelease: BridgeRelease? { prompt.available.verifiedInstaller }

    /// Primary action. Does nothing without a verified installer.
    func install() {
        guard task == nil, !stage.isBusy, let release = installRelease else { return }
        let checkOnly = stage == .uncertain
        var replacing = false
        if case .replacementRequired = stage { replacing = true }
        run(release: release, replace: replacing, checkOnly: checkOnly)
    }

    /// Read-only re-check of the host (the manual-setup path's "Check again").
    func checkAgain() {
        guard task == nil, !stage.isBusy else { return }
        run(release: installRelease ?? .pinned, replace: false, checkOnly: true, manual: installRelease == nil, manualTarget: prompt.available.version)
    }

    /// Every way of leaving the sheet (Not now, swipe, stale ownership) ends
    /// here: stop any in-flight work, and snooze this host+release for the
    /// launch so the banner does not instantly return.
    func finish(snoozingIn checker: BridgeUpdateChecker?) {
        cancel()
        checker?.dismiss(prompt)
    }

    func cancel() {
        guard let task else { return }
        token = nil
        self.task = nil
        task.cancel()
        stage = mayHaveInstalled ? .uncertain : .idle
        feedback = mayHaveInstalled
            ? "Installation may have finished on the host. Check installation before trying again."
            : "The host check stopped. No installation was started."
    }

    private func run(release: BridgeRelease, replace: Bool, checkOnly: Bool, manual: Bool = false, manualTarget: String? = nil) {
        let mine = UUID()
        token = mine
        feedback = nil
        stage = .checking
        mayHaveInstalled = checkOnly && mayHaveInstalled
        task = Task { @MainActor in
            do {
                let result: HostHelperSetupDecision
                if manual {
                    result = try await manualCheck(target: manualTarget ?? release.version)
                } else {
                    result = try await runner(replace, checkOnly, release) { [weak self] stage in
                        await self?.commit(stage, token: mine)
                    }
                }
                try Task.checkCancellation()
                guard token == mine else { return }
                task = nil
                switch result {
                case .ready:
                    stage = .installed
                    isFinished = true
                    onInstalled()
                case .missing:
                    stage = .idle
                    feedback = "No Herdcats Bridge was found on this computer."
                case .replacementRequired(let probe):
                    stage = .replacementRequired(probe)
                    feedback = HostHelperSetupPlan.replacementFeedback(probe: probe)
                    if checkOnly, case .present(let version, _, _) = probe, let version {
                        feedback = "Herdcats Bridge on this computer is still \(version)."
                    }
                    if manual { stage = .idle }
                case .install, .unsupportedByPinnedInstaller:
                    throw HostHelperSetupError.invalidResponse
                }
            } catch {
                guard token == mine else { return }
                task = nil
                if mayHaveInstalled {
                    stage = .uncertain
                    feedback = "Installation could not be confirmed. It may have finished on the host. Check installation before trying again, or use manual setup."
                } else if let setupError = error as? HostHelperSetupError {
                    stage = .idle
                    feedback = setupError.localizedDescription
                } else {
                    stage = .idle
                    feedback = "The host could not be checked. Reconnect and try again, or use manual setup. No installation was started."
                }
            }
        }
    }

    private func commit(_ stage: HostHelperSetupStage, token: UUID) {
        guard self.token == token else { return }
        self.stage = stage
        if stage == .installing { mayHaveInstalled = true }
    }

    /// Manual-only release: the app runs nothing but a read-only version probe.
    private func manualCheck(target: String) async throws -> HostHelperSetupDecision {
        guard let version = try await prober() else { return .missing }
        let probe = HostHelperProbe.present(version: version, managed: true, compatible: true)
        return HostHelperProbe.isOlder(version, than: target) ? .replacementRequired(probe) : .ready
    }
}

extension HerdrConnection {
    /// Production runner for `BridgeUpdateSetup`: `agent: nil`, explicit-update reason.
    @MainActor func bridgeUpdateRunner(host: ConnectionIdentity, generation: ConnectionGeneration) -> BridgeUpdateSetup.Runner {
        { replace, checkOnly, release, onStage in
            try await self.setUpHostHelper(
                replace: replace, checkOnly: checkOnly, target: host, owned: generation, agent: nil,
                reason: .updateRequired, release: release, onStage: onStage)
        }
    }
}

/// Lets the per-tab banner open the root-owned sheet.
private struct BridgeUpdateOpenKey: EnvironmentKey {
    static let defaultValue: ((BridgeUpdatePrompt) -> Void)? = nil
}

private struct BridgeUpdateSheetOpenKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var openBridgeUpdate: ((BridgeUpdatePrompt) -> Void)? {
        get { self[BridgeUpdateOpenKey.self] }
        set { self[BridgeUpdateOpenKey.self] = newValue }
    }

    var bridgeUpdateSheetOpen: Bool {
        get { self[BridgeUpdateSheetOpenKey.self] }
        set { self[BridgeUpdateSheetOpenKey.self] = newValue }
    }
}

/// The update notice for the active host, or nil when there is nothing to show.
@MainActor private func currentBridgeUpdatePrompt(appModel: AppModel, active: ActiveMachine?) -> BridgeUpdatePrompt? {
    #if DEBUG
    // Layout preview: `-hc.preview-bridge-update` (verified Update button) or
    // `-hc.preview-bridge-update manual` (Details). Banner only; no host needed.
    let args = ProcessInfo.processInfo.arguments
    if let i = args.firstIndex(of: "-hc.preview-bridge-update") {
        let manual = args.indices.contains(i + 1) && args[i + 1] == "manual"
        return BridgeUpdatePrompt(
            host: ConnectionIdentity(host: "preview.local", port: 22, username: "preview"),
            installed: "0.5.0",
            available: manual
                ? BridgeReleaseInfo(version: "0.6.0", verifiedInstaller: nil)
                : BridgeReleaseInfo(version: "0.5.0", verifiedInstaller: .pinned))
    }
    #endif
    guard !appModel.isCoreMode, appModel.isReadyForTerminalInput,
          let host = appModel.connectionIdentity, host.backend == .tui
    else { return nil }
    return active?.bridgeUpdates.prompt(activeHost: host, generation: appModel.ownership.transportGeneration)
}

/// Banner pinned just above the tab bar. Apply to each tab's content: a bottom
/// safe-area inset inside a tab sits above the tab bar and reserves its space,
/// so it never covers content or navigation.
struct BridgeUpdateBannerInset: ViewModifier {
    @Environment(AppModel.self) private var appModel
    @Environment(ActiveMachine.self) private var active: ActiveMachine?
    @Environment(\.openBridgeUpdate) private var open
    @Environment(\.bridgeUpdateSheetOpen) private var sheetOpen

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if let prompt = currentBridgeUpdatePrompt(appModel: appModel, active: active), !sheetOpen {
                BridgeUpdateBanner(
                    prompt: prompt,
                    onOpen: { open?(prompt) },
                    onDismiss: { active?.bridgeUpdates.dismiss(prompt) }
                )
                .padding(.vertical, 4)
                .transition(.opacity)
            }
        }
    }
}

/// Root-level sheet owner. The banner itself lives in each tab
/// (`bridgeUpdateBanner()`) so it can sit above the tab bar.
struct BridgeUpdateHost: ViewModifier {
    @Environment(AppModel.self) private var appModel
    @Environment(ActiveMachine.self) private var active: ActiveMachine?
    @State private var setup: BridgeUpdateSetup?

    func body(content: Content) -> some View {
        content
            .environment(\.openBridgeUpdate) { open($0) }
            .environment(\.bridgeUpdateSheetOpen, setup != nil)
            .sheet(item: Binding(
                get: { setup },
                set: { if $0 == nil, let current = setup { close(current) } }
            )) { setup in
                BridgeUpdateSheet(setup: setup, appModel: appModel) { self.close(setup) }
            }
            // Host or connection ownership changed: the sheet's target is gone.
            .onChange(of: appModel.connectionIdentity) { _, _ in closeIfStale() }
            .onChange(of: appModel.ownership.transportGeneration) { _, _ in closeIfStale() }
            .onChange(of: appModel.isReadyForTerminalInput) { _, _ in closeIfStale() }
    }

    private func open(_ prompt: BridgeUpdatePrompt) {
        guard let generation = appModel.ownership.transportGeneration, let checker = active?.bridgeUpdates else { return }
        setup = BridgeUpdateSetup(
            prompt: prompt, generation: generation,
            runner: appModel.connection.bridgeUpdateRunner(host: prompt.host, generation: generation),
            prober: { [connection = appModel.connection] in
                try await connection.probeInstalledBridgeVersion(target: prompt.host, owned: generation)
            },
            onInstalled: { checker.invalidateObservation() })
    }

    private func close(_ setup: BridgeUpdateSetup) {
        // Acting on the prompt counts as seeing it; a finished install is also
        // removed by the refreshed observation.
        setup.finish(snoozingIn: active?.bridgeUpdates)
        self.setup = nil
    }

    private func closeIfStale() {
        guard let setup else { return }
        if appModel.connectionIdentity != setup.prompt.host
            || appModel.ownership.transportGeneration != setup.generation
            || !appModel.isReadyForTerminalInput {
            setup.cancel()
            self.setup = nil
        }
    }
}

private struct BridgeUpdateSheet: View {
    let setup: BridgeUpdateSetup
    let appModel: AppModel
    let onClose: () -> Void

    var body: some View {
        AgentBridgeSetupView(
            reason: .updateRequired, agent: nil, installedVersion: setup.prompt.installed,
            pinnedVersion: setup.prompt.available.version,
            installAvailable: setup.installRelease != nil,
            dismissLabel: "Not now", showsPiExtensionReminder: true, installedLabel: "Done",
            isChecking: false, feedback: setup.feedback,
            stage: setup.stage, target: setup.prompt.host,
            canInstall: appModel.isReadyForTerminalInput
                && appModel.connectionIdentity == setup.prompt.host
                && appModel.ownership.transportGeneration == setup.generation
                && setup.installRelease != nil,
            onInstall: { setup.isFinished ? onClose() : setup.install() },
            onCheckAgain: { setup.checkAgain() },
            onUseTerminal: onClose
        )
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .interactiveDismissDisabled(setup.isBusy)
    }
}

extension View {
    func bridgeUpdateHost() -> some View { modifier(BridgeUpdateHost()) }
    func bridgeUpdateBanner() -> some View { modifier(BridgeUpdateBannerInset()) }
}
