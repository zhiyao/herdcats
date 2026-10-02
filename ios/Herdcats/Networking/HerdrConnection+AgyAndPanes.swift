import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

extension HerdrConnection {
    func agentList() async throws -> [AgentEntry] {
        try await fetch(AgentListResult.self, args: "agent list").agents
    }

    /// Reads local provider quotas via `quota-axi` on the Herdr machine.
    /// Soft dependency: missing binary throws `.quotaAxiNotFound`.
    /// `provider` scopes the read to one quota-axi provider (card retry).
    func quotaReport(provider: String? = nil, timeout: TimeInterval = 30) async throws -> QuotaReport {
        try requireHostServices()
        let output = try await runQuotaAxi(timeout: timeout, provider: provider)
        var report = try QuotaReport.decode(output.json)
        report.cliVersion = output.version
        return report
    }

    /// A separate, short-lived PTY; closing it never closes the shared SSH client.
    func runAgyLogin(
        id: UUID,
        onOutput: @escaping @Sendable (String) async -> Void
    ) async throws {
        try requireHostServices()
        guard let client else { throw HerdrError.notConnected }
        guard agyLogin == nil else {
            throw HerdrError.invalidConfiguration("An Agy sign-in is already open. Close it and try again.")
        }
        let owned = generation
        defer { clearAgyLogin(id: id) }
        try await withTimeout(seconds: 600, label: "Agy sign-in") {
            try await client.withPTY(.init(
                wantReply: true, term: "xterm-256color",
                terminalCharacterWidth: 4096, terminalRowHeight: 40,
                terminalPixelWidth: 0, terminalPixelHeight: 0,
                terminalModes: .init([:])
            )) { inbound, outbound in
                try Task.checkCancellation()
                try await self.installAgyLogin(id: id, generation: owned, writer: outbound)
                do {
                    // No credential or user-supplied text is interpolated into a shell command.
                    try await outbound.write(ByteBuffer(string: Self.agyLoginRemoteCommand + "\n"))
                    var terminal = AgyTerminalResponder()
                    for try await output in inbound {
                        try Task.checkCancellation()
                        let buffer: ByteBuffer
                        switch output {
                        case .stdout(let value), .stderr(let value): buffer = value
                        }
                        let text = String(buffer: buffer)
                        try await self.recordAgyLoginOutput(text, id: id, generation: owned)
                        let replies = terminal.responses(to: text)
                        if !replies.isEmpty {
                            try await outbound.write(ByteBuffer(string: replies))
                        }
                        await onOutput(text)
                    }
                    await self.clearAgyLogin(id: id)
                } catch {
                    await self.clearAgyLogin(id: id)
                    throw error
                }
            }
        }
    }

    func installAgyLogin(id: UUID, generation expected: ConnectionGeneration, writer: TTYStdinWriter) throws {
        guard slot.matches(expected) else { throw HerdrError.notConnected }
        guard agyLogin == nil else { throw HerdrError.invalidConfiguration("An Agy sign-in is already open.") }
        agyLogin = AgyLoginSession(id: id, generation: expected, writer: writer)
        agyLoginTranscript = AgySignInTranscript(waitsForReadyMarker: true)
    }

    func recordAgyLoginOutput(_ text: String, id: UUID, generation expected: ConnectionGeneration) throws {
        guard slot.matches(expected), agyLogin?.id == id else { throw HerdrError.notConnected }
        agyLoginTranscript.append(text)
    }

    func clearAgyLogin(id: UUID) {
        guard agyLogin?.id == id else { return }
        agyLogin = nil
        agyLoginTranscript = AgySignInTranscript()
    }

    func sendAgyLoginInput(_ input: AgySignInInput, id: UUID) async throws {
        guard let session = agyLogin, session.id == id, slot.matches(session.generation) else {
            throw HerdrError.notConnected
        }
        switch input {
        case .code: break
        default:
            guard agyLoginTranscript.isChoosingLoginMethod else {
                throw HerdrError.invalidConfiguration("Agy is not waiting for a login choice.")
            }
        }
        let text = try input.terminalText(awaitingCode: agyLoginTranscript.awaitingCode)
        if case .code = input { agyLoginTranscript.markCodeSubmitted() }
        try await session.writer.write(ByteBuffer(string: text))
    }

    static var agyLoginRemoteCommand: String {
        let script = """
        stty -echo
        export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:/opt/homebrew/bin:/usr/local/bin:$PATH"
        cd "$HOME" || exit 1
        printf '\\n\(AgySignInTranscript.readyMarker)\\n'
        exec agy
        """
        return "exec /bin/sh -c \(shellSafeArgument(script))"
    }

    func tabList(workspaceId: String) async throws -> [TabEntry] {
        try await fetch(TabListResult.self, args: Self.tabListArguments(workspaceId: workspaceId)).tabs
    }

    /// Creates a tab with its own root pane and returns that pane's ID.
    func tabCreate(workspaceId: String, cwd: String?, label: String) async throws -> String {
        try await fetch(
            TabCreateResult.self,
            args: Self.tabCreateArguments(workspaceId: workspaceId, cwd: cwd, label: label)
        ).rootPane.paneId
    }

    static func tabCreateArguments(workspaceId: String, cwd: String?, label: String) -> String {
        var args = "tab create --workspace \(shellSafeArgument(workspaceId))"
        if let cwd, !cwd.isEmpty {
            args += " --cwd \(shellSafeArgument(cwd))"
        }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLabel.isEmpty {
            args += " --label \(shellSafeArgument(trimmedLabel))"
        }
        return args + " --no-focus"
    }

    /// Builds `tab list` arguments. Workspace IDs come from remote JSON and
    /// must be shell-escaped before interpolation (including when routed via
    /// `--machine` to a gateway).
    static func tabListArguments(workspaceId: String) -> String {
        "tab list --workspace \(shellSafeArgument(workspaceId))"
    }

    func paneList(workspaceId: String) async throws -> [PaneEntry] {
        try await fetch(PaneListResult.self, args: Self.paneListArguments(workspaceId: workspaceId)).panes
    }

    /// Builds `pane list` arguments. Workspace IDs come from remote JSON and
    /// must be shell-escaped before interpolation (including when routed via
    /// `--machine` to a gateway).
    static func paneListArguments(workspaceId: String) -> String {
        "pane list --workspace \(shellSafeArgument(workspaceId))"
    }

    /// Renames a pane. If `name` is empty or only whitespace, clears any custom label.
    @discardableResult
    func paneRename(paneId: String, name: String) async throws -> PaneEntry {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let args = trimmed.isEmpty
            ? "pane rename \(Self.shellSafeArgument(paneId)) --clear"
            : "pane rename \(Self.shellSafeArgument(paneId)) \(Self.shellSafeArgument(trimmed))"
        return try await fetch(PaneInfoResult.self, args: args).pane
    }

    /// Splits `paneId` and returns the newly created sibling pane.
    @discardableResult
    func paneSplit(
        paneId: String,
        direction: String = "right",
        cwd: String? = nil,
        focus: Bool = false
    ) async throws -> PaneEntry {
        var args = "pane split \(Self.shellSafeArgument(paneId)) --direction \(Self.shellSafeArgument(direction))"
        if let cwd, !cwd.isEmpty {
            args += " --cwd \(Self.shellSafeArgument(cwd))"
        }
        args += focus ? " --focus" : " --no-focus"
        return try await fetch(PaneInfoResult.self, args: args).pane
    }

    /// Marks a Done agent as seen so Herdr clears it to Idle. Prefers
    /// `agent focus` (pane ID is a valid target); falls back to `tab focus`
    /// when the pane has no recognized agent.
    func markAgentSeen(paneId: String, tabId: String, hasAgent: Bool) async throws {
        _ = try await runHerdr(
            Self.markAgentSeenArguments(paneId: paneId, tabId: tabId, hasAgent: hasAgent),
            allowEmptyOutput: true
        )
    }

    static func markAgentSeenArguments(paneId: String, tabId: String, hasAgent: Bool) -> String {
        if hasAgent {
            return "agent focus \(shellSafeArgument(paneId))"
        }
        return "tab focus \(shellSafeArgument(tabId))"
    }

    /// Closes / kills a pane.
    func paneClose(paneId: String) async throws {
        _ = try await runHerdr("pane close \(Self.shellSafeArgument(paneId))", allowEmptyOutput: true)
    }

    /// Reads a pane's terminal output, preferring ANSI so colors survive.
    /// Empty output is legitimate here (a freshly cleared pane), so it is
    /// allowed through instead of being treated as a protocol error.
    func paneReadText(paneId: String, lines: Int = 400) async throws -> String {
        try await runHerdr(
            "pane read \(Self.shellSafeArgument(paneId)) --source recent-unwrapped --lines \(lines) --format ansi",
            allowEmptyOutput: true
        )
    }

    /// Types `text` into the pane followed by Enter (`pane run`).
    func paneSendText(paneId: String, text: String) async throws {
        try await paneInput.run(paneId: paneId) {
            try await self.paneSendTextUnlocked(paneId: paneId, text: text)
        }
    }

    func paneSendTextUnlocked(paneId: String, text: String) async throws {
        try await runHerdr(
            "pane run \(Self.shellSafeArgument(paneId)) \(Self.shellSafeArgument(text))",
            timeout: 15,
            allowEmptyOutput: true
        )
    }

    /// Captures a Live input session token for `paneId` on the current
    /// connection generation.
    ///
    /// Acquires the exclusive pane-input lane as a no-op barrier first so Live
    /// activation waits behind any in-flight Compose mutation (submit, escape).
    /// Generation is checked before the wait and again after the lane is held.
    /// Callers must still perform a successful pane read after this returns before
    /// enabling the Live keyboard.
    func beginPaneLiveInput(paneId: String) async throws -> PaneLiveInputSession {
        let trimmed = paneId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HerdrError.invalidConfiguration("Pane id is required for live input.")
        }
        // Capture before waiting so a generation bump during an in-flight
        // Compose mutation rejects this begin rather than minting a stale token.
        let owned = generation
        try requireGeneration(owned)
        return try await paneInput.run(paneId: trimmed) {
            try await self.paneLiveBeginBarrierUnlocked(paneId: trimmed, owned: owned)
        }
    }

    func paneLiveBeginBarrierUnlocked(
        paneId: String,
        owned: ConnectionGeneration
    ) async throws -> PaneLiveInputSession {
        try requireGeneration(owned)
        // No remote command — lane acquisition itself serializes behind Compose.
        try requireGeneration(owned)
        return PaneLiveInputSession(paneId: paneId, generation: owned)
    }

    /// Live-only `pane send-text` through the exclusive pane lane. Checks the
    /// session generation before and after the command. Never logs `text`.
    func sendPaneLiveText(_ text: String, session: PaneLiveInputSession) async throws {
        try requireGeneration(session.generation)
        try await paneInput.run(paneId: session.paneId) {
            try await self.paneLiveTypeTextUnlocked(text: text, session: session)
        }
    }

    /// Live-only `pane send-keys` through the exclusive pane lane. Checks the
    /// session generation before and after the command. Never logs `keys`.
    func sendPaneLiveKeys(_ keys: [String], session: PaneLiveInputSession) async throws {
        try requireGeneration(session.generation)
        try await paneInput.run(paneId: session.paneId) {
            try await self.paneLiveSendKeysUnlocked(keys, session: session)
        }
    }

    func paneLiveTypeTextUnlocked(text: String, session: PaneLiveInputSession) async throws {
        try requireGeneration(session.generation)
        try await paneTypeTextUnlocked(
            paneId: session.paneId, text: text, owned: session.generation
        )
        try requireGeneration(session.generation)
    }

    func paneLiveSendKeysUnlocked(_ keys: [String], session: PaneLiveInputSession) async throws {
        try requireGeneration(session.generation)
        try await paneSendKeysUnlocked(
            paneId: session.paneId, keys, owned: session.generation
        )
        try requireGeneration(session.generation)
    }
}
