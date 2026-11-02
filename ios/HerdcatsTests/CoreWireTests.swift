import Foundation
import Testing

@testable import Herdcats

@Suite("Core wire protocol")
struct CoreWireTests {
    @Test func fragmentedHeadersAndPayloadsReassembleExactly() throws {
        let payload = Data("{\"title\":\"猫\"}".utf8)
        let expected = CoreFrame(channel: 7, kind: .data, payload: payload)
        var parser = CoreFrameParser()
        var frames: [CoreFrame] = []
        for byte in try expected.encoded() {
            frames += try parser.append(Data([byte]))
        }
        #expect(frames == [expected])
        try parser.finish()
    }

    @Test func multipleFramesInOneReadKeepTheirOrderAndLittleEndianChannels() throws {
        let first = CoreFrame(channel: 0x01020304, kind: .data, payload: Data([1, 2, 3]))
        let second = CoreFrame(channel: 0, kind: .data, payload: Data("{}".utf8))
        let bytes = try first.encoded() + second.encoded()
        #expect(Array(bytes.prefix(4)) == [4, 3, 2, 1])
        var parser = CoreFrameParser()
        #expect(try parser.append(bytes) == [first, second])
    }

    @Test func oversizedHeaderFailsBeforeWaitingForPayload() {
        var parser = CoreFrameParser()
        let bytes = Data([1, 0, 0, 0, 0, 1, 0, 0, 1]) // 16 MiB + 1
        #expect(throws: CoreRPCError.frameTooLarge) { _ = try parser.append(bytes) }
    }

    @Test func truncatedFrameAndUnknownKindFail() throws {
        var parser = CoreFrameParser()
        _ = try parser.append(Data([0, 0, 0]))
        #expect(throws: CoreRPCError.invalidFrame) { try parser.finish() }
        var other = CoreFrameParser()
        #expect(throws: CoreRPCError.invalidFrame) {
            _ = try other.append(Data([1, 0, 0, 0, 99, 0, 0, 0, 0]))
        }
    }

    @Test func eventLinesBufferSplitUTF8AndSeveralNotifications() throws {
        let first = Data("{\"method\":\"event\",\"params\":{\"title\":\"猫\"}}\n".utf8)
        let second = Data("{\"method\":\"heartbeat\",\"params\":{\"seq\":4}}\n".utf8)
        var parser = CoreJSONLineParser()
        var messages: [CoreJSON] = []
        for byte in first + second {
            messages += try parser.append(Data([byte]))
        }
        #expect(messages.count == 2)
        #expect(messages[0]["params"]["title"].stringValue == "猫")
        #expect(messages[1]["params"]["seq"].uint64Value == 4)
        try parser.finish()
    }

    @Test func eventLineLimitAndMalformedJSONFail() {
        var bounded = CoreJSONLineParser(maximumLineBytes: 8)
        #expect(throws: CoreRPCError.frameTooLarge) {
            _ = try bounded.append(Data(repeating: 65, count: 9))
        }
        var malformed = CoreJSONLineParser()
        #expect(throws: CoreRPCError.invalidFrame) {
            _ = try malformed.append(Data("not json\n".utf8))
        }
    }

    @Test func JSONRoundTripsAndIntegerAccessRejectsLossyConversions() throws {
        let value: CoreJSON = .object(["text": .string("hello"), "null": .null,
                                      "array": .array([.bool(true), .number(42)])])
        #expect(try JSONDecoder().decode(CoreJSON.self, from: JSONEncoder().encode(value)) == value)
        #expect(value["missing"] == .null)
        #expect(CoreJSON.number(1.5).intValue == nil)
        #expect(CoreJSON.number(-1).uint64Value == nil)
        #expect(CoreJSON.number(.infinity).intValue == nil)
    }

    @Test func remoteErrorsKeepStableKindAndHint() throws {
        let reply = try JSONDecoder().decode(CoreJSON.self, from: Data(
            "{\"jsonrpc\":\"2.0\",\"id\":\"r\",\"error\":{\"code\":-32000,\"message\":\"waiting\",\"data\":{\"kind\":\"unavailable\",\"hint\":\"retry after restarted\"}}}".utf8))
        #expect(CoreRPCError.responseError(reply) == .remote(
            code: -32000, kind: "unavailable", message: "waiting", hint: "retry after restarted"))
        #expect(CoreRPCError.responseError(.object(["result": .null])) == nil)
    }
}

private actor CoreTestWire {
    var writes: [Data] = []
    var transportCloses = 0
    var notificationCloses = 0
    var events: [CoreJSON] = []
    private var writeWaiters: [Int: CheckedContinuation<Data, Never>] = [:]
    private var eventWaiter: CheckedContinuation<CoreJSON, Never>?
    private var closeWaiter: CheckedContinuation<Void, Never>?
    private var blockedWrites = Set<Int>()
    private var writeReleases: [Int: CheckedContinuation<Void, Never>] = [:]

    func write(_ bytes: Data) async {
        writes.append(bytes)
        let number = writes.count
        writeWaiters.removeValue(forKey: number)?.resume(returning: bytes)
        if blockedWrites.remove(number) != nil {
            await withCheckedContinuation { writeReleases[number] = $0 }
        }
    }
    func blockWrite(_ number: Int) { blockedWrites.insert(number) }
    func releaseWrite(_ number: Int) { writeReleases.removeValue(forKey: number)?.resume() }
    func waitForWrite(_ number: Int) async -> Data {
        if writes.count >= number { return writes[number - 1] }
        return await withCheckedContinuation { writeWaiters[number] = $0 }
    }
    func closeTransport() { transportCloses += 1 }
    func closed() {
        notificationCloses += 1
        closeWaiter?.resume()
        closeWaiter = nil
    }
    func waitForClose() async {
        if notificationCloses > 0 { return }
        await withCheckedContinuation { closeWaiter = $0 }
    }
    func record(_ event: CoreJSON) {
        events.append(event)
        eventWaiter?.resume(returning: event)
        eventWaiter = nil
    }
    func waitForEvent() async -> CoreJSON {
        if let event = events.first { return event }
        return await withCheckedContinuation { eventWaiter = $0 }
    }
}

private actor CoreCallbackReader {
    var client: CoreRPCClient?
    let wire: CoreTestWire
    init(wire: CoreTestWire) { self.wire = wire }
    func install(_ value: CoreRPCClient) { client = value }
    func receive(_ notification: CoreJSON) async throws {
        let client = try #require(client)
        let document = try await client.request("doc.get", params: ["name": .string("herdr-app")])
        await wire.record(document)
    }
}

@Suite("Core RPC lifecycle", .timeLimit(.minutes(1)))
struct CoreRPCLifecycleTests {
    private func decodeRequest(_ data: Data) throws -> CoreJSON {
        var frames = CoreFrameParser()
        let frame = try #require(try frames.append(data).first)
        return try JSONDecoder().decode(CoreJSON.self, from: frame.payload)
    }
    private func reply(_ request: CoreJSON, result: CoreJSON) throws -> Data {
        let payload: CoreJSON = .object(["jsonrpc": .string("2.0"), "id": request["id"], "result": result])
        return try CoreFrame(channel: 0, kind: .data, payload: JSONEncoder().encode(payload)).encoded()
    }
    private func open(
        _ wire: CoreTestWire,
        onNotification: @escaping @Sendable (CoreJSON) async throws -> Void = { _ in }
    ) async throws -> CoreRPCClient {
        let client = CoreRPCClient(onNotification: onNotification, onClose: { await wire.closed() })
        let opening = Task {
            try await client.open(write: { await wire.write($0) }, close: { await wire.closeTransport() })
        }
        let request = try JSONDecoder().decode(CoreJSON.self, from: await wire.waitForWrite(1))
        let result: CoreJSON = .object(["generation": .number(1), "framed": .bool(true), "version": .string("0.1.14")])
        let response: CoreJSON = .object(["jsonrpc": .string("2.0"), "id": request["id"], "result": result])
        await client.receive(try JSONEncoder().encode(response) + Data([10]))
        #expect(try await opening.value == result)
        #expect(await client.isOpen)
        return client
    }

    @Test func repliesAreCorrelatedWhenTheyArriveInReverseOrder() async throws {
        let wire = CoreTestWire()
        let client = try await open(wire)
        let first = Task { try await client.request("first") }
        let second = Task { try await client.request("second") }
        let a = try decodeRequest(await wire.waitForWrite(2))
        let b = try decodeRequest(await wire.waitForWrite(3))
        for request in [b, a] {
            await client.receive(try reply(request, result: request["method"]))
        }
        #expect(try await first.value == .string("first"))
        #expect(try await second.value == .string("second"))
        await client.close()
        await client.close()
        #expect(await client.isOpen == false)
        #expect(await wire.transportCloses == 1)
        #expect(await wire.notificationCloses == 0)
    }

    @Test func cancelledRequestDrainsItsLateReplyWithoutResendingInput() async throws {
        let wire = CoreTestWire()
        let client = try await open(wire)
        let input = Task { try await client.request("terminal.send", params: ["text": .string("once")]) }
        let request = try decodeRequest(await wire.waitForWrite(2))
        input.cancel()
        do {
            _ = try await input.value
            Issue.record("Cancelled input returned a response")
        } catch { #expect(error is CancellationError) }
        await client.receive(try reply(request, result: .null))
        let next = Task { try await client.request("terminal.list") }
        let nextRequest = try decodeRequest(await wire.waitForWrite(3))
        await client.receive(try reply(nextRequest, result: .object(["terminals": .array([])])))
        #expect(try await next.value["terminals"] == .array([]))
        #expect(await wire.writes.count == 3)
        #expect(await wire.notificationCloses == 0)
        await client.close()
    }

    @Test func earlyEventCanMakeRPCBeforeReturningCreditWithoutBlockingReads() async throws {
        let wire = CoreTestWire()
        let callback = CoreCallbackReader(wire: wire)
        let client = try await open(wire, onNotification: { try await callback.receive($0) })
        await callback.install(client)
        let subscribe = Task { try await client.subscribeEvents() }
        let request = try decodeRequest(await wire.waitForWrite(2))
        let event = Data("{\"jsonrpc\":\"2.0\",\"method\":\"event\",\"params\":{\"seq\":1,\"type\":\"doc\"}}\n".utf8)
        let early = try CoreFrame(channel: 7, kind: .data, payload: event).encoded()
        let snapshot: CoreJSON = .object(["seq": .number(0), "channel": .number(7), "terminals": .array([])])
        await client.receive(try early + reply(request, result: snapshot))
        #expect(try await subscribe.value == snapshot)
        let documentRequest = try decodeRequest(await wire.waitForWrite(3))
        #expect(documentRequest["method"].stringValue == "doc.get")
        await client.receive(try reply(documentRequest, result: .object(["version": .number(2)])))
        #expect(await wire.waitForEvent()["version"].intValue == 2)
        var parser = CoreFrameParser()
        let credit = try #require(try parser.append(await wire.waitForWrite(4)).first)
        #expect(credit.kind == .credit)
        #expect(credit.channel == 7)
        #expect(credit.payload.count == 4)
        await client.close()
    }

    @Test func invalidFrameRejectsPendingCallsAndNotifiesClosureOnce() async throws {
        let wire = CoreTestWire()
        let client = try await open(wire)
        let pending = Task { try await client.request("terminal.list") }
        _ = await wire.waitForWrite(2)
        await client.receive(Data([0, 0, 0, 0, 99, 0, 0, 0, 0]))
        do { _ = try await pending.value; Issue.record("Invalid frame was accepted") }
        catch { #expect(error as? CoreRPCError == .invalidFrame) }
        await wire.waitForClose()
        await client.close()
        #expect(await wire.transportCloses == 1)
        #expect(await wire.notificationCloses == 1)
    }

    @Test func remoteRPCErrorRejectsOnlyItsRequest() async throws {
        let wire = CoreTestWire()
        let client = try await open(wire)
        let call = Task { try await client.request("terminal.send") }
        let request = try decodeRequest(await wire.waitForWrite(2))
        let error: CoreJSON = .object([
            "jsonrpc": .string("2.0"), "id": request["id"], "error": .object([
                "code": .number(-32000), "message": .string("program is blocked"),
                "data": .object(["kind": .string("blocked")])
            ])
        ])
        await client.receive(try CoreFrame(channel: 0, kind: .data, payload: JSONEncoder().encode(error)).encoded())
        do { _ = try await call.value; Issue.record("Remote error was accepted") }
        catch {
            #expect(error as? CoreRPCError == .remote(code: -32000, kind: "blocked", message: "program is blocked", hint: nil))
        }
        #expect(await wire.notificationCloses == 0)
        await client.close()
    }

    @Test func deadlineClosesTheChannelWithoutResendingTheCall() async throws {
        let wire = CoreTestWire()
        let client = try await open(wire)
        let call = Task { try await client.request("terminal.send", timeout: 0.05) }
        _ = await wire.waitForWrite(2)
        do { _ = try await call.value; Issue.record("Unanswered request returned") }
        catch { #expect(error as? CoreRPCError == .timeout) }
        await wire.waitForClose()
        #expect(await wire.writes.count == 2)
        #expect(await wire.transportCloses == 1)
        #expect(await wire.notificationCloses == 1)
        await client.close()
    }

    @Test func optionalDocumentTimeoutDrainsLateReplyAndKeepsChannelUsable() async throws {
        let wire = CoreTestWire()
        let client = try await open(wire)
        let document = Task { try await client.request("doc.get", timeout: 0.05, closeOnTimeout: false) }
        let request = try decodeRequest(await wire.waitForWrite(2))
        do { _ = try await document.value; Issue.record("Unanswered optional document returned") }
        catch { #expect(error as? CoreRPCError == .timeout) }
        await client.receive(try reply(request, result: .object(["value": .null, "version": .number(0)])))
        let next = Task { try await client.request("terminal.list") }
        let list = try decodeRequest(await wire.waitForWrite(3))
        await client.receive(try reply(list, result: .object(["terminals": .array([])])))
        #expect(try await next.value["terminals"] == .array([]))
        #expect(await wire.notificationCloses == 0)
        #expect(await wire.writes.count == 3)
        await client.close()
    }

    @Test func cancelledQueuedMutationNeverReachesWriterAndDoesNotPoisonLaterWrites() async throws {
        let wire = CoreTestWire()
        let client = try await open(wire)
        await wire.blockWrite(2)
        let first = Task { try await client.request("terminal.list") }
        let firstRequest = try decodeRequest(await wire.waitForWrite(2))
        let mutation = Task { try await client.request("terminal.send", params: ["text": .string("do not send")]) }
        // Let the mutation enter the actor and suspend behind the blocked writer.
        // The writer itself cannot complete until this test releases it.
        for _ in 0..<100 { await Task.yield() }
        mutation.cancel()
        do { _ = try await mutation.value; Issue.record("Cancelled queued mutation returned") }
        catch { #expect(error is CancellationError) }

        let later = Task { try await client.request("terminal.get") }
        await wire.releaseWrite(2)
        await client.receive(try reply(firstRequest, result: .array([])))
        _ = try await first.value
        let next = try decodeRequest(await wire.waitForWrite(3))
        #expect(next["method"].stringValue == "terminal.get")
        if next["method"].stringValue != "terminal.get" {
            // Drain a buggy late write so a regression records a failure rather
            // than stranding the later request until its deadline.
            await client.receive(try reply(next, result: .null))
            let actualLater = try decodeRequest(await wire.waitForWrite(4))
            await client.receive(try reply(actualLater, result: .string("still healthy")))
        } else {
            await client.receive(try reply(next, result: .string("still healthy")))
        }
        #expect(try await later.value == .string("still healthy"))
        #expect(await wire.writes.count == 3)
        #expect(await wire.notificationCloses == 0)
        await client.close()
    }
}
