import Foundation
import Testing
@testable import Herdcats

@Suite("Persistent Live shell framing")
struct PanePersistentShellTests {
    @Test func fragmentedUTF8AndDelimiterPreserveExactOutput() throws {
        let expected = "\u{1B}[32m漢字🐈\nsecond line\n"
        let marker = "HC_fixture"
        let wire = Data((expected + "\n" + marker + "\n").utf8)
        for split in 0..<wire.count {
            var frame = PaneShellResponseFrame(marker: marker)
            #expect(try frame.append(Data(wire.prefix(split))) == nil)
            #expect(try frame.append(Data(wire.dropFirst(split))) == expected)
        }
    }

    @Test func emptyAndMarkerLikeOutputDoNotCompleteEarly() throws {
        var empty = PaneShellResponseFrame(marker: "HC_end")
        #expect(try empty.append(Data("\nHC_end\n".utf8)) == "")
        var frame = PaneShellResponseFrame(marker: "HC_end")
        #expect(try frame.append(Data("HC_end\ntext HC_end\n".utf8)) == nil)
        #expect(try frame.append(Data("\nHC_end\n".utf8)) == "HC_end\ntext HC_end\n")
    }

    @Test func oversizedOrTrailingResponsesFailClosed() throws {
        var oversized = PaneShellResponseFrame(marker: "end", limit: 4)
        #expect(throws: HerdrError.self) {
            try oversized.append(Data(repeating: 65, count: 20))
        }
        var trailing = PaneShellResponseFrame(marker: "end")
        #expect(throws: HerdrError.self) {
            try trailing.append(Data("hello\nend\nunexpected".utf8))
        }
    }

    @Test func wrapperKeepsParentShellAndDetachesCommandInput() {
        let frame = PaneShellResponseFrame(marker: "HC_fixture")
        let command = frame.command(HerdrConnection.remoteCommand(
            HerdrConnection.paneSendTextArguments(paneId: "w1:p1", text: "hello\n'$(touch unexpected)'🐈")
        ))
        #expect(command.hasPrefix("sh -c '"))
        #expect(command.contains("</dev/null\nprintf"))
        #expect(command.hasSuffix("'HC_fixture'\n"))
    }

    @Test func successiveOwnersOnSamePaneHaveDifferentTokens() {
        let generation = ConnectionGeneration(rawValue: 1)
        let first = PaneLiveInputSession(paneId: "w1:p1", generation: generation)
        let second = PaneLiveInputSession(paneId: "w1:p1", generation: generation)
        #expect(first != second)
    }
}

private actor ShellTestWire {
    private(set) var commands: [String] = []
    private(set) var closeCount = 0
    func write(_ command: String) { commands.append(command) }
    func close() { closeCount += 1 }
    func marker(at index: Int) -> String {
        // Each generated command ends with printf '\n%s\n' 'HC_<UUID>'.
        String(commands[index].split(separator: "'").first { $0.hasPrefix("HC_") }!)
    }
}

@Suite("Persistent Live shell delivery")
struct PanePersistentShellDeliveryTests {
    @Test func requestsRemainOrderedUntilAcknowledgement() async throws {
        let wire = ShellTestWire()
        let shell = PanePersistentShell(writeCommand: { await wire.write($0) }, closeChannel: { await wire.close() })
        let first = Task { try await shell.execute("true") }
        try await waitForCommands(1, on: wire)
        let second = Task { try await shell.execute("true") }
        #expect(await wire.commands.count == 1)
        let marker1 = await wire.marker(at: 0)
        await shell.receive(Data("漢".utf8))
        await shell.receive(Data("字\n\(marker1)\n".utf8))
        #expect(try await first.value == "漢字")
        try await waitForCommands(2, on: wire)
        let marker2 = await wire.marker(at: 1)
        await shell.receive(Data("\n\(marker2)\n".utf8))
        #expect(try await second.value == "")
        await shell.close()
        #expect(await wire.closeCount == 1)
    }

    @Test func timeoutClosesChannelAndNeverReplays() async throws {
        let wire = ShellTestWire()
        let shell = PanePersistentShell(writeCommand: { await wire.write($0) }, closeChannel: { await wire.close() })
        do {
            _ = try await shell.execute("true", timeout: 0.01)
            Issue.record("Unacknowledged request should time out")
        } catch {
            #expect(error as? HerdrError == .timeout("Live shell"))
        }
        do {
            _ = try await shell.execute("true")
            Issue.record("Closed channel should reject later requests")
        } catch {
            #expect(error as? HerdrError == .notConnected)
        }
        #expect(await wire.commands.count == 1)
        await shell.close()
        #expect(await wire.closeCount == 1)
    }

    @Test func closeFailsOutstandingAndQueuedRequests() async throws {
        let wire = ShellTestWire()
        let shell = PanePersistentShell(writeCommand: { await wire.write($0) }, closeChannel: { await wire.close() })
        let first = Task { try await shell.execute("true") }
        try await waitForCommands(1, on: wire)
        let second = Task { try await shell.execute("true") }
        await shell.close()
        for task in [first, second] {
            do { _ = try await task.value; Issue.record("Closed channel completed a request") }
            catch { #expect(error as? HerdrError == .notConnected) }
        }
        #expect(await wire.commands.count == 1)
        #expect(await wire.closeCount == 1)
    }

    private func waitForCommands(_ count: Int, on wire: ShellTestWire) async throws {
        for _ in 0..<1_000 {
            if await wire.commands.count >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw HerdrError.timeout("test wire")
    }
}

private extension HerdrConnection {
    func installShellTestOwner(_ session: PaneLiveInputSession, input: PanePersistentShell, output: PanePersistentShell) {
        activeLiveSessions[session.paneId] = session
        liveShells[session.paneId] = PaneLiveShells(session: session, input: input, output: output)
    }

    func shellTestOwnerIs(_ session: PaneLiveInputSession) -> Bool {
        activeLiveSessions[session.paneId] == session && liveShells[session.paneId]?.session == session
    }
}

@Suite("Live shell ownership")
struct PaneLiveShellOwnershipTests {
    @Test func delayedOldViewCleanupCannotCloseNewOwner() async {
        let connection = HerdrConnection()
        let generation = ConnectionGeneration(rawValue: 1)
        let old = PaneLiveInputSession(paneId: "w1:p1", generation: generation)
        let current = PaneLiveInputSession(paneId: "w1:p1", generation: generation)
        let input = PanePersistentShell(writeCommand: { _ in }, closeChannel: {})
        let output = PanePersistentShell(writeCommand: { _ in }, closeChannel: {})
        await connection.installShellTestOwner(current, input: input, output: output)
        await connection.endPaneLiveInput(old)
        #expect(await connection.shellTestOwnerIs(current))
        #expect(await input.isOpen)
        #expect(await output.isOpen)
        await connection.endPaneLiveInput(current)
        #expect(await connection.shellTestOwnerIs(current) == false)
    }

    @Test func endedSessionCannotFallBackToLegacyDelivery() async {
        let connection = HerdrConnection()
        let session = PaneLiveInputSession(paneId: "w1:p1", generation: ConnectionGeneration(rawValue: 1))
        let input = PanePersistentShell(writeCommand: { _ in }, closeChannel: {})
        let output = PanePersistentShell(writeCommand: { _ in }, closeChannel: {})
        await connection.installShellTestOwner(session, input: input, output: output)
        await connection.endPaneLiveInput(session)
        do {
            _ = try await connection.sendThroughLiveShell("unused", session: session)
            Issue.record("Retired session must not select legacy delivery")
        } catch {
            #expect(error as? HerdrError == .notConnected)
        }
    }
}
