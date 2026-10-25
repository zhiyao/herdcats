import Foundation
import Observation

@MainActor
@Observable
final class ActiveMachine {
    private(set) var model: AppModel
    private(set) var pending: AppModel?
    private(set) var pendingLabel: String?
    var switchError: String?
    var pendingHostKeyOwnedByForm = false
    private(set) var signInFailure: SignInFailure?

    struct SignInFailure: Equatable {
        let needsSignIn: Bool
        let passphraseRejected: Bool
    }

    enum SwitchOutcome: Equatable {
        case switched, alreadyActive, needsCredentials, failed, superseded
    }

    private let makeModel: @MainActor () -> AppModel
    private let dial: @MainActor (AppModel, ConnectionConfig) async -> Void
    private var target: (entry: RecentConnection, config: ConnectionConfig, recordConnection: Bool)?
    private var revision: UInt64 = 0
    private var dialingRevision: UInt64?

    init(
        model: AppModel? = nil,
        makeModel: @escaping @MainActor () -> AppModel = { AppModel(autoConnectOnLaunch: false) },
        dial: @escaping @MainActor (AppModel, ConnectionConfig) async -> Void = { await $0.connect(config: $1) }
    ) {
        self.model = model ?? AppModel()
        self.makeModel = makeModel
        self.dial = dial
    }

    func switchMachine(to entry: RecentConnection, config: ConnectionConfig? = nil, recordConnection: Bool = true) async -> SwitchOutcome {
        let identity = ConnectionIdentity(host: entry.host, port: entry.port, username: entry.username)
        if identity == model.connectionIdentity, case .connected = model.phase {
            // Re-selecting the current machine is the latest choice; drop any switch in flight.
            await cancelSwitch()
            return .alreadyActive
        }
        if let target, identity == ConnectionIdentity(target.config) { return .superseded }
        guard let config = config ?? RecentConnectionStore.config(for: entry) else {
            // The form opened for this machine replaces any earlier selection.
            await cancelSwitch()
            return .needsCredentials
        }

        // Invalidate before awaiting teardown so a later selection owns the next dial.
        revision += 1
        let currentRevision = revision
        let previous = pending
        clearPending()
        if let previous { await previous.disconnect() }
        guard revision == currentRevision else { return .superseded }

        let candidate = makeModel()
        pending = candidate
        pendingLabel = entry.shortDisplayName(among: recordConnection
            ? (try? RecentConnectionStore.load()) ?? [] : RecentConnectionStore.snapshot())
        target = (entry, config, recordConnection)
        switchError = nil
        signInFailure = nil
        return await dialAndFinish(candidate, entry: entry, config: config, revision: currentRevision, recordConnection: recordConnection)
    }

    func finishPendingSwitch() async -> SwitchOutcome {
        guard let candidate = pending, let target, dialingRevision != revision else { return .superseded }
        return await dialAndFinish(candidate, entry: target.entry, config: target.config, revision: revision, recordConnection: target.recordConnection)
    }

    func cancelSwitch() async {
        signInFailure = nil
        revision += 1
        let candidate = pending
        clearPending()
        if let candidate { await candidate.disconnect() }
    }

    /// Explicit user disconnect: a switch still dialing must not bring the session back.
    func disconnect() async {
        await cancelSwitch()
        await model.disconnect()
    }

    private func dialAndFinish(
        _ candidate: AppModel, entry: RecentConnection, config: ConnectionConfig, revision currentRevision: UInt64, recordConnection: Bool
    ) async -> SwitchOutcome {
        dialingRevision = currentRevision
        defer { if dialingRevision == currentRevision { dialingRevision = nil } }
        await dial(candidate, config)
        guard revision == currentRevision, pending === candidate else {
            await candidate.disconnect()
            return .superseded
        }
        if candidate.hostKeyChallenge != nil { return .failed }

        if case .connected = candidate.phase {
            let old = model
            model = candidate
            clearPending()
            do {
                if recordConnection { try RecentConnectionStore.record(entry, in: RecentConnectionStore.load()) }
            } catch {
                switchError = "Could not save \(entry.displayName): \(error.localizedDescription)"
            }
            await old.disconnect()
            return .switched
        }

        signInFailure = SignInFailure(needsSignIn: candidate.lastConnectNeedsSignIn,
            passphraseRejected: candidate.lastConnectPassphraseRejected)
        switchError = "Couldn't reach \(entry.displayName): \(candidate.lastError ?? "Connection failed")"
        clearPending()
        await candidate.disconnect()
        return .failed
    }

    private func clearPending() {
        pending = nil
        pendingLabel = nil
        target = nil
    }
}

// Compact sign-in and setup both use the make-before-break switch lifecycle.
extension ActiveMachine {
    func signIn(using value: ConnectionSignIn, replay: Bool = false) async throws -> SwitchOutcome {
        guard value.isReady else { return .needsCredentials }
        if !replay { try value.prepareAttempt() }
        let outcome = await switchMachine(to: value.entry, config: value.config, recordConnection: !replay)
        if outcome == .switched && !replay { try persistSignIn(value) }
        return outcome
    }

    func finishSignIn(using value: ConnectionSignIn, replay: Bool = false) async throws -> SwitchOutcome {
        let outcome = await finishPendingSwitch()
        if outcome == .switched && !replay { try persistSignIn(value) }
        return outcome
    }

    private func persistSignIn(_ value: ConnectionSignIn) throws {
        do { try value.persist(connected: false) }
        catch {
            switchError = "Connected, but could not save sign-in: \(error.localizedDescription)"
            throw error
        }
    }

}
