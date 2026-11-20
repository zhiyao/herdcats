import Citadel
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable, Sendable {
        case disconnected
        case connecting
        case connected(host: String, username: String)
        case offline(host: String, username: String)
    }

    var phase: Phase = .disconnected
    var hasActiveSession: Bool
    var activeConfig: ConnectionConfig? {
        didSet {
            if oldValue?.navigationScope != activeConfig?.navigationScope {
                sessions = []
                sessionListError = nil
            }
        }
    }
    /// Runtimes the Auto probe found on the last connect; empty when it did not run.
    var detectedBackends: Set<ConnectionBackend> = []
    var isCoreMode: Bool { activeConfig?.backend == .core }
    var isReadyForTerminalInput: Bool {
        if case .connected = phase { return true }
        return false
    }
    var paneConnectionIdentity: ConnectionIdentity? {
        connectionIdentity?.scopedToSession(activeConfig?.session?.name)
    }
    var sessions: [HerdrSession] = []
    var isLoadingSessions = false
    var sessionListError: String?

    func refreshSessions(load: (() async throws -> [HerdrSession])? = nil) async {
        guard !isCoreMode, isReadyForTerminalInput, !isLoadingSessions else { return }
        let owned = ownership
        let scope = activeConfig?.navigationScope
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        do {
            let values: [HerdrSession]
            if let load { values = try await load() }
            else { values = try await connection.sessionList() }
            guard !Task.isCancelled, ownership == owned, activeConfig?.navigationScope == scope else { return }
            sessions = values
            sessionListError = nil
        } catch {
            guard !Task.isCancelled, ownership == owned, activeConfig?.navigationScope == scope else { return }
            sessionListError = HerdrConnection.friendlyMessage(for: error)
        }
    }

    var runtimeRevision: UInt64 = 0
    var runtimeRefreshTask: Task<Void, Never>?

    func noteRuntimeChange(generation: ConnectionGeneration) {
        guard ownership.transportGeneration == generation, runtimeRefreshTask == nil else { return }
        runtimeRefreshTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self else { return }
            self.runtimeRefreshTask = nil
            guard self.ownership.transportGeneration == generation else { return }
            self.runtimeRevision &+= 1
        }
    }
    var connectionBanner: ConnectionBanner?
    var lastConnectPassphraseRejected = false
    var lastConnectNeedsSignIn = false
    var lastError: String?
    var connectionProgressMessage = "Connecting…"
    var herdrMissingOnLastConnect = false
    /// The connection's saved runtime isn't on the machine, but the other one is.
    struct RuntimeMismatch: Equatable {
        let saved: ConnectionBackend
        let installed: ConnectionBackend
    }
    /// Set with `herdrMissingOnLastConnect` when the machine has the other runtime.
    var runtimeMismatchOnLastConnect: RuntimeMismatch?
    var herdrSessionUnavailableOnLastConnect = false
    var herdrVersion: String?
    var connectionIdentity: ConnectionIdentity? {
        didSet { if oldValue != connectionIdentity { optimisticPaneStatus.reset() } }
    }
    var hostKeyChallenge: SSHHostKeyChallenge?
    var hostKeyVerificationBlocked = false
    var isSceneActive = true {
        didSet {
            guard oldValue != isSceneActive, !isSceneActive else { return }
            cancelReconnect()
        }
    }

    /// Production ownership primitive — unit tests exercise this same type.
    var ownership = ConnectionSessionOwnership() {
        // A new transport may restart pane revisions, so old overrides can't be ordered against them.
        didSet { if oldValue.transportGeneration != ownership.transportGeneration { optimisticPaneStatus.reset() } }
    }

    /// Local "working" shown from prompt submission until the pane list confirms.
    let optimisticPaneStatus = OptimisticPaneStatus()
    let phoneAnswers = PhoneAnswersStore()
    let connection: HerdrConnection
    @ObservationIgnored var readyTabQueryClient: SSHClient?

    func revokeOptionalTabAdmission() {
        readyTabQueryClient?.invalidateOptionalTabList()
        readyTabQueryClient = nil
    }
    var dismissBannerTask: Task<Void, Never>?
    var autoReconnectTask: Task<Void, Never>?
    var isDialing = false
    var reconnectBackoff = ReconnectBackoffState()
    @ObservationIgnored var lastScheduledAutoReconnectDelay: TimeInterval?

    /// Test seams for deterministic fake-clock, jitter, sleep, and dial tests.
    @ObservationIgnored var nowUptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored var sleepSeconds: (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }
    @ObservationIgnored var reconnectJitterUnit: () -> Double = { Double.random(in: 0...1) }
    @ObservationIgnored var customDialTransport: (
        (ConnectionConfig, ConnectionGeneration, @escaping @Sendable (ConnectionGeneration) -> Void) async throws -> ConnectionGeneration
    )?
    @ObservationIgnored var customCheckHerdr: ((ConnectionConfig, ConnectionGeneration) async throws -> String)?

    var connectedOrOfflineHost: String? {
        switch phase {
        case let .connected(host, _), let .offline(host, _): return host
        case .disconnected, .connecting: return nil
        }
    }

    var machineDisplayName: String {
        connectedOrOfflineHost ?? "Remote Machine"
    }

    init(
        connection: HerdrConnection = HerdrConnection(),
        autoConnectOnLaunch: Bool = true
    ) {
        self.connection = connection
        if autoConnectOnLaunch,
           let autoConfig = AutoConnect.configIfRequested() ?? LaunchPreference.autoConnectConfig() {
            self.hasActiveSession = true
            self.activeConfig = autoConfig
            self.phase = .disconnected
            self.connectionBanner = .connecting(message: "Connecting…")
        } else {
            self.hasActiveSession = false
            self.phase = .disconnected
        }
    }

    /// Test seam: overrides the 30s connect watchdog sleep.
    var connectWatchdogNanoseconds: UInt64 = 30_000_000_000

    var isConnecting: Bool {
        if case .connecting = phase { return true }
        return false
    }

    var isOffline: Bool {
        if case .offline = phase { return true }
        return false
    }

    func showBackOnline(message: String = "Back online") {
        dismissBannerTask?.cancel()
        withAnimation(.easeInOut(duration: 0.25)) {
            connectionBanner = .backOnline(message: message)
        }
        dismissBannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                self?.connectionBanner = nil
            }
        }
    }

    var canScheduleAutoReconnect: Bool {
        isSceneActive
            && hasActiveSession
            && activeConfig != nil
            && isOffline
            && !hostKeyVerificationBlocked
    }

    func canAutoReconnectNow() -> Bool {
        canScheduleAutoReconnect && !isDialing
    }

    func scheduleAutoReconnect() {
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
        guard canScheduleAutoReconnect else { return }
        let delaySeconds = reconnectBackoff.nextDelaySeconds(jitterUnit: reconnectJitterUnit())
        lastScheduledAutoReconnectDelay = delaySeconds
        autoReconnectTask = Task { @MainActor [weak self] in
            do {
                try await self?.sleepSeconds(delaySeconds)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard self.canAutoReconnectNow() else { return }
            // The reconnect task is handing control to reconnect(). Clear its
            // slot first so reconnect() does not cancel the task that is now
            // performing the SSH attempt.
            self.autoReconnectTask = nil
            await self.reconnect(automatically: true)
        }
    }

    func cancelReconnect() {
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
    }

    func reconnect(automatically: Bool = false) async {
        if automatically {
            guard canAutoReconnectNow() else { return }
        } else {
            guard activeConfig != nil, !isDialing else { return }
        }
        guard let config = activeConfig else { return }
        cancelReconnect()
        #if DEBUG
        print("[HC] reconnecting to \(config.host):\(config.port)")
        #endif
        connectionBanner = .connecting(message: "Reconnecting…")
        await connect(config: config, isAutomatic: automatically)
    }
}
