import CryptoKit
import Foundation
import Testing
@testable import Herdcats

/// Holds an async wait that a test can release explicitly (Citadel-like hang).
final class ExternallyReleasedWait<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?

    func wait() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            precondition(self.continuation == nil, "Only one pending waiter is supported")
            self.continuation = continuation
            lock.unlock()
        }
    }

    func release(_ value: T) {
        resolve(.success(value))
    }

    func fail(_ error: Error) {
        resolve(.failure(error))
    }

    private func resolve(_ result: Result<T, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

struct TestSignalTests {
    @Test func releaseBeforeWaitIsRetained() async throws {
        let signal = ExternallyReleasedWait<Int>()
        signal.release(42)
        #expect(try await signal.wait() == 42)
    }

    @Test func failureBeforeWaitIsRetained() async {
        let signal = ExternallyReleasedWait<Int>()
        signal.fail(HerdrError.notConnected)
        do {
            _ = try await signal.wait()
            Issue.record("Expected the buffered failure")
        } catch {
            #expect(error as? HerdrError == .notConnected)
        }
    }
}

/// A fresh in-memory key used only to exercise OpenSSH parsing and error text.
/// Never persisted or authorized on an SSH server.
enum OpenSSHParserFixture {
    private static let key = Curve25519.Signing.PrivateKey()

    private static func integer(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return Data(bytes: &bigEndian, count: 4)
    }

    private static func field(_ data: Data) -> Data {
        integer(UInt32(data.count)) + data
    }

    private static var publicBlob: Data {
        field(Data("ssh-ed25519".utf8)) + field(key.publicKey.rawRepresentation)
    }

    static var publicKeyLine: String {
        "ssh-ed25519 " + publicBlob.base64EncodedString()
    }

    static let pem: String = {
        var privateSection = integer(0x12345678) + integer(0x12345678)
        privateSection += field(Data("ssh-ed25519".utf8))
        privateSection += field(key.publicKey.rawRepresentation)
        privateSection += field(key.rawRepresentation + key.publicKey.rawRepresentation)
        privateSection += field(Data("parser-test-only".utf8))
        let paddingCount = 8 - privateSection.count % 8
        privateSection.append(contentsOf: (1...paddingCount).map(UInt8.init))

        var container = Data("openssh-key-v1\u{0}".utf8)
        container += field(Data("none".utf8)) + field(Data("none".utf8)) + field(Data())
        container += integer(1) + field(publicBlob) + field(privateSection)
        let body = container.base64EncodedString()
        let wrapped = stride(from: 0, to: body.count, by: 70).map { offset in
            let start = body.index(body.startIndex, offsetBy: offset)
            let end = body.index(start, offsetBy: min(70, body.count - offset))
            return String(body[start..<end])
        }.joined(separator: "\n")
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n" + wrapped
            + "\n-----END OPENSSH PRIVATE KEY-----"
    }()
}
