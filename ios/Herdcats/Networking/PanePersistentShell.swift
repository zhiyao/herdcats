import Foundation
import Citadel
import NIOCore

/// One request's byte framing. Decode only after completion so SSH chunk
/// boundaries cannot corrupt multibyte input or ANSI output.
struct PaneShellResponseFrame {
    private var bytes = Data()
    let marker: String
    let limit: Int

    init(marker: String = "HC_\(UUID().uuidString)", limit: Int = 8 * 1024 * 1024) {
        self.marker = marker
        self.limit = limit
    }

    var delimiter: Data { Data("\n\(marker)\n".utf8) }

    mutating func append(_ chunk: Data) throws -> String? {
        bytes.append(chunk)
        guard bytes.count <= limit + delimiter.count else {
            throw HerdrError.unexpectedResponse("Live response exceeded its size limit.")
        }
        guard let range = bytes.range(of: delimiter) else { return nil }
        guard range.upperBound == bytes.endIndex else {
            throw HerdrError.unexpectedResponse("Unexpected data after Live response.")
        }
        return String(decoding: bytes[..<range.lowerBound], as: UTF8.self)
    }

    /// Run in a child shell with stdin detached: a command must never consume
    /// subsequent requests from the persistent shell's input stream.
    func command(_ command: String) -> String {
        "\(command.hasPrefix("exec ") ? String(command.dropFirst(5)) : command) </dev/null\nprintf '\\n%s\\n' '\(marker)'\n"
    }
}

/// A non-PTY POSIX shell over one SSH exec channel. No Python, socket relay,
/// installed helper, or host-side Herdr changes. Each request still invokes
/// the stock CLI. Input and output use separate instances to keep reads from
/// holding up keystrokes. Never retry a request after writing it.
actor PanePersistentShell {
    private let lane = PaneInputCoordinator()
    private var writeCommand: (@Sendable (String) async throws -> Void)?
    private var closeChannel: (@Sendable () async -> Void)?
    private var task: Task<Void, Never>?
    private var opening: CheckedContinuation<Void, Error>?
    private var response: CheckedContinuation<String, Error>?
    private var frame: PaneShellResponseFrame?
    private var timeoutTask: Task<Void, Never>?
    private var closed = false
    var isOpen: Bool { !closed && writeCommand != nil }

    init() {}

    /// Transport seam for deterministic framing, timeout, and ordering tests.
    init(
        writeCommand: @escaping @Sendable (String) async throws -> Void,
        closeChannel: @escaping @Sendable () async -> Void
    ) {
        self.writeCommand = writeCommand
        self.closeChannel = closeChannel
    }

    func open(client: SSHClient) async throws {
        try await withCheckedThrowingContinuation { continuation in
            opening = continuation
            armTimeout(seconds: 5)
            task = Task {
                do {
                    try await client.withExec("exec /bin/sh") { inbound, outbound in
                        await self.attach(outbound)
                        for try await output in inbound {
                            switch output {
                            case let .stdout(buffer):
                                await self.receive(Data(buffer.readableBytesView))
                            case .stderr:
                                // Command stderr is merged by remoteCommand; never log pane content.
                                break
                            }
                        }
                    }
                } catch {
                    await self.stop(error: error)
                    return
                }
                await self.stop(error: HerdrError.notConnected)
            }
        }
        // Verify stdin/stdout work before enabling input or selecting fallback.
        _ = try await execute("true", timeout: 5)
    }

    private func attach(_ writer: TTYStdinWriter) async {
        guard !closed else {
            try? await writer.close()
            return
        }
        writeCommand = { command in try await writer.write(ByteBuffer(string: command)) }
        closeChannel = { try? await writer.close() }
        timeoutTask?.cancel()
        opening?.resume()
        opening = nil
    }

    func execute(_ command: String, timeout: TimeInterval = 20) async throws -> String {
        try await lane.run(paneId: "shell") {
            try await self.perform(command, timeout: timeout)
        }
    }

    private func perform(_ command: String, timeout: TimeInterval) async throws -> String {
        guard !closed, let writeCommand else { throw HerdrError.notConnected }
        let nextFrame = PaneShellResponseFrame()
        return try await withCheckedThrowingContinuation { continuation in
            frame = nextFrame
            response = continuation
            armTimeout(seconds: timeout)
            Task {
                do {
                    try await writeCommand(nextFrame.command(command))
                } catch {
                    await self.stop(error: error)
                }
            }
        }
    }

    func receive(_ bytes: Data) async {
        guard !closed, var frame else {
            if !closed { await stop(error: HerdrError.unexpectedResponse("Unframed Live response.")) }
            return
        }
        do {
            if let output = try frame.append(bytes) {
                self.frame = nil
                timeoutTask?.cancel()
                let continuation = response
                response = nil
                continuation?.resume(returning: output)
            } else {
                self.frame = frame
            }
        } catch {
            await stop(error: error)
        }
    }

    private func armTimeout(seconds: TimeInterval) {
        timeoutTask?.cancel()
        timeoutTask = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            await self.stop(error: HerdrError.timeout("Live shell"))
        }
    }

    func close() async { await stop(error: HerdrError.notConnected) }

    private func stop(error: Error) async {
        guard !closed else { return }
        closed = true
        timeoutTask?.cancel()
        opening?.resume(throwing: error)
        opening = nil
        response?.resume(throwing: error)
        response = nil
        frame = nil
        let closeChannel = self.closeChannel
        self.closeChannel = nil
        writeCommand = nil
        task?.cancel()
        task = nil
        await closeChannel?()
    }
}

struct PaneLiveShells: Sendable {
    let session: PaneLiveInputSession
    let input: PanePersistentShell
    let output: PanePersistentShell
}

extension HerdrConnection {
    /// Probe only shell I/O, before any mutation. Saved-machine routing stays
    /// on the established CLI path; no direct-host stream may bypass its route.
    func prepareLiveShells(session: PaneLiveInputSession) async {
        guard route == nil, let client,
              liveShellUnavailableGeneration != session.generation else { return }
        let pair = PaneLiveShells(session: session, input: PanePersistentShell(), output: PanePersistentShell())
        preparingLiveShells[session.paneId] = session.streamID
        do {
            try await pair.input.open(client: client)
            try await pair.output.open(client: client)
            try requireGeneration(session.generation)
            try Task.checkCancellation()
            guard preparingLiveShells[session.paneId] == session.streamID else { throw HerdrError.notConnected }
            preparingLiveShells.removeValue(forKey: session.paneId)
            if let old = liveShells.updateValue(pair, forKey: session.paneId) {
                Task { await old.input.close(); await old.output.close() }
            }
        } catch {
            if preparingLiveShells[session.paneId] == session.streamID {
                preparingLiveShells.removeValue(forKey: session.paneId)
                if let old = liveShells.removeValue(forKey: session.paneId) {
                    Task { await old.input.close(); await old.output.close() }
                }
                if !Task.isCancelled {
                    liveShellUnavailableGeneration = session.generation
                }
            }
            await pair.input.close()
            await pair.output.close()
        }
    }

    /// False means setup selected legacy transport before input was written.
    /// An execution error always propagates: replay over fallback is unsafe.
    func sendThroughLiveShell(_ args: String, session: PaneLiveInputSession) async throws -> Bool {
        guard activeLiveSessions[session.paneId] == session else { throw HerdrError.notConnected }
        guard let pair = liveShells[session.paneId] else { return false }
        guard pair.session == session else { throw HerdrError.notConnected }
        let output = try await pair.input.execute(Self.remoteCommand(args))
        try requireGeneration(session.generation)
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try Self.interpret(output)
        }
        return true
    }

    func endPaneLiveInput(_ session: PaneLiveInputSession) {
        guard activeLiveSessions[session.paneId] == session else { return }
        activeLiveSessions.removeValue(forKey: session.paneId)
        if preparingLiveShells[session.paneId] == session.streamID {
            preparingLiveShells.removeValue(forKey: session.paneId)
        }
        guard liveShells[session.paneId]?.session == session,
              let pair = liveShells.removeValue(forKey: session.paneId) else { return }
        Task { await pair.input.close(); await pair.output.close() }
    }

    func closeAllLiveShells() {
        let pairs = Array(liveShells.values)
        liveShells.removeAll()
        preparingLiveShells.removeAll()
        activeLiveSessions.removeAll()
        liveShellUnavailableGeneration = nil
        Task {
            for pair in pairs { await pair.input.close(); await pair.output.close() }
        }
    }
}

/// Capture the shell owner before disabling input. Failure and recovery paths
/// use the same teardown as pane departure, so clearing the UI token cannot
/// leave its channels alive if the view disappears before recovery runs.
enum PaneLiveSessionTeardown {
    @MainActor
    static func retire(_ session: inout PaneLiveInputSession?, connection: HerdrConnection) {
        guard let token = session else { return }
        Task { await connection.endPaneLiveInput(token) }
        session = nil
    }
}
