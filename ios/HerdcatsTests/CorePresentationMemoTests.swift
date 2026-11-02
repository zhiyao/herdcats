import Foundation
import Testing
@testable import Herdcats

private extension HerdrConnection {
    func installForTest(_ snapshot: CoreSnapshot) { coreSnapshot = snapshot }
    func setLayoutsForTest(_ layouts: [String: CoreJSON]) { coreLayouts = layouts }
    func applyForTest(_ message: CoreJSON) throws {
        if try coreSnapshot?.apply(message) == true { invalidateCorePresentation() }
    }
    var builds: Int { corePresentationBuilds }
}

@Suite("Core presentation memo")
struct CorePresentationMemoTests {
    @Test func repeatedCallsBuildOnceUntilSnapshotOrLayoutsChange() async throws {
        let connection = HerdrConnection()
        await connection.installForTest(try snapshot(seq: 1))

        _ = try await connection.cachedCorePresentation()
        _ = try await connection.cachedCorePresentation()
        #expect(await connection.builds == 1)

        // A new event advances the snapshot sequence.
        try await connection.applyForTest(json("{\"method\":\"event\",\"params\":{\"seq\":2,\"type\":\"title\",\"terminal\":\"t1\",\"data\":{\"title\":\"New\"}}}"))
        let updated = try await connection.cachedCorePresentation()
        #expect(await connection.builds == 2)
        #expect(updated.panes.first?.terminalTitle == "New")
        _ = try await connection.cachedCorePresentation()
        #expect(await connection.builds == 2)

        // Assigning layouts invalidates even with an unchanged sequence.
        await connection.setLayoutsForTest(["": .null])
        _ = try await connection.cachedCorePresentation()
        #expect(await connection.builds == 3)
    }

    @Test func missedAndNewSubscriptionDropTheMemo() async throws {
        let connection = HerdrConnection()
        await connection.installForTest(try snapshot(seq: 5))
        _ = try await connection.cachedCorePresentation()

        // Same sequence number but replaced terminals must not reuse the memo.
        try await connection.applyForTest(json("{\"method\":\"missed\",\"params\":{\"seq\":9,\"terminals\":[]}}"))
        let afterMissed = try await connection.cachedCorePresentation()
        #expect(afterMissed.panes.isEmpty)

        await connection.installForTest(try snapshot(seq: 9))
        await connection.invalidateCorePresentation()
        let replaced = try await connection.cachedCorePresentation()
        #expect(replaced.panes.count == 1)
    }

    @Test func closeCoreClearsTheMemo() async throws {
        let connection = HerdrConnection()
        await connection.installForTest(try snapshot(seq: 1))
        _ = try await connection.cachedCorePresentation()
        await connection.closeCore()
        await #expect(throws: (any Error).self) { try await connection.cachedCorePresentation() }
        await connection.installForTest(try snapshot(seq: 1))
        _ = try await connection.cachedCorePresentation()
        #expect(await connection.builds == 2)
    }

    private func snapshot(seq: Int) throws -> CoreSnapshot {
        let terminal = "{\"address\":\"t1\",\"title\":\"Terminal\",\"state\":\"live\",\"cwd\":\"/p\",\"created_ms\":1,\"status\":null,\"reported\":false,\"labels\":{}}"
        return try CoreSnapshot(subscription: json("{\"seq\":\(seq),\"terminals\":[\(terminal)]}"))
    }

    private func json(_ value: String) throws -> CoreJSON {
        try JSONDecoder().decode(CoreJSON.self, from: Data(value.utf8))
    }
}
