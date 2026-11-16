import Foundation
import Testing
@testable import Herdcats

@Suite("AppModel reconnect backoff and scene awareness")
@MainActor
struct AppModelReconnectPolicyTests {
    private func makeConfig(host: String = "mac.example") -> ConnectionConfig {
        ConnectionConfig(host: host, port: 22, username: "tester", auth: .password("fixture"))
    }

    @Test func exponentialBackoffIsBoundedWithJitterAndResetsOnStableSuccess() {
        // Without jitter penalty (unit = 1.0), delays follow 2.5 * 2^n capped at 60s.
        let expectedMaxes: [TimeInterval] = [2.5, 5.0, 10.0, 20.0, 40.0, 60.0, 60.0]
        for (failures, expected) in expectedMaxes.enumerated() {
            #expect(ReconnectBackoffPolicy.delaySeconds(failureCount: failures, jitterUnit: 1.0) == expected)
            #expect(ReconnectBackoffPolicy.delaySeconds(failureCount: failures, jitterUnit: 0.0) == expected * 0.75)
        }

        // Jitter spreads delays even at the 60s cap without exceeding it.
        let lowCap = ReconnectBackoffPolicy.delaySeconds(failureCount: 10, jitterUnit: 0.0)
        let highCap = ReconnectBackoffPolicy.delaySeconds(failureCount: 10, jitterUnit: 1.0)
        #expect(lowCap < highCap)
        #expect(lowCap == 45.0)
        #expect(highCap == 60.0)

        var state = ReconnectBackoffState()
        state.noteFailure()
        state.noteFailure()
        #expect(state.failureCount == 2)

        // Rapid disconnect before the 30s stability threshold does not reset backoff.
        state.noteConnected(at: 100)
        state.noteDisconnectedFromConnected(at: 110)
        #expect(state.failureCount == 3)

        // Connection surviving >= 30s resets backoff to step 0 on subsequent loss.
        state.noteConnected(at: 200)
        state.noteDisconnectedFromConnected(at: 235)
        #expect(state.failureCount == 0)
        #expect(state.nextDelaySeconds(jitterUnit: 1.0) == 2.5)
    }

    @Test func pendingAutoReconnectCancelsWhenSceneBecomesInactiveAndLossWhileInactiveNeverDials() async throws {
        let config = makeConfig()
        let model = AppModel(autoConnectOnLaunch: false)
        var now: TimeInterval = 100
        model.nowUptime = { now }
        model.reconnectJitterUnit = { 1.0 }

        var dialCount = 0
        model.customDialTransport = { _, reserved, _ in
            dialCount += 1
            return reserved
        }
        model.customCheckHerdr = { _, _ in "herdr 0.8.6" }

        var sleepDelays: [TimeInterval] = []
        let sleepStarted = ExternallyReleasedWait<Void>()
        let releaseSleep = ExternallyReleasedWait<Void>()
        model.sleepSeconds = { seconds in
            sleepDelays.append(seconds)
            sleepStarted.release(())
            _ = try await releaseSleep.wait()
        }

        // Connect cleanly first.
        await model.connect(config: config)
        #expect(dialCount == 1)
        #expect(model.phase == .connected(host: config.host, username: config.username))

        // Lose connection after 40s (stable): schedules initial 2.5s retry.
        now = 140
        let gen1 = try #require(model.ownership.transportGeneration)
        model.handleConnectionLost(generation: gen1)
        #expect(model.isOffline)
        #expect(model.autoReconnectTask != nil)
        try await sleepStarted.wait()
        #expect(sleepDelays == [2.5])

        // Scene becomes inactive while retry timer is pending: cancels immediately, zero dials.
        model.isSceneActive = false
        releaseSleep.release(())
        await Task.yield()
        #expect(model.autoReconnectTask == nil)
        #expect(dialCount == 1)

        // New failure / loss while inactive never schedules an automatic retry or dials.
        model.handleConnectionLost(generation: gen1) // stale gen ignored
        model.scheduleAutoReconnect()
        #expect(model.autoReconnectTask == nil)
        await model.reconnect(automatically: true)
        #expect(dialCount == 1)

        // Foreground reactivation triggers an immediate dial without waiting for backoff sleep.
        model.isSceneActive = true
        await model.reconnect(automatically: true)
        #expect(dialCount == 2)
        #expect(model.phase == .connected(host: config.host, username: config.username))
    }

    @Test func repeatedReconnectFailuresBackOffAndResetOnlyAfterStableSuccess() async throws {
        let config = makeConfig()
        let model = AppModel(autoConnectOnLaunch: false)
        var now: TimeInterval = 0
        model.nowUptime = { now }
        model.reconnectJitterUnit = { 1.0 }

        var dialCount = 0
        var shouldFailDial = false
        model.customDialTransport = { _, reserved, _ in
            dialCount += 1
            if shouldFailDial {
                throw HerdrError.timeout("SSH")
            }
            return reserved
        }
        model.customCheckHerdr = { _, _ in "herdr 0.8.6" }

        var recordedDelays: [TimeInterval] = []
        var sleepGate = ExternallyReleasedWait<Void>()
        model.sleepSeconds = { seconds in
            recordedDelays.append(seconds)
            sleepGate.release(())
            // Fail sleep immediately in this test only when released via cancelReconnect;
            // otherwise wait briefly for the test loop to drive each step deterministically.
            try await Task.sleep(for: .milliseconds(5))
        }

        // Initial connect succeeds at t = 0.
        await model.connect(config: config)
        #expect(dialCount == 1)

        // Outage begins at t = 60 (stable connection -> step 0 = 2.5s), then dials fail.
        now = 60
        shouldFailDial = true
        model.sleepSeconds = { seconds in
            recordedDelays.append(seconds)
            // Keep sleep open indefinitely so the test drives each dial explicitly.
            try await Task.sleep(for: .seconds(600))
        }
        let gen1 = try #require(model.ownership.transportGeneration)
        model.handleConnectionLost(generation: gen1)
        try await waitUntilDelayCount(1, in: { recordedDelays.count })
        #expect(recordedDelays == [2.5])

        // Simulate repeated failed reconnect attempts (e.g., via foreground/timer ticks):
        var expectedDelayCount = 1
        for expectedDelay in [5.0, 10.0, 20.0, 40.0, 60.0, 60.0] {
            expectedDelayCount += 1
            await model.reconnect(automatically: true)
            try await waitUntilDelayCount(expectedDelayCount, in: { recordedDelays.count })
            #expect(recordedDelays.last == expectedDelay)
        }
        #expect(recordedDelays == [2.5, 5.0, 10.0, 20.0, 40.0, 60.0, 60.0])

        // Reconnect succeeds at t = 100, then drops quickly at t = 110 (< 30s): stays backed off at 60s.
        shouldFailDial = false
        now = 100
        await model.reconnect(automatically: true)
        #expect(model.phase == .connected(host: config.host, username: config.username))
        now = 110
        let genFlaky = try #require(model.ownership.transportGeneration)
        model.handleConnectionLost(generation: genFlaky)
        try await waitUntilDelayCount(8, in: { recordedDelays.count })
        #expect(recordedDelays.last == 60.0)

        // Reconnect succeeds at t = 200 and stays stable until t = 235 (>= 30s): resets to 2.5s.
        now = 200
        await model.reconnect(automatically: true)
        now = 235
        let genStable = try #require(model.ownership.transportGeneration)
        model.handleConnectionLost(generation: genStable)
        try await waitUntilDelayCount(9, in: { recordedDelays.count })
        #expect(recordedDelays.last == 2.5)
        model.cancelReconnect()
    }

    @Test func explicitManualRetryDialsImmediatelyEvenDuringLongOutageBackoff() async throws {
        let config = makeConfig()
        let model = AppModel(autoConnectOnLaunch: false)
        model.reconnectJitterUnit = { 1.0 }
        var dialCount = 0
        var shouldFail = true
        model.customDialTransport = { _, reserved, _ in
            dialCount += 1
            if shouldFail { throw HerdrError.timeout("SSH") }
            return reserved
        }
        model.customCheckHerdr = { _, _ in "herdr 0.8.6" }
        model.sleepSeconds = { _ in try await Task.sleep(for: .seconds(600)) }

        model.hasActiveSession = true
        model.activeConfig = config
        model.phase = .offline(host: config.host, username: config.username)

        // Push into outage backoff.
        await model.reconnect(automatically: true)
        await model.reconnect(automatically: true)
        #expect(dialCount == 2)
        #expect(model.lastScheduledAutoReconnectDelay == 10.0)
        #expect(model.autoReconnectTask != nil)

        // User taps Retry manually: cancels pending backoff sleep and dials immediately.
        shouldFail = false
        await model.reconnect(automatically: false)
        #expect(dialCount == 3)
        #expect(model.autoReconnectTask == nil)
        #expect(model.phase == .connected(host: config.host, username: config.username))
    }

    @Test func preNetworkEligibilityRecheckAbortsAutomaticDialIfSceneTurnsInactiveDuringSetup() async throws {
        let config = makeConfig()
        let model = AppModel(autoConnectOnLaunch: false)
        model.hasActiveSession = true
        model.activeConfig = config
        model.phase = .offline(host: config.host, username: config.username)

        var dialCount = 0
        model.customDialTransport = { _, reserved, _ in
            dialCount += 1
            return reserved
        }

        // Direct automatic dial while scene is inactive must not dial.
        model.isSceneActive = false
        await model.connect(config: config, isAutomatic: true)
        #expect(dialCount == 0)
        #expect(model.phase == .offline(host: config.host, username: config.username))
        #expect(model.reconnectBackoff.failureCount == 0)

        // Race: scheduled sleep wakes up right as scene turns inactive before dialing.
        model.isSceneActive = true
        let sleepFinished = ExternallyReleasedWait<Void>()
        model.sleepSeconds = { _ in
            model.isSceneActive = false
            sleepFinished.release(())
        }
        model.scheduleAutoReconnect()
        try await sleepFinished.wait()
        await Task.yield()
        #expect(dialCount == 0)
        #expect(model.autoReconnectTask == nil)
        #expect(model.reconnectBackoff.failureCount == 0)
    }

    @Test func hostKeyChallengeBlocksAutomaticReconnectUntilApprovedAndUserDisconnectResetsSession() async throws {
        let config = makeConfig()
        let model = AppModel(autoConnectOnLaunch: false)
        let challenge = SSHHostKeyChallenge(
            host: config.host,
            port: config.port,
            publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            previousPublicKey: nil
        )
        var dialCount = 0
        model.customDialTransport = { _, reserved, _ in
            dialCount += 1
            if dialCount == 1 {
                throw SSHHostKeyError.unknown(challenge)
            }
            return reserved
        }
        model.customCheckHerdr = { _, _ in "herdr 0.8.6" }
        model.sleepSeconds = { _ in try await Task.sleep(for: .seconds(600)) }

        model.hasActiveSession = true
        model.activeConfig = config
        model.phase = .offline(host: config.host, username: config.username)

        // First dial triggers host-key challenge: blocks all automatic reconnects.
        await model.reconnect(automatically: true)
        #expect(dialCount == 1)
        #expect(model.hostKeyVerificationBlocked)
        #expect(model.hostKeyChallenge == challenge)
        #expect(model.autoReconnectTask == nil)

        // Foreground reactivation / scheduled attempt cannot bypass host-key block.
        model.scheduleAutoReconnect()
        #expect(model.autoReconnectTask == nil)
        await model.reconnect(automatically: true)
        #expect(dialCount == 1)

        // User disconnect clears session, cancels tasks, resets backoff, and prevents auto-reconnect.
        await model.disconnect()
        #expect(!model.hasActiveSession)
        #expect(model.activeConfig == nil)
        #expect(model.phase == .disconnected)
        #expect(!model.hostKeyVerificationBlocked)
        #expect(model.reconnectBackoff.failureCount == 0)
        model.scheduleAutoReconnect()
        #expect(model.autoReconnectTask == nil)
        await model.reconnect(automatically: true)
        #expect(dialCount == 1)
    }

    private func waitUntilDelayCount(_ expected: Int, in count: () -> Int) async throws {
        for _ in 0..<200 {
            if count() >= expected { return }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
