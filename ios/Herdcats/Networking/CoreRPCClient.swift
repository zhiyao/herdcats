import Citadel
import Foundation
import NIOCore

/// A single non-PTY Core channel. The connection owns all request IDs and event
/// stream credit; closing it never closes the caller's shared SSH transport.
actor CoreRPCClient {
    private struct Pending {
        let continuation: CheckedContinuation<CoreJSON, Error>
        let timeout: Task<Void, Never>
    }
    private struct EventBatch {
        let messages: [CoreJSON]
        let bytes: Int
    }

    private let onNotification: @Sendable (CoreJSON) async throws -> Void
    private let onClose: @Sendable () async -> Void
    private var writer: (@Sendable (Data) async throws -> Void)?
    private var closer: (@Sendable () async -> Void)?
    private var streamTask: Task<Void, Never>?
    private var opening: CheckedContinuation<Void, Error>?
    private var openTimeout: Task<Void, Never>?
    private var pending: [String: Pending] = [:]
    private var sentRequests = Set<String>()
    private var retired = Set<String>()
    private var closedError: CoreRPCError?
    private var helloID: String?
    private var helloBuffer = Data()
    private var framed = false
    private var frames = CoreFrameParser()
    private var eventLines = CoreJSONLineParser()
    private var subscribing = false
    private var eventChannel: UInt32?
    private var earlyFrames: [CoreFrame] = []
    private var earlyBytes = 0
    private var eventBatches: [EventBatch] = []
    private var queuedEventBytes = 0
    private var eventDeliveryTask: Task<Void, Never>?
    private var lastWrite: Task<Void, Error>?
    private var writes: [UUID: Task<Void, Error>] = [:]

    init(
        onNotification: @escaping @Sendable (CoreJSON) async throws -> Void,
        onClose: @escaping @Sendable () async -> Void
    ) {
        self.onNotification = onNotification
        self.onClose = onClose
    }

    var isOpen: Bool { framed && closedError == nil }

    func open(client: SSHClient, command: String) async throws -> CoreJSON {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard closedError == nil, streamTask == nil, writer == nil else { throw CoreRPCError.closed }
            try await withCheckedThrowingContinuation { continuation in
                opening = continuation
                openTimeout = Task {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    await self.stop(.timeout)
                }
                streamTask = Task {
                    do {
                        try await client.withExec(command) { inbound, outbound in
                            await self.attach(outbound)
                            for try await output in inbound {
                                try Task.checkCancellation()
                                switch output {
                                case let .stdout(bytes):
                                    await self.receive(Data(bytes.readableBytesView))
                                case .stderr: break // Never mix diagnostics with framed stdout.
                                }
                            }
                        }
                        await self.stop(.closed)
                    } catch {
                        await self.stop((error as? CoreRPCError) ?? .closed)
                    }
                }
            }
            return try await handshake()
        } onCancel: {
            Task { await self.close() }
        }
    }

    /// Byte-transport injection keeps protocol ownership independent of SSH.
    /// The caller feeds received bytes to receive and owns inbound EOF.
    func open(
        write: @escaping @Sendable (Data) async throws -> Void,
        close: @escaping @Sendable () async -> Void
    ) async throws -> CoreJSON {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard closedError == nil, writer == nil, streamTask == nil else { throw CoreRPCError.closed }
            writer = write
            closer = close
            return try await handshake()
        } onCancel: {
            Task { await self.close() }
        }
    }

    private func attach(_ outbound: TTYStdinWriter) async {
        guard closedError == nil else { try? await outbound.close(); return }
        writer = { bytes in try await outbound.write(ByteBuffer(bytes: bytes)) }
        closer = { try? await outbound.close() }
        openTimeout?.cancel()
        openTimeout = nil
        let continuation = opening
        opening = nil
        continuation?.resume()
    }

    private func handshake() async throws -> CoreJSON {
        let result = try await request("hello", params: ["generation": .number(1), "framed": .bool(true)], timeout: 10)
        guard result["generation"].intValue == 1, result["framed"].boolValue == true else {
            await stop(.unsupportedGeneration)
            throw CoreRPCError.unsupportedGeneration
        }
        return result
    }

    func request(
        _ method: String,
        params: [String: CoreJSON] = [:],
        timeout: TimeInterval = 15,
        closeOnTimeout: Bool = true
    ) async throws -> CoreJSON {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard closedError == nil, writer != nil else { throw closedError ?? .closed }
            guard timeout.isFinite, timeout > 0 else { throw CoreRPCError.timeout }
            guard pending.count < 64 else { throw CoreRPCError.tooManyRequests }
            let isHello = !framed && method == "hello" && helloID == nil
            guard framed || isHello else { throw CoreRPCError.invalidFrame }
            let request: CoreJSON = .object([
                "jsonrpc": .string("2.0"), "id": .string(id),
                "method": .string(method), "params": .object(params)
            ])
            let payload = try JSONEncoder().encode(request)
            guard payload.count <= CoreFrame.maximumPayload else { throw CoreRPCError.frameTooLarge }
            let bytes: Data
            if isHello {
                helloID = id
                bytes = payload + Data([10])
            } else {
                bytes = try CoreFrame(channel: 0, kind: .data, payload: payload).encoded()
            }
            return try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task {
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    // Mutations may have uncertain delivery. Optional reads can
                    // retire their ID and drain a late reply without disrupting
                    // terminal browsing. Neither policy resends a request.
                    if closeOnTimeout { await self.stop(.timeout) }
                    else { await self.retireRequest(id, error: CoreRPCError.timeout) }
                }
                pending[id] = Pending(continuation: continuation, timeout: timeoutTask)
                Task {
                    guard self.pending[id] != nil, self.closedError == nil else { return }
                    do { try await self.send(bytes, requestID: id) }
                    catch { await self.stop((error as? CoreRPCError) ?? .closed) }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    private func cancelRequest(_ id: String) async {
        await retireRequest(id, error: CancellationError())
    }

    private func retireRequest(_ id: String, error: Error) async {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(throwing: error)
        // A sent call can still finish remotely; drain its eventual reply.
        // Unsent queued calls are dropped at the writer, with no reply to drain.
        if sentRequests.remove(id) != nil { retired.insert(id) }
        if retired.count > 128 { await stop(.closed) }
    }

    func subscribeEvents() async throws -> CoreJSON {
        guard eventChannel == nil, !subscribing else { throw CoreRPCError.invalidFrame }
        subscribing = true
        defer { subscribing = false }
        do {
            let result = try await request("events.subscribe")
            guard let number = result["channel"].uint64Value, number > 0,
                  let channel = UInt32(exactly: number),
                  result["seq"].uint64Value != nil, result["terminals"].arrayValue != nil else {
                throw CoreRPCError.invalidFrame
            }
            eventChannel = channel
            let queued = earlyFrames
            earlyFrames = []
            earlyBytes = 0
            for frame in queued { try consumeStream(frame) }
            return result
        } catch {
            await stop((error as? CoreRPCError) ?? .closed)
            throw error
        }
    }

    private var canWrite: Bool { closedError == nil }

    /// Every write is one whole frame. The chain preserves order across actor
    /// suspension while allowing replies and events to continue arriving.
    private func send(_ data: Data, requestID: String? = nil) async throws {
        guard closedError == nil, let writer else { throw closedError ?? .closed }
        let previous = lastWrite
        let id = UUID()
        let task = Task {
            if let previous { try await previous.value }
            try Task.checkCancellation()
            guard self.canWrite else { throw CoreRPCError.closed }
            if let requestID {
                // The caller can be canceled while this task waits behind a
                // previous write. Drop an unsent retired call successfully so
                // it neither emits input nor poisons the write chain.
                guard self.pending[requestID] != nil else { return }
                self.sentRequests.insert(requestID)
            }
            try await writer(data)
        }
        writes[id] = task
        lastWrite = task
        defer { writes.removeValue(forKey: id) }
        try await task.value
    }

    func receive(_ bytes: Data) async {
        guard closedError == nil else { return }
        do {
            var remainder = bytes
            if !framed {
                helloBuffer.append(bytes)
                if let newline = helloBuffer.firstIndex(of: 10) {
                    guard newline <= CoreFrame.maximumPayload else { throw CoreRPCError.frameTooLarge }
                    let reply = try decodeObject(Data(helloBuffer.prefix(upTo: newline)))
                    if let error = CoreRPCError.responseError(reply) { throw error }
                    guard reply["id"].stringValue == helloID,
                          reply["result"]["generation"].intValue == 1,
                          reply["result"]["framed"].boolValue == true else {
                        throw CoreRPCError.unsupportedGeneration
                    }
                    remainder = Data(helloBuffer.suffix(from: newline + 1))
                    helloBuffer = Data()
                    framed = true // Flip before resuming hello or parsing trailing bytes.
                    try deliverReply(reply)
                } else {
                    guard helloBuffer.count <= CoreFrame.maximumPayload else { throw CoreRPCError.frameTooLarge }
                    return
                }
            }
            for frame in try frames.append(remainder) {
                if frame.channel == 0 {
                    guard frame.kind == .data else { throw CoreRPCError.invalidFrame }
                    try deliverReply(decodeObject(frame.payload))
                } else if eventChannel != nil {
                    try consumeStream(frame)
                } else {
                    // Core can send event frames before the subscribe RPC reply.
                    guard subscribing, earlyFrames.count < 1024,
                          earlyBytes + frame.payload.count <= 512 * 1024 else {
                        throw CoreRPCError.invalidFrame
                    }
                    earlyFrames.append(frame)
                    earlyBytes += frame.payload.count
                }
            }
        } catch {
            await stop((error as? CoreRPCError) ?? .invalidFrame)
        }
    }

    private func decodeObject(_ bytes: Data) throws -> CoreJSON {
        guard let value = try? JSONDecoder().decode(CoreJSON.self, from: bytes),
              value.objectValue != nil, value["jsonrpc"].stringValue == "2.0" else {
            throw CoreRPCError.invalidFrame
        }
        return value
    }

    private func deliverReply(_ reply: CoreJSON) throws {
        guard let id = reply["id"].stringValue else { throw CoreRPCError.invalidFrame }
        if retired.remove(id) != nil { return }
        sentRequests.remove(id)
        guard let request = pending.removeValue(forKey: id) else { throw CoreRPCError.invalidFrame }
        request.timeout.cancel()
        if let error = CoreRPCError.responseError(reply) {
            request.continuation.resume(throwing: error)
        } else if reply.objectValue?["result"] != nil {
            request.continuation.resume(returning: reply["result"])
        } else {
            request.continuation.resume(throwing: CoreRPCError.invalidFrame)
            throw CoreRPCError.invalidFrame
        }
    }

    private func consumeStream(_ frame: CoreFrame) throws {
        guard frame.channel == eventChannel else { throw CoreRPCError.invalidFrame }
        switch frame.kind {
        case .data:
            guard !frame.payload.isEmpty else { return }
            guard eventBatches.count < 32_768,
                  queuedEventBytes + frame.payload.count <= 4 * 1024 * 1024 else {
                throw CoreRPCError.frameTooLarge
            }
            let messages = try eventLines.append(frame.payload)
            guard messages.allSatisfy({ $0.objectValue != nil && $0["jsonrpc"].stringValue == "2.0"
                && ["event", "heartbeat", "missed"].contains($0["method"].stringValue ?? "")
                && $0.objectValue?["id"] == nil }) else { throw CoreRPCError.invalidFrame }
            eventBatches.append(EventBatch(messages: messages, bytes: frame.payload.count))
            queuedEventBytes += frame.payload.count
            if eventDeliveryTask == nil {
                eventDeliveryTask = Task { await self.deliverEvents() }
            }
        case .credit:
            guard frame.payload.count == 4 else { throw CoreRPCError.invalidFrame }
        case .close:
            // The event subscription is no longer usable; a reconnect takes a
            // fresh snapshot. The SSH generation owner decides how to recover.
            throw CoreRPCError.closed
        case .resize, .focus, .facts:
            throw CoreRPCError.invalidFrame
        }
    }

    /// Runs independently from receive: callbacks may make RPCs on channel 0.
    private func deliverEvents() async {
        defer { eventDeliveryTask = nil }
        do {
            while closedError == nil, !eventBatches.isEmpty {
                let batch = eventBatches.removeFirst()
                for message in batch.messages {
                    try Task.checkCancellation()
                    try await onNotification(message)
                }
                guard closedError == nil else { return }
                queuedEventBytes -= batch.bytes
                guard let eventChannel, closedError == nil else { return }
                var credit = Data()
                CoreFrame.appendLittleEndian(UInt32(batch.bytes), to: &credit)
                try await send(CoreFrame(channel: eventChannel, kind: .credit, payload: credit).encoded())
            }
        } catch {
            await stop((error as? CoreRPCError) ?? .closed)
        }
    }

    func close() async { await stop(.closed, notify: false) }

    private func stop(_ error: CoreRPCError, notify: Bool = true) async {
        guard closedError == nil else { return }
        closedError = error
        openTimeout?.cancel()
        openTimeout = nil
        let opening = self.opening
        self.opening = nil
        opening?.resume(throwing: error)
        let requests = Array(pending.values)
        pending = [:]
        sentRequests = []
        retired = []
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
        eventDeliveryTask?.cancel()
        eventDeliveryTask = nil
        eventBatches = []
        queuedEventBytes = 0
        earlyFrames = []
        earlyBytes = 0
        for write in writes.values { write.cancel() }
        writes = [:]
        lastWrite = nil
        writer = nil
        let closer = self.closer
        self.closer = nil
        streamTask?.cancel()
        streamTask = nil
        await closer?()
        if notify { await onClose() }
    }
}
