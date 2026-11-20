import Citadel
import Observation
import SwiftUI

enum ReconnectBackoffPolicy {
    static let initialDelaySeconds: TimeInterval = 2.5
    static let maxDelaySeconds: TimeInterval = 60.0
    static let stableConnectionThreshold: TimeInterval = 30.0
    /// Bounded jitter spreads retries within [0.75 * base, base] so outages
    /// back off progressively without exceeding `maxDelaySeconds`.
    static let minJitterMultiplier: Double = 0.75

    static func delaySeconds(failureCount: Int, jitterUnit: Double) -> TimeInterval {
        let clampedFailures = max(0, failureCount)
        let exponent = min(clampedFailures, 10)
        let base = min(maxDelaySeconds, initialDelaySeconds * pow(2.0, Double(exponent)))
        let unit = min(1.0, max(0.0, jitterUnit))
        let multiplier = minJitterMultiplier + (1.0 - minJitterMultiplier) * unit
        return min(maxDelaySeconds, base * multiplier)
    }
}

struct ReconnectBackoffState: Equatable, Sendable {
    private(set) var failureCount = 0
    private(set) var connectedAt: TimeInterval?

    mutating func noteConnected(at now: TimeInterval) {
        connectedAt = now
    }

    mutating func noteFailure() {
        connectedAt = nil
        failureCount += 1
    }

    mutating func noteDisconnectedFromConnected(at now: TimeInterval) {
        defer { connectedAt = nil }
        if let connectedAt, now - connectedAt >= ReconnectBackoffPolicy.stableConnectionThreshold {
            failureCount = 0
        } else {
            failureCount += 1
        }
    }

    mutating func reset() {
        connectedAt = nil
        failureCount = 0
    }

    func nextDelaySeconds(jitterUnit: Double) -> TimeInterval {
        ReconnectBackoffPolicy.delaySeconds(failureCount: failureCount, jitterUnit: jitterUnit)
    }
}

extension AppModel {
    func prepareConnectionStatus(for config: ConnectionConfig) {
        lastError = nil
        connectionProgressMessage = "Signing in over SSH…"
        herdrMissingOnLastConnect = false
        runtimeMismatchOnLastConnect = nil
        herdrSessionUnavailableOnLastConnect = false
        connectionIdentity = ConnectionIdentity(config)
    }

    /// Whether the last connect attempt was for `entry`'s machine and runtime.
    func lastConnectWasFor(_ entry: RecentConnection) -> Bool {
        guard let activeConfig else { return false }
        let shown = ConnectionIdentity(host: entry.host, port: entry.port, username: entry.username, backend: entry.backend)
        // The stored form ignores the case of the host name.
        return ConnectionIdentity(activeConfig).storageKey == shown.storageKey
    }

    /// Shows `message` as a plain error in place of a Herdr recovery card.
    func showPlainError(_ message: String) {
        herdrMissingOnLastConnect = false
        runtimeMismatchOnLastConnect = nil
        herdrSessionUnavailableOnLastConnect = false
        lastError = message
    }

    func checkSessionReadiness() async throws {
        // --version confirms the binary only; a space query confirms the
        // selected source is ready for the screens we present next.
        do {
            _ = try await connection.workspaceList(timeoutPolicy: .teardownSilently)
        } catch {
            throw Self.sessionReadinessError(error)
        }
    }

    static func sessionReadinessError(_ error: Error) -> Error {
        guard let herdrError = error as? HerdrError else { return error }
        switch herdrError {
        case let .api(code, message):
            let missingSessionPhrases = [
                "no default session", "default session not found", "default session is missing",
                "default session is unavailable", "default session does not exist"
            ]
            if code == "session_unavailable"
                || missingSessionPhrases.contains(where: { message.localizedCaseInsensitiveContains($0) }) {
                return HerdrError.sessionUnavailable
            }
            return error
        default:
            return error
        }
    }

    /// Approval only persists the exact displayed key; the next handshake verifies it again.
    func approveHostKey(_ challenge: SSHHostKeyChallenge, store: SSHHostKeyStore = .shared) async -> Bool {
        guard hostKeyChallenge == challenge, !isDialing else { return false }
        do {
            if let previousKey = challenge.previousPublicKey {
                try await store.replace(challenge.publicKey, replacing: previousKey,
                                        host: challenge.host, port: challenge.port)
            } else {
                try await store.trust(challenge.publicKey, host: challenge.host, port: challenge.port)
            }
            guard hostKeyChallenge == challenge else { return false }
            hostKeyChallenge = nil
            hostKeyVerificationBlocked = false
            lastError = nil
            return true
        } catch {
            lastError = HerdrConnection.friendlyMessage(for: error)
            return false
        }
    }

    func cancelHostKeyApproval() {
        hostKeyChallenge = nil
        cancelReconnect()
    }

    func disconnect() async {
        cancelReconnect()
        let owned = ownership
        if let generation = owned.transportGeneration {
            let client = await connection.optionalTabAdmissionOwner(generation: generation)
            guard ownership == owned else { return }
            client?.invalidateOptionalTabList()
        }
        reconnectBackoff.reset()
        lastScheduledAutoReconnectDelay = nil
        dismissBannerTask?.cancel()
        connectionBanner = nil
        hasActiveSession = false
        activeConfig = nil
        hostKeyChallenge = nil
        hostKeyVerificationBlocked = false
        let generation = ownership.disconnect()
        phase = .disconnected
        herdrVersion = nil
        connectionIdentity = nil
        if let generation {
            connection.forceClose(generation: generation)
        }
        // If somehow no generation was reserved, invalidate whatever is current
        // via a fresh reserve-and-close would be wrong; leave transport alone.
    }

    /// Returns the user to the connection screen if a remembered credential
    /// could not be persisted after authentication succeeded.
    func reportCredentialStorageError(_ message: String) async {
        await disconnect()
        lastError = message
    }

    func handleConnectWatchdog(attempt: UInt64) {
        guard case .connecting = phase else { return }
        switch ownership.watchdogTimeout(for: attempt) {
        case .stale:
            return
        case let .timedOut(generation):
            lastError = "The connection attempt timed out."
            connection.forceClose(generation: generation)
            connectionIdentity = nil
            if hasActiveSession, let config = activeConfig {
                reconnectBackoff.noteFailure()
                phase = .offline(host: config.host, username: config.username)
                connectionBanner = .offline(message: "Offline · Connection timed out", canRetry: true)
                scheduleAutoReconnect()
            } else {
                reconnectBackoff.reset()
                phase = .disconnected
            }
        }
    }

    func handleConnectionLost(generation: ConnectionGeneration) {
        // Invalidates the app attempt so delayed serverVersion cannot promote.
        guard ownership.handleLoss(generation: generation) else { return }
        switch phase {
        case let .connected(host, username):
            reconnectBackoff.noteDisconnectedFromConnected(at: nowUptime())
            phase = .offline(host: host, username: username)
            connectionBanner = .offline(message: "Offline · Connection lost", canRetry: true)
            scheduleAutoReconnect()
        case .connecting:
            if hasActiveSession, let config = activeConfig {
                reconnectBackoff.noteFailure()
                phase = .offline(host: config.host, username: config.username)
                connectionBanner = .offline(message: "Offline · Connection lost", canRetry: true)
                scheduleAutoReconnect()
            } else {
                reconnectBackoff.reset()
                connectionIdentity = nil
                phase = .disconnected
                lastError = "The connection was lost during handshake."
            }
        case .offline:
            reconnectBackoff.noteFailure()
            scheduleAutoReconnect()
        case .disconnected:
            break
        }
    }
}
