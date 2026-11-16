@testable import Citadel
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing
@testable import Herdcats

@Suite("Pane timeline power policy and lifecycle")
@MainActor
struct PaneTimelinePowerPolicyTests {
    @Test func policyEliminatesHiddenTerminalWorkWhileTimelineIsVisible() {
        #expect(!PaneRefreshPolicy.shouldRunTerminalInitialRead(showsTimeline: true, isSceneActive: true, isOffline: false))
        #expect(!PaneRefreshPolicy.shouldPollTerminal(showsTimeline: true, autoRefreshEnabled: true, isSceneActive: true, isOffline: false))
        #expect(!PaneRefreshPolicy.shouldPrepareLiveSession(showsTimeline: true, isFocused: true, isSceneActive: true, isOffline: false))
        #expect(!PaneRefreshPolicy.shouldParseTerminalOutput(showsTimeline: true))

        #expect(PaneRefreshPolicy.shouldRunTerminalInitialRead(showsTimeline: false, isSceneActive: true, isOffline: false))
        #expect(PaneRefreshPolicy.shouldPollTerminal(showsTimeline: false, autoRefreshEnabled: true, isSceneActive: true, isOffline: false))
        #expect(!PaneRefreshPolicy.shouldPollTerminal(showsTimeline: false, autoRefreshEnabled: false, isSceneActive: true, isOffline: false))
        #expect(!PaneRefreshPolicy.shouldPollTerminal(showsTimeline: false, autoRefreshEnabled: true, isSceneActive: false, isOffline: false))
        #expect(!PaneRefreshPolicy.shouldPollTerminal(showsTimeline: false, autoRefreshEnabled: true, isSceneActive: true, isOffline: true))
        #expect(PaneRefreshPolicy.shouldPrepareLiveSession(showsTimeline: false, isFocused: true, isSceneActive: true, isOffline: false))
        #expect(!PaneRefreshPolicy.shouldPrepareLiveSession(showsTimeline: false, isFocused: false, isSceneActive: true, isOffline: false))
        #expect(PaneRefreshPolicy.shouldParseTerminalOutput(showsTimeline: false))
    }

    @Test func hiddenTimelineNeverReadsParsesOrSleepsInTerminalPollingRunner() async {
        var reads = 0
        var sleeps: [TimeInterval] = []
        let key = TerminalRefreshTaskKey(
            paneId: "w1:p1",
            showsTimeline: true,
            isSceneActive: true,
            isOffline: false,
            autoRefreshEnabled: true
        )
        let runner = PaneTerminalPollingRunner(
            key: key,
            currentKey: { key },
            needsInitialRead: true,
            markInitialReadDone: {},
            reloadAndParse: { reads += 1 },
            sleep: { interval in sleeps.append(interval) }
        )
        await runner.run()
        #expect(reads == 0)
        #expect(sleeps.isEmpty)
    }

    @Test func hiddenTimelineNeverAcquiresLiveSessionOrShells() async {
        var begins = 0
        var reloads = 0
        var installs = 0
        var sleeps: [TimeInterval] = []
        let runner = PaneLiveSessionRunner(
            targetPaneId: "w1:p1",
            isEligible: {
                PaneRefreshPolicy.shouldPrepareLiveSession(
                    showsTimeline: true,
                    isFocused: true,
                    isSceneActive: true,
                    isOffline: false
                )
            },
            isEnabled: { false },
            needsResyncOrMissingSession: { true },
            retireCurrentSession: {},
            beginLiveInput: { _ in
                begins += 1
                return PaneLiveInputSession(paneId: "w1:p1", generation: ConnectionGeneration(rawValue: 1))
            },
            endLiveInput: { _ in },
            reloadPostBarrier: {
                reloads += 1
                return nil
            },
            installSession: { _ in installs += 1 },
            noteTimeout: {},
            sleep: { interval in sleeps.append(interval) }
        )
        await runner.run()
        #expect(begins == 0)
        #expect(reloads == 0)
        #expect(installs == 0)
        #expect(sleeps.isEmpty)
    }

    @Test func modeSwitchingStartsFreshTerminalWorkOnEntryAndRetiresShellsOnTimelineReturn() async throws {
        let pane = PaneEntry(
            paneId: "w1:p1", tabId: "t1", workspaceId: "w1",
            label: nil, agent: "pi", agentStatus: "idle", cwd: "/tmp",
            terminalTitle: "Pi", terminalTitleStripped: "Pi", focused: true, revision: nil
        )
        let scope = ConnectionIdentity(host: "mac.local", port: 22, username: "tester")
        let state = PaneSessionState(pane: pane, connectionScope: scope)
        let palette = TerminalPalette(palette: AppThemePreferences.shared.dark, dark: true)

        var showsTimeline = true
        var loadedPaneID: String?
        var remoteReads = 0
        var parseCount = 0

        func currentTerminalKey() -> TerminalRefreshTaskKey {
            TerminalRefreshTaskKey(
                paneId: pane.paneId,
                showsTimeline: showsTimeline,
                isSceneActive: true,
                isOffline: false,
                autoRefreshEnabled: false
            )
        }

        // Initial Timeline visit: zero terminal reads or parses.
        await PaneTerminalPollingRunner(
            key: currentTerminalKey(),
            currentKey: currentTerminalKey,
            needsInitialRead: loadedPaneID != pane.paneId,
            markInitialReadDone: { loadedPaneID = pane.paneId },
            reloadAndParse: {
                remoteReads += 1
                await state.reload { "\u{1B}[32mvisit-\(remoteReads)\u{1B}[0m" }
                if PaneRefreshPolicy.shouldParseTerminalOutput(showsTimeline: showsTimeline) {
                    parseCount += 1
                    state.updateParsedOutput(palette: palette)
                }
            },
            sleep: { _ in }
        ).run()
        #expect(remoteReads == 0)
        #expect(parseCount == 0)
        #expect(state.outputRevision == 0)

        // Switch Timeline -> Terminal: loads fresh snapshot and parses ANSI once.
        showsTimeline = false
        loadedPaneID = nil
        await PaneTerminalPollingRunner(
            key: currentTerminalKey(),
            currentKey: currentTerminalKey,
            needsInitialRead: loadedPaneID != pane.paneId,
            markInitialReadDone: { loadedPaneID = pane.paneId },
            reloadAndParse: {
                remoteReads += 1
                await state.reload { "\u{1B}[32mvisit-\(remoteReads)\u{1B}[0m" }
                if PaneRefreshPolicy.shouldParseTerminalOutput(showsTimeline: showsTimeline) {
                    parseCount += 1
                    state.updateParsedOutput(palette: palette)
                }
            },
            sleep: { _ in }
        ).run()
        #expect(remoteReads == 1)
        #expect(parseCount == 1)
        #expect(state.output == "\u{1B}[32mvisit-1\u{1B}[0m")
        #expect(state.outputRevision == 1)

        // Live session installs and opens shells in Terminal mode, then retires on Timeline return.
        let connection = HerdrConnection()
        let generation = ConnectionGeneration(rawValue: 1)
        let inputWire = ModeSwitchShellWire()
        let outputWire = ModeSwitchShellWire()
        var activeSession: PaneLiveInputSession?

        let liveRunner = PaneLiveSessionRunner(
            targetPaneId: pane.paneId,
            isEligible: {
                PaneRefreshPolicy.shouldPrepareLiveSession(
                    showsTimeline: showsTimeline,
                    isFocused: true,
                    isSceneActive: true,
                    isOffline: false
                )
            },
            isEnabled: { activeSession != nil },
            needsResyncOrMissingSession: { activeSession == nil },
            retireCurrentSession: { PaneLiveSessionTeardown.retire(&activeSession, connection: connection) },
            beginLiveInput: { paneId in
                let token = PaneLiveInputSession(paneId: paneId, generation: generation)
                let input = PanePersistentShell(writeCommand: { _ in }, closeChannel: { await inputWire.close() })
                let output = PanePersistentShell(writeCommand: { _ in }, closeChannel: { await outputWire.close() })
                await connection.installTestShells(token, input: input, output: output)
                return token
            },
            endLiveInput: { await connection.endPaneLiveInput($0) },
            reloadPostBarrier: {
                remoteReads += 1
                await state.reload { "\u{1B}[32mvisit-\(remoteReads)\u{1B}[0m" }
                if PaneRefreshPolicy.shouldParseTerminalOutput(showsTimeline: showsTimeline) {
                    parseCount += 1
                    state.updateParsedOutput(palette: palette)
                }
                return state.errorMessage
            },
            installSession: { activeSession = $0 },
            noteTimeout: {},
            sleep: { _ in }
        )
        await liveRunner.run()
        #expect(activeSession != nil)
        #expect(remoteReads == 2)
        #expect(parseCount == 2)

        // Switch Terminal -> Timeline: abandons Live session and closes both shells.
        showsTimeline = true
        loadedPaneID = nil
        PaneLiveSessionTeardown.retire(&activeSession, connection: connection)
        #expect(activeSession == nil)
        for _ in 0..<1_000 {
            if await inputWire.closeCount == 1, await outputWire.closeCount == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await inputWire.closeCount == 1)
        #expect(await outputWire.closeCount == 1)

        // Switch Timeline -> Terminal again: loads another fresh snapshot even with auto-refresh off.
        showsTimeline = false
        await PaneTerminalPollingRunner(
            key: currentTerminalKey(),
            currentKey: currentTerminalKey,
            needsInitialRead: loadedPaneID != pane.paneId,
            markInitialReadDone: { loadedPaneID = pane.paneId },
            reloadAndParse: {
                remoteReads += 1
                await state.reload { "\u{1B}[32mvisit-\(remoteReads)\u{1B}[0m" }
                if PaneRefreshPolicy.shouldParseTerminalOutput(showsTimeline: showsTimeline) {
                    parseCount += 1
                    state.updateParsedOutput(palette: palette)
                }
            },
            sleep: { _ in }
        ).run()
        #expect(remoteReads == 3)
        #expect(parseCount == 3)
        #expect(state.output == "\u{1B}[32mvisit-3\u{1B}[0m")
    }

    @Test func cancellationOrTimelineSwitchMidBeginOrReadRetiresTokenWithoutInstalling() async throws {
        for stage in ["duringBegin", "duringRead", "taskCancelled"] {
            var showsTimeline = false
            let enteredBegin = ExternallyReleasedWait<Void>()
            let releaseBegin = ExternallyReleasedWait<Void>()
            let enteredRead = ExternallyReleasedWait<Void>()
            let releaseRead = ExternallyReleasedWait<Void>()
            var installed: PaneLiveInputSession?
            var endedTokens: [PaneLiveInputSession] = []
            var readCount = 0

            let runner = PaneLiveSessionRunner(
                targetPaneId: "w1:p1",
                isEligible: { !showsTimeline },
                isEnabled: { installed != nil },
                needsResyncOrMissingSession: { installed == nil },
                retireCurrentSession: {},
                beginLiveInput: { paneId in
                    enteredBegin.release(())
                    _ = try await releaseBegin.wait()
                    return PaneLiveInputSession(paneId: paneId, generation: ConnectionGeneration(rawValue: 1))
                },
                endLiveInput: { endedTokens.append($0) },
                reloadPostBarrier: {
                    readCount += 1
                    enteredRead.release(())
                    _ = try? await releaseRead.wait()
                    return nil
                },
                installSession: { installed = $0 },
                noteTimeout: {},
                sleep: { _ in }
            )

            let task = Task { @MainActor in
                await runner.acquireOnce()
            }
            try await enteredBegin.wait()

            if stage == "duringBegin" {
                showsTimeline = true
                releaseBegin.release(())
                releaseRead.release(())
            } else if stage == "duringRead" {
                releaseBegin.release(())
                try await enteredRead.wait()
                showsTimeline = true
                releaseRead.release(())
            } else {
                releaseBegin.release(())
                try await enteredRead.wait()
                task.cancel()
                releaseRead.release(())
            }

            await task.value
            #expect(installed == nil, "Stage: \(stage)")
            #expect(endedTokens.count == 1, "Stage: \(stage)")
            if stage == "duringBegin" {
                #expect(readCount == 0)
            } else {
                #expect(readCount == 1)
            }
        }
    }

    @Test func terminalPollingExitsImmediatelyWhenCancelledDuringFiveSecondSleep() async throws {
        var showsTimeline = false
        var reads = 0
        let sleeping = ExternallyReleasedWait<Void>()
        let sleepGate = ExternallyReleasedWait<Void>()

        func key() -> TerminalRefreshTaskKey {
            TerminalRefreshTaskKey(
                paneId: "w1:p1",
                showsTimeline: showsTimeline,
                isSceneActive: true,
                isOffline: false,
                autoRefreshEnabled: true
            )
        }

        let task = Task { @MainActor in
            await PaneTerminalPollingRunner(
                key: key(),
                currentKey: key,
                needsInitialRead: true,
                markInitialReadDone: {},
                reloadAndParse: { reads += 1 },
                sleep: { _ in
                    sleeping.release(())
                    _ = try await sleepGate.wait()
                }
            ).run()
        }

        try await sleeping.wait()
        #expect(reads == 1)
        showsTimeline = true
        sleepGate.release(())
        await task.value
        #expect(reads == 1)
    }

    @Test func liveAcquisitionWaitsBehindComposeMutationForFreshPostInputReadBarrier() async throws {
        let pane = PaneEntry(
            paneId: "w1:p1", tabId: "t1", workspaceId: "w1",
            label: nil, agent: nil, agentStatus: "idle", cwd: "/tmp",
            terminalTitle: "Shell", terminalTitleStripped: "Shell", focused: true, revision: nil
        )
        let scope = ConnectionIdentity(host: "mac.local", port: 22, username: "tester")
        let session = PaneSessionState(pane: pane, connectionScope: scope)
        let coordinator = PaneInputCoordinator()
        let composeEntered = ExternallyReleasedWait<Void>()
        let releaseCompose = ExternallyReleasedWait<Void>()
        var events: [String] = []
        var installed: PaneLiveInputSession?

        // Pre-barrier read produces stale pre-mutation output.
        await session.reload {
            events.append("pre-barrier-read")
            return "before-mutation"
        }
        #expect(session.output == "before-mutation")

        // Compose mutation holds the exclusive pane input lane.
        let composeTask = Task {
            try await coordinator.run(paneId: pane.paneId) {
                events.append("compose-start")
                composeEntered.release(())
                _ = try await releaseCompose.wait()
                events.append("compose-finish")
            }
        }
        try await composeEntered.wait()

        // Live acquisition begins while Compose is still in flight; its barrier
        // must wait until Compose finishes before reading fresh output.
        let liveTask = Task { @MainActor in
            await PaneLiveSessionRunner(
                targetPaneId: pane.paneId,
                isEligible: { true },
                isEnabled: { installed != nil },
                needsResyncOrMissingSession: { installed == nil },
                retireCurrentSession: {},
                beginLiveInput: { paneId in
                    try await coordinator.run(paneId: paneId) {
                        events.append("barrier-acquired")
                        return PaneLiveInputSession(paneId: paneId, generation: ConnectionGeneration(rawValue: 1))
                    }
                },
                endLiveInput: { _ in },
                reloadPostBarrier: {
                    await session.reload {
                        events.append("post-barrier-read")
                        return "after-mutation"
                    }
                    return session.errorMessage
                },
                installSession: {
                    events.append("session-installed")
                    installed = $0
                },
                noteTimeout: {},
                sleep: { _ in }
            ).acquireOnce()
        }

        // Give the live task a moment to queue on the input coordinator behind Compose.
        try await Task.sleep(for: .milliseconds(20))
        #expect(installed == nil)
        #expect(!events.contains("post-barrier-read"))

        releaseCompose.release(())
        try await composeTask.value
        await liveTask.value

        #expect(installed != nil)
        #expect(session.output == "after-mutation")
        #expect(events == [
            "pre-barrier-read",
            "compose-start",
            "compose-finish",
            "barrier-acquired",
            "post-barrier-read",
            "session-installed"
        ])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func leavingTerminalDuringComposeRetiresConnectedAcquisition(background: Bool) async throws {
        try await withConnectedLiveInputFixture { connection, shell in
            var showsTimeline = false
            var isSceneActive = true
            var installed: PaneLiveInputSession?
            var prepared: PaneLiveInputSession?
            var reads = 0
            let enteredCompose = ExternallyReleasedWait<Void>()
            let releaseCompose = ExternallyReleasedWait<Void>()
            defer {
                releaseCompose.release(())
                shell.release.release(())
            }
            let compose = Task {
                try await connection.paneInput.run(paneId: "w1:p1") {
                    enteredCompose.release(())
                    try await releaseCompose.wait()
                }
            }
            try await enteredCompose.wait()

            let acquisition = Task { @MainActor in
                await PaneLiveSessionRunner(
                    targetPaneId: "w1:p1",
                    isEligible: {
                        PaneRefreshPolicy.shouldPrepareLiveSession(
                            showsTimeline: showsTimeline, isFocused: true,
                            isSceneActive: isSceneActive, isOffline: false
                        )
                    },
                    isEnabled: { installed != nil },
                    needsResyncOrMissingSession: { true },
                    retireCurrentSession: {},
                    beginLiveInput: { paneId in
                        let token = try await connection.beginPaneLiveInput(paneId: paneId)
                        prepared = token
                        return token
                    },
                    endLiveInput: { await connection.endPaneLiveInput($0) },
                    reloadPostBarrier: { reads += 1; return nil },
                    installSession: { installed = $0 },
                    noteTimeout: {},
                    sleep: { _ in }
                ).acquireOnce()
            }
            for _ in 0..<1_000 {
                if await connection.paneInput.queuedCount(paneId: "w1:p1") == 1 { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let queued = await connection.paneInput.queuedCount(paneId: "w1:p1")
            // Change eligibility at the real input-lane boundary, without
            // cancelling the task: the late token must still be retired.
            showsTimeline = !background
            isSceneActive = !background
            releaseCompose.release(())
            shell.release.release(())
            try await compose.value
            await acquisition.value

            #expect(queued == 1)
            try #require(prepared != nil, "Must reach the connected acquisition path")
            #expect(installed == nil)
            #expect(reads == 0)
            #expect(await connection.hasActiveLiveSession(paneId: "w1:p1") == false)
            // A stale token cannot deliver input after the mode/lifecycle change.
            do {
                try await connection.sendPaneLiveText("must-not-replay", session: try #require(prepared))
                Issue.record("Retired Live input must reject delivery")
            } catch {
                #expect(error as? HerdrError == .notConnected)
            }
        }
    }

    @Test func cancelledBeginPaneLiveInputDoesNotLeaveActiveSessionInstalled() async throws {
        try await withConnectedLiveInputFixture { connection, shell in
            let firstEntered = ExternallyReleasedWait<Void>()
            let releaseFirst = ExternallyReleasedWait<Void>()
            let blocker = Task {
                try await connection.paneInput.run(paneId: "w1:p1") {
                    firstEntered.release(())
                    _ = try await releaseFirst.wait()
                }
            }
            try await firstEntered.wait()

            let cancelledBegin = Task {
                try await connection.beginPaneLiveInput(paneId: "w1:p1")
            }
            for _ in 0..<1_000 {
                if await connection.paneInput.queuedCount(paneId: "w1:p1") == 1 { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let queued = await connection.paneInput.queuedCount(paneId: "w1:p1")
            cancelledBegin.cancel()
            releaseFirst.release(())
            try await blocker.value

            do {
                _ = try await cancelledBegin.value
                Issue.record("Cancelled beginPaneLiveInput should throw")
            } catch {
                #expect(error is CancellationError)
            }
            #expect(queued == 1)
            #expect(await connection.hasActiveLiveSession(paneId: "w1:p1") == false)

            shell.release.release(())
            let session = try await connection.beginPaneLiveInput(paneId: "w1:p1")
            #expect(await connection.hasActiveLiveSession(paneId: "w1:p1"))
            await connection.endPaneLiveInput(session)
            #expect(await connection.hasActiveLiveSession(paneId: "w1:p1") == false)
        }
    }

    @Test func cancellationDuringShellSetupRetiresInstalledLiveSession() async throws {
        try await withConnectedLiveInputFixture { connection, shell in
            let begin = Task {
                try await connection.beginPaneLiveInput(paneId: "w1:p1")
            }
            try await shell.entered.wait()
            #expect(await connection.hasActiveLiveSession(paneId: "w1:p1"))
            begin.cancel()
            shell.release.release(())
            do {
                _ = try await begin.value
                Issue.record("Cancelled shell setup should throw")
            } catch {
                #expect(error is CancellationError)
            }
            #expect(await connection.hasActiveLiveSession(paneId: "w1:p1") == false)
        }
    }
}

private actor ModeSwitchShellWire {
    private(set) var closeCount = 0
    func close() { closeCount += 1 }
}

private extension HerdrConnection {
    func installTestShells(
        _ session: PaneLiveInputSession,
        input: PanePersistentShell,
        output: PanePersistentShell
    ) {
        activeLiveSessions[session.paneId] = session
        liveShells[session.paneId] = PaneLiveShells(session: session, input: input, output: output)
    }

    func hasActiveLiveSession(paneId: String) -> Bool {
        activeLiveSessions[paneId] != nil
    }
}

private struct LiveInputFixtureAuthentication: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [.password]

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        responsePromise.succeed(.success)
    }
}

@MainActor
private func withConnectedLiveInputFixture(
    _ operation: (HerdrConnection, LiveInputFixtureShell) async throws -> Void
) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = try await SSHServer.host(
        host: "127.0.0.1", port: 0,
        hostKeys: [.init(ed25519Key: Curve25519.Signing.PrivateKey())],
        authenticationDelegate: LiveInputFixtureAuthentication(), group: group
    )
    let shell = LiveInputFixtureShell()
    server.enableExec(withDelegate: shell)
    var ssh: SSHClient?
    do {
        let port = try #require(server.channel.localAddress?.port)
        let settings = SSHClientSettings(
            host: "127.0.0.1", port: port,
            authenticationMethod: { .passwordBased(username: "fixture", password: "fixture") },
            hostKeyValidator: .acceptAnything()
        )
        let client = try await SSHClient.connect(to: settings)
        ssh = client
        let connection = HerdrConnection()
        await connection.installLiveInputFixture(client)
        try await operation(connection, shell)
    } catch {
        try? await ssh?.close()
        try? await server.close()
        try? await group.shutdownGracefully()
        throw error
    }
    try await ssh?.close()
    try await server.close()
    try await group.shutdownGracefully()
}

private extension HerdrConnection {
    func installLiveInputFixture(_ client: SSHClient) {
        let reserved = slot.beginReplace().attempt
        _ = slot.install(client, expected: reserved)
    }
}

private final class LiveInputFixtureShell: ExecDelegate, Sendable {
    let entered = ExternallyReleasedWait<Void>()
    let release = ExternallyReleasedWait<Void>()

    func start(command: String, outputHandler: ExecOutputHandler) async throws -> ExecCommandContext {
        entered.release(())
        try await release.wait()
        outputHandler.succeed(exitCode: 1)
        return LiveInputFixtureCommand()
    }

    func setEnvironmentValue(_ value: String, forKey key: String) async throws {}
}

private struct LiveInputFixtureCommand: ExecCommandContext {
    func terminate() async throws {}
}
