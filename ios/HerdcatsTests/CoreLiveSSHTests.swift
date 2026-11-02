import Foundation
import Testing
@testable import Herdcats

private final class CoreLiveBundle: NSObject {}
private struct CoreLiveConfiguration: Decodable {
    let host: String
    let port: Int
    let username: String
    let privateKey: String
    let hostKey: String
    let unavailablePrivateKey: String?

    static var load: Self? {
        if let text = ProcessInfo.processInfo.environment["HC_CORE_LIVE_CONFIG"] {
            return try? JSONDecoder().decode(Self.self, from: Data(text.utf8))
        }
        guard let url = Bundle(for: CoreLiveBundle.self).url(forResource: "core-live-smoke", withExtension: "json"),
              let bytes = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: bytes)
    }
}

@Suite("Core live SSH", .serialized)
struct CoreLiveSSHTests {
    @MainActor @Test(.enabled(if: CoreLiveConfiguration.load?.unavailablePrivateKey != nil))
    func startupClosureKeepsActionableCoreErrorAndNeverFallsBack() async throws {
        let config = try #require(CoreLiveConfiguration.load)
        let key = try #require(config.unavailablePrivateKey)
        try #require(config.host == "127.0.0.1" && config.port > 1024)
        try await SSHHostKeyStore.shared.trust(config.hostKey, host: config.host, port: config.port)
        // The disposable SSH server restricts this test key to /usr/bin/false:
        // login succeeds but the Core exec channel immediately closes.
        for _ in 0..<5 {
            let model = AppModel(autoConnectOnLaunch: false)
            await model.connect(config: ConnectionConfig(host: config.host, port: config.port,
                username: config.username, auth: .privateKey(key), backend: .core))
            #expect(model.phase == .disconnected)
            #expect(model.lastError?.contains("Could not open Herdr Core") == true)
            #expect(!model.hasActiveSession)
            #expect(model.activeConfig?.backend == .core)
            await model.disconnect()
        }
    }

    /// Explicitly opt-in, loopback-only resource generated with disposable keys.
    /// Ordinary builds skip this test and never contact a runtime.
    @Test(.enabled(if: CoreLiveConfiguration.load != nil))
    func nativeConnectionReadsSendsUploadsSubscribesAndReconnectsWithoutBridge() async throws {
        let config = try #require(CoreLiveConfiguration.load)
        try #require(config.host == "127.0.0.1" && config.port > 1024)
        try await SSHHostKeyStore.shared.trust(config.hostKey, host: config.host, port: config.port)
        let connection = HerdrConnection()
        let settings = ConnectionConfig(host: config.host, port: config.port, username: config.username,
                                        auth: .privateKey(config.privateKey), backend: .core)
        var scratch: String?
        do {
            let generation = await connection.reserveConnectGeneration()
            try await connection.connect(settings, expected: generation, onDisconnect: { _ in })
            let version = try await connection.serverVersion()
            #expect(version.hasPrefix("Herdr Core "))
            _ = try await connection.workspaceList()
            _ = try await connection.agentList()
            #expect(await connection.agentBridges.isEmpty)
            do {
                _ = try await connection.runHerdr("workspace list")
                Issue.record("Core unexpectedly allowed a legacy runtime command")
            } catch let error as HerdrError {
                guard case .invalidConfiguration = error else { throw error }
            }
            do {
                _ = try await connection.openAgentTimeline(paneId: "t1", onEvent: { _ in })
                Issue.record("Core unexpectedly opened a bridge")
            } catch let error as HerdrError {
                guard case .invalidConfiguration = error else { throw error }
            }

            let created = try await connection.coreRequest("terminal.run", params: [
                "argv": .array([.string("/bin/cat")]), "name": .string("hc-native-" + UUID().uuidString.prefix(8).lowercased()),
                "no_parent": .bool(true), "no_notify": .bool(true), "keep": .bool(false),
                "labels": .object(["herdcats.test": .string("core-native")])
            ])
            let address = try #require(created["address"].stringValue)
            scratch = address
            let marker = "Swift Core round trip " + UUID().uuidString
            // Cursor label deliberately exercises bypass of the old bridge-only
            // provider guard. Input goes exclusively to the owned cat process.
            try await connection.paneSubmit(paneId: address, text: marker, agent: "cursor")
            var echoed = false
            for _ in 0..<50 {
                if try await connection.paneReadText(paneId: address).contains(marker) { echoed = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(echoed)
            try await connection.paneSendKeys(paneId: address, Array("keyprobe").map(String.init) + ["enter"])
            var keysEchoed = false
            for _ in 0..<50 {
                if try await connection.paneReadText(paneId: address).contains("keyprobe") { keysEchoed = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(keysEchoed)
            let hierarchy = try await connection.corePresentation()
            #expect(hierarchy.panes.contains { $0.paneId == address })
            #expect(hierarchy.workspaces.contains { $0.workspaceId == CoreHierarchy.otherWorkspaceID })

            let image = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7S8AAAAASUVORK5CYII="))
            let path = try await connection.uploadAttachment(data: image, fileExtension: "png", paneId: address)
            let inspected = try await connection.coreRequest("machine.exec", params: [
                "argv": .array([.string("python3"), .string("-c"),
                                 .string("import base64,pathlib,sys;print(base64.b64encode(pathlib.Path(sys.argv[1]).read_bytes()).decode())"), .string(path)])
            ])
            let output = try #require(Data(base64Encoded: inspected["stdout"].stringValue ?? ""))
            #expect(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == image.base64EncodedString())
            try await connection.markAgentSeen(paneId: address, tabId: "unused", hasAgent: false)
            try await connection.coreInterrupt(terminal: address)
            _ = try await connection.coreRequest("terminal.kill", params: ["terminal": .string(address)])
            _ = try await connection.coreRequest("terminal.rm", params: ["terminal": .string(address)])
            scratch = nil
            await connection.close()

            let next = await connection.reserveConnectGeneration()
            try await connection.connect(settings, expected: next, onDisconnect: { _ in })
            _ = try await connection.serverVersion()
            let restored = try await connection.corePresentation()
            #expect(!restored.panes.contains { $0.paneId == address })
            do {
                _ = try await connection.coreRequest("terminal.keys", params: ["terminal": .string(address), "keys": .array([.string("enter")])], expectedGeneration: generation)
                Issue.record("Stale generation was allowed to send input")
            } catch let error as HerdrError { #expect(error == .notConnected) }
        } catch {
            if let scratch {
                _ = try? await connection.coreRequest("terminal.kill", params: ["terminal": .string(scratch)])
                _ = try? await connection.coreRequest("terminal.rm", params: ["terminal": .string(scratch)])
            }
            await connection.close()
            throw error
        }
        await connection.close()
    }
}
