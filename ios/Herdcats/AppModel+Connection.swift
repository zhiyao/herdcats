import Citadel
import Observation
import SwiftUI

extension AppModel {
    func connect(config: ConnectionConfig, isAutomatic: Bool = false) async {
        var config = config
        if isAutomatic, !canAutoReconnectNow() { return }
        guard !isDialing else { return }
        if !isAutomatic, !isOffline {
            reconnectBackoff.reset()
        }
        isDialing = true
        defer { isDialing = false }
        guard let state = await prepareConnectAttempt(config: config) else { return }

        guard ownership.isCurrent(state.attempt) else {
            state.watchdog.cancel()
            return
        }
        if isAutomatic, !isSceneActive || !hasActiveSession || hostKeyVerificationBlocked {
            state.watchdog.cancel()
            if case let .failed(generation) = ownership.fail(for: state.attempt) {
                connection.forceClose(generation: generation)
            }
            connectionIdentity = nil
            if hasActiveSession {
                phase = .offline(host: config.host, username: config.username)
                connectionBanner = .offline(message: "Offline · Connection lost", canRetry: true)
            } else {
                phase = .disconnected
                connectionBanner = nil
            }
            return
        }

        var isCheckingHerdr = false
        do {
            let onDisconnect: @Sendable (ConnectionGeneration) -> Void = { [weak self] lostGeneration in
                Task { @MainActor in
                    self?.handleConnectionLost(generation: lostGeneration)
                }
            }
            let generation: ConnectionGeneration
            if let customDialTransport {
                generation = try await customDialTransport(config, state.reserved, onDisconnect)
            } else {
                generation = try await connection.connect(
                    config,
                    expected: state.reserved,
                    onDisconnect: onDisconnect
                )
            }
            if !ownership.noteTransportInstalled(generation, for: state.attempt) {
                connection.forceClose(generation: generation)
                state.watchdog.cancel()
                return
            }
            // SSH setup is bounded by the watchdog. The two Herdr probes have
            // their own command deadlines and must report their own errors.
            state.watchdog.cancel()
            isCheckingHerdr = true
            let version: String
            if let customCheckHerdr {
                version = try await customCheckHerdr(config, generation)
            } else {
                // Auto looks for both runtimes up front. A saved runtime is checked on its own.
                let usesSavedRuntime = !config.detectsBackend
                if config.detectsBackend {
                    connectionProgressMessage = "Detecting Herdr…"
                    let found = try await connection.detectBackends()
                    guard ownership.isCurrent(state.attempt) else {
                        connection.forceClose(generation: generation)
                        return
                    }
                    // TUI has every feature; the machine picker offers Herdr Core when both exist.
                    config.backend = found.contains(.core) && !found.contains(.tui) ? .core : .tui
                    config.detectsBackend = false
                    await connection.adoptBackend(config.backend)
                    guard ownership.isCurrent(state.attempt) else { return }
                    activeConfig = config
                    connectionIdentity = ConnectionIdentity(config)
                    detectedBackends = found
                }
                connectionProgressMessage = config.backend == .core ? "Checking Herdr Core…" : "Checking Herdr…"
                #if DEBUG
                print("[HC] ssh connected, checking herdr…")
                #endif

                do {
                    version = try await connection.serverVersion(timeoutPolicy: .teardownSilently)
                } catch {
                    guard usesSavedRuntime, HerdrConnection.mayMeanRuntimeIsMissing(error, backend: config.backend) else {
                        throw error
                    }
                    // The saved runtime seems to be missing. Look for both runtimes on this
                    // connection, so the error can name the one the machine has instead.
                    guard ownership.isCurrent(state.attempt) else {
                        connection.forceClose(generation: generation)
                        return
                    }
                    connectionProgressMessage = "Detecting Herdr…"
                    let found = try? await connection.detectBackends(expected: generation)
                    guard ownership.isCurrent(state.attempt) else {
                        connection.forceClose(generation: generation)
                        return
                    }
                    throw HerdrConnection.missingRuntimeError(error, saved: config.backend, found: found)
                }
                #if DEBUG
                print("[HC] herdr version: \(version)")
                #endif
                if ownership.isCurrent(state.attempt) {
                    connectionProgressMessage = config.backend == .core ? "Reading Herdr Core terminals…" : "Checking \(config.sessionName) session…"
                }
                try await checkSessionReadiness()
            }
            let tabQueryClient = if config.backend == .tui {
                await connection.optionalTabAdmissionOwner(generation: generation)
            } else {
                nil as SSHClient?
            }
            guard ownership.isCurrent(state.attempt) else {
                connection.forceClose(generation: generation)
                return
            }
            if config.backend == .tui {
                guard tabQueryClient?.allowOptionalTabList() ?? (customDialTransport != nil) else {
                    throw HerdrError.notConnected
                }
            }
            readyTabQueryClient = tabQueryClient
            herdrVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
            phase = .connected(host: config.host, username: config.username)
            hasActiveSession = true
            reconnectBackoff.noteConnected(at: nowUptime())
            cancelReconnect()
            showBackOnline(message: state.wasOffline ? "Back online" : "Connected")
        } catch {
            state.watchdog.cancel()
            handleConnectFailure(
                error,
                config: config,
                attempt: state.attempt,
                wasOffline: state.wasOffline,
                isCheckingHerdr: isCheckingHerdr
            )
        }
    }

    func prepareConnectAttempt(
        config: ConnectionConfig
    ) async -> ConnectAttemptState? {
        revokeOptionalTabAdmission()
        lastConnectPassphraseRejected = false
        lastConnectNeedsSignIn = false
        hostKeyChallenge = nil
        hostKeyVerificationBlocked = false
        activeConfig = config
        detectedBackends = []
        let wasOffline = isOffline
        phase = .connecting
        if connectionBanner == nil || isOffline {
            connectionBanner = .connecting(message: wasOffline ? "Reconnecting…" : "Connecting…")
        }
        prepareConnectionStatus(for: config)
        let attempt = ownership.beginAttempt()

        // Reserve a transport generation before dialing so every close path
        // has an identity — never unscoped forceClose().
        let reserved = await connection.reserveConnectGeneration(runtimeChangeHandler: { [weak self] generation in
            Task { @MainActor in
                self?.noteRuntimeChange(generation: generation)
            }
        })
        guard ownership.associateReserved(reserved, for: attempt) else {
            // Stale attempt — close only this reservation; do not touch newer UI state.
            connection.forceClose(generation: reserved)
            return nil
        }

        let watchdog = Task { @MainActor [weak self] in
            let nanos = self?.connectWatchdogNanoseconds ?? 30_000_000_000
            do {
                try await Task.sleep(nanoseconds: nanos)
            } catch {
                return
            }
            self?.handleConnectWatchdog(attempt: attempt)
        }
        return ConnectAttemptState(
            attempt: attempt,
            reserved: reserved,
            wasOffline: wasOffline,
            watchdog: watchdog
        )
    }

    func handleConnectFailure(
        _ error: Error,
        config: ConnectionConfig,
        attempt: UInt64,
        wasOffline: Bool,
        isCheckingHerdr: Bool
    ) {
        #if DEBUG
        print("[HC] connect failed: \(error)")
        #endif
        switch ownership.fail(for: attempt) {
        case .stale:
            return
        case let .failed(generation):
            connection.forceClose(generation: generation)
            connectionIdentity = nil
            if let hostKeyError = error as? SSHHostKeyError {
                hostKeyVerificationBlocked = true
                switch hostKeyError {
                case let .unknown(challenge), let .changed(challenge):
                    hostKeyChallenge = challenge
                }
            } else if error is SSHHostKeyStore.StoreError {
                hostKeyVerificationBlocked = true
            }
            if hostKeyVerificationBlocked || error is OpenSSHKeyError { cancelReconnect() }
            let message = HerdrConnection.friendlyMessage(for: error, config: config)
            if let keyError = error as? OpenSSHKeyError {
                switch keyError {
                case .invalidPassphraseOrKey, .passphraseRequired: lastConnectPassphraseRejected = true
                default: lastConnectPassphraseRejected = false
                }
            }
            lastConnectNeedsSignIn = Self.needsSignIn(after: error)
            lastError = message
            if case let .runtimeNotInstalled(saved, available)? = error as? HerdrError {
                herdrMissingOnLastConnect = true
                runtimeMismatchOnLastConnect = available.map { RuntimeMismatch(saved: saved, installed: $0) }
            } else {
                herdrMissingOnLastConnect = (error as? HerdrError) == .herdrNotFound
                runtimeMismatchOnLastConnect = nil
            }
            herdrSessionUnavailableOnLastConnect = (error as? HerdrError) == .sessionUnavailable
            switch Self.connectFailureDisposition(
                error: error,
                hadActiveSession: hasActiveSession,
                wasOffline: wasOffline,
                isCheckingHerdr: isCheckingHerdr
            ) {
            case .readinessRecovery:
                // Key errors require editable credentials, and readiness errors
                // require setup recovery. Clear the session so connection selection
                // is reachable and the launch overlay cannot remain blocking.
                hasActiveSession = false
                reconnectBackoff.reset()
                cancelReconnect()
                connectionBanner = nil
                phase = .disconnected
            case .offlineRetry:
                if hostKeyVerificationBlocked {
                    reconnectBackoff.reset()
                } else {
                    reconnectBackoff.noteFailure()
                }
                phase = .offline(host: config.host, username: config.username)
                connectionBanner = .offline(
                    message: "Offline · \(message)",
                    canRetry: true
                )
                scheduleAutoReconnect()
            case .disconnected:
                reconnectBackoff.reset()
                phase = .disconnected
            }
        }
    }

    static func needsSignIn(after error: Error) -> Bool {
        if error is OpenSSHKeyError { return true }
        if error is SSHHostKeyError || error is SSHHostKeyStore.StoreError || error is HerdrError { return false }
        let description = String(describing: error).lowercased()
        return description.contains("authentication")
    }

    static func connectFailureDisposition(
        error: Error,
        hadActiveSession: Bool,
        wasOffline: Bool,
        isCheckingHerdr: Bool
    ) -> ConnectFailureDisposition {
        if error is OpenSSHKeyError { return .readinessRecovery }
        let needsReadinessRecovery = switch error as? HerdrError {
        case .herdrNotFound?, .runtimeNotInstalled?, .sessionUnavailable?: true
        default: false
        }
        if isCheckingHerdr && (!wasOffline || !hadActiveSession || needsReadinessRecovery) {
            return .readinessRecovery
        }
        if hadActiveSession { return .offlineRetry }
        return .disconnected
    }
}
