import Foundation
import Testing

@testable import Herdcats

private let shaA = String(repeating: "a", count: 64)
private let shaB = String(repeating: "b", count: 64)

private func releaseJSON(
    tag: String, draft: Bool = false, prerelease: Bool = false,
    digest: String? = "sha256:\(shaA)", assetName: String = "install.sh", url: String? = nil, state: String = "uploaded"
) -> [String: Any] {
    let version = tag.replacingOccurrences(of: "herdcats-bridge-v", with: "")
    var asset: [String: Any] = [
        "name": assetName, "state": state,
        "browser_download_url": url ?? "https://github.com/zhiyao/herdcats/releases/download/\(tag)/install.sh",
    ]
    if let digest { asset["digest"] = digest }
    _ = version
    return ["tag_name": tag, "draft": draft, "prerelease": prerelease, "assets": [asset]]
}

private func feed(_ releases: [[String: Any]]) -> Data {
    try! JSONSerialization.data(withJSONObject: releases)
}

@Suite("Bridge release feed")
struct BridgeReleaseFeedTests {
    @Test func picksHighestStableBridgeReleaseNumerically() throws {
        let data = feed([
            releaseJSON(tag: "herdcats-bridge-v0.9.0"),
            releaseJSON(tag: "herdcats-bridge-v0.10.0"),
            releaseJSON(tag: "herdcats-bridge-v0.2.0"),
        ])
        #expect(try BridgeReleaseFeed.latestStable(in: data)?.version == "0.10.0")
    }

    @Test func ignoresDraftsPrereleasesAndUnrelatedTags() throws {
        let data = feed([
            releaseJSON(tag: "herdcats-bridge-v9.0.0", draft: true),
            releaseJSON(tag: "herdcats-bridge-v8.0.0", prerelease: true),
            releaseJSON(tag: "ios-v7.0.0"),
            releaseJSON(tag: "herdcats-bridge-v6.0.0-rc1"),
            releaseJSON(tag: "herdcats-bridge-v6.0"),
            releaseJSON(tag: "herdcats-bridge-v06.0.0"),
            releaseJSON(tag: "Herdcats-Bridge-v5.0.0"),
            releaseJSON(tag: "herdcats-bridge-v0.6.0"),
        ])
        #expect(try BridgeReleaseFeed.latestStable(in: data)?.version == "0.6.0")
        #expect(try BridgeReleaseFeed.latestStable(in: feed([releaseJSON(tag: "ios-v1.0.0")])) == nil)
    }

    @Test func newerReleaseIsInstallableOnlyWithStrictDigestAndDerivedURL() throws {
        let good = try BridgeReleaseFeed.latestStable(in: feed([releaseJSON(tag: "herdcats-bridge-v0.6.0", digest: "sha256:\(shaB)")]))
        #expect(good?.verifiedInstaller == BridgeRelease(version: "0.6.0", installerSHA256: shaB))

        let cases: [[String: Any]] = [
            releaseJSON(tag: "herdcats-bridge-v0.6.0", digest: nil),
            releaseJSON(tag: "herdcats-bridge-v0.6.0", digest: "sha512:\(shaB)"),
            releaseJSON(tag: "herdcats-bridge-v0.6.0", digest: "sha256:\(shaB.uppercased())"),
            releaseJSON(tag: "herdcats-bridge-v0.6.0", digest: "sha256:abc"),
            releaseJSON(tag: "herdcats-bridge-v0.6.0", digest: "sha256:\(shaB)'; rm -rf ~; '"),
            releaseJSON(tag: "herdcats-bridge-v0.6.0", url: "https://evil.example/herdcats-bridge-v0.6.0/install.sh"),
            releaseJSON(tag: "herdcats-bridge-v0.6.0", url: "https://github.com/other/repo/releases/download/herdcats-bridge-v0.6.0/install.sh"),
            releaseJSON(tag: "herdcats-bridge-v0.6.0", assetName: "install.sh.txt"),
            releaseJSON(tag: "herdcats-bridge-v0.6.0", state: "starter"),
        ]
        for release in cases {
            let info = try BridgeReleaseFeed.latestStable(in: feed([release]))
            #expect(info?.version == "0.6.0")
            #expect(info?.verifiedInstaller == nil, "must fall back to manual setup")
        }
    }

    @Test func releaseMatchingPinIgnoresFeedDigest() throws {
        let info = try BridgeReleaseFeed.latestStable(in: feed([
            releaseJSON(tag: "herdcats-bridge-v\(HostHelperSetupPlan.version)", digest: "sha256:\(shaB)"),
        ]))
        #expect(info?.verifiedInstaller == .pinned)
    }

    @Test func malformedPayloadThrows() {
        #expect(throws: (any Error).self) { try BridgeReleaseFeed.latestStable(in: Data("{}".utf8)) }
    }

    @Test func versionComparisonIsNumericAndStrict() {
        #expect(BridgeReleaseFeed.isNewer("0.10.0", than: "0.9.9"))
        #expect(!BridgeReleaseFeed.isNewer("0.5.0", than: "0.5.0"))
        #expect(!BridgeReleaseFeed.isNewer("0.4.9", than: "0.5.0"))
        #expect(!BridgeReleaseFeed.isNewer("0.6.0", than: "garbage"))
        #expect(BridgeRelease(version: "0.6.0", installerSHA256: "zz") == nil)
        #expect(BridgeRelease(version: "0.6.0; id", installerSHA256: shaA) == nil)
    }
}

private final class StubTransport: BridgeReleaseTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Data, Error>]
    private(set) var calls = 0
    var gate: AsyncStream<Void>.Continuation?
    private var waiter: AsyncStream<Void>?
    init(_ results: [Result<Data, Error>], gated: Bool = false) {
        self.results = results
        if gated {
            let pair = AsyncStream<Void>.makeStream()
            waiter = pair.stream
            gate = pair.continuation
        }
    }
    func fetchReleaseList() async throws -> Data {
        lock.lock(); calls += 1
        let result = results.count > 1 ? results.removeFirst() : results[0]
        lock.unlock()
        if let waiter { for await _ in waiter { break } }
        return try result.get()
    }
}

private final class MemoryCache: BridgeReleaseCache, @unchecked Sendable {
    var entry: BridgeReleaseCacheEntry?
    init(_ entry: BridgeReleaseCacheEntry? = nil) { self.entry = entry }
    func load() -> BridgeReleaseCacheEntry? { entry }
    func save(_ entry: BridgeReleaseCacheEntry) { self.entry = entry }
}

private final class Clock: @unchecked Sendable {
    var time = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { time.addTimeInterval(seconds) }
}

private let hostA = ConnectionIdentity(host: "a.example", port: 22, username: "u")
private let hostB = ConnectionIdentity(host: "b.example", port: 22, username: "u")
private let gen1 = ConnectionGeneration(rawValue: 1)
private let gen2 = ConnectionGeneration(rawValue: 2)
private let newerFeed = feed([releaseJSON(tag: "herdcats-bridge-v0.6.0", digest: "sha256:\(shaB)")])

@MainActor
private func makeChecker(
    _ transport: StubTransport, cache: MemoryCache = MemoryCache(), clock: Clock = Clock()
) -> BridgeUpdateChecker {
    BridgeUpdateChecker(transport: transport, cache: cache, now: { clock.time })
}

private struct Boom: Error {}

@Suite("Bridge update checker")
@MainActor struct BridgeUpdateCheckerTests {
    @Test func fetchPublishesLatestAndCaches() async {
        let cache = MemoryCache()
        let checker = makeChecker(StubTransport([.success(newerFeed)]), cache: cache)
        await checker.refresh(force: true)
        #expect(checker.latest?.version == "0.6.0")
        #expect(cache.entry?.latest?.verifiedInstaller?.installerSHA256 == shaB)
    }

    @Test func concurrentRefreshesCoalesceIntoOneRequest() async {
        let transport = StubTransport([.success(newerFeed)], gated: true)
        let checker = makeChecker(transport)
        async let a: Void = checker.refresh(force: true)
        async let b: Void = checker.refresh(force: true)
        async let c: Void = checker.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        transport.gate?.yield()
        _ = await (a, b, c)
        #expect(transport.calls == 1)
    }

    @Test func recentSuccessThrottlesUntilIntervalThenForegroundRefetches() async {
        let clock = Clock()
        let transport = StubTransport([.success(newerFeed)])
        let checker = makeChecker(transport, clock: clock)
        await checker.refresh(force: true)
        await checker.refresh()
        #expect(transport.calls == 1)
        clock.advance(61 * 60)
        await checker.refresh()
        #expect(transport.calls == 2)
        await checker.refresh(force: true)
        #expect(transport.calls == 3)
    }

    @Test func offlineKeepsKnownReleaseAndBacksOff() async {
        let clock = Clock()
        let cache = MemoryCache(BridgeReleaseCacheEntry(
            latest: BridgeReleaseInfo(version: "0.6.0", verifiedInstaller: nil), fetchedAt: clock.time.addingTimeInterval(-7200)))
        let transport = StubTransport([.failure(Boom())])
        let checker = makeChecker(transport, cache: cache, clock: clock)
        #expect(checker.latest?.version == "0.6.0") // from cache at launch
        await checker.refresh(force: true)
        #expect(checker.latest?.version == "0.6.0") // failure keeps it
        #expect(checker.lastFailure != nil)
        await checker.refresh()
        #expect(transport.calls == 1, "failure backoff")
        clock.advance(11 * 60)
        await checker.refresh()
        #expect(transport.calls == 2)
    }

    @Test func malformedResponseIsAFailureNotAnUpdate() async {
        let checker = makeChecker(StubTransport([.success(Data("nope".utf8))]))
        await checker.refresh(force: true)
        #expect(checker.latest == nil)
        #expect(checker.lastFailure != nil)
    }

    @Test func cancelledInFlightResultIsDiscarded() async {
        let transport = StubTransport([.success(newerFeed)], gated: true)
        let checker = makeChecker(transport)
        let task = Task { await checker.refresh(force: true) }
        try? await Task.sleep(for: .milliseconds(50))
        checker.cancelInFlight()
        transport.gate?.yield()
        await task.value
        #expect(checker.latest == nil)
        #expect(!checker.isRefreshing)
        // A later refresh starts clean.
        await checker.refresh(force: true)
        #expect(checker.latest?.version == "0.6.0")
    }

    private func observed(_ checker: BridgeUpdateChecker, host: ConnectionIdentity = hostA,
                          generation: ConnectionGeneration = gen1, version: String?) async {
        await checker.ensureObservation(host: host, generation: generation) { version }
    }

    @Test func noPromptWhenEqualOlderUnknownOrNothingObserved() async {
        let checker = makeChecker(StubTransport([.success(newerFeed)]))
        await checker.refresh(force: true)
        #expect(checker.prompt(activeHost: hostA, generation: gen1) == nil) // not observed yet
        await observed(checker, version: "0.6.0")
        #expect(checker.prompt(activeHost: hostA, generation: gen1) == nil) // equal
        checker.invalidateObservation()
        await observed(checker, version: "0.7.0")
        #expect(checker.prompt(activeHost: hostA, generation: gen1) == nil) // installed newer
        checker.invalidateObservation()
        await observed(checker, version: nil)
        #expect(checker.prompt(activeHost: hostA, generation: gen1) == nil) // bridge missing
        checker.invalidateObservation()
        await observed(checker, version: "weird")
        #expect(checker.prompt(activeHost: hostA, generation: gen1) == nil)
    }

    @Test func promptUsesInstalledNotBundledPin() async {
        let checker = makeChecker(StubTransport([.success(newerFeed)]))
        await checker.refresh(force: true)
        await observed(checker, version: HostHelperSetupPlan.version) // installed == pin, release newer
        let prompt = checker.prompt(activeHost: hostA, generation: gen1)
        #expect(prompt?.installed == HostHelperSetupPlan.version)
        #expect(prompt?.available.version == "0.6.0")
        #expect(prompt?.available.verifiedInstaller?.installerSHA256 == shaB)
    }

    @Test func observationIsBoundToHostAndConnectionGeneration() async {
        let checker = makeChecker(StubTransport([.success(newerFeed)]))
        await checker.refresh(force: true)
        await observed(checker, version: "0.5.0")
        #expect(checker.prompt(activeHost: hostA, generation: gen1) != nil)
        #expect(checker.prompt(activeHost: hostB, generation: gen1) == nil, "host switch")
        #expect(checker.prompt(activeHost: hostA, generation: gen2) == nil, "same-host reconnect")
        #expect(checker.prompt(activeHost: hostA, generation: nil) == nil)
        // Reconnect re-probes and may observe a different version.
        await observed(checker, generation: gen2, version: "0.6.0")
        #expect(checker.prompt(activeHost: hostA, generation: gen2) == nil)
        #expect(checker.prompt(activeHost: hostA, generation: gen1) == nil)
    }

    @Test func probeRunsOncePerGeneration() async {
        let checker = makeChecker(StubTransport([.success(newerFeed)]))
        var probes = 0
        await checker.ensureObservation(host: hostA, generation: gen1) { probes += 1; return "0.5.0" }
        await checker.ensureObservation(host: hostA, generation: gen1) { probes += 1; return "0.5.0" }
        #expect(probes == 1)
        checker.invalidateObservation() // post-update re-read
        await checker.ensureObservation(host: hostA, generation: gen1) { probes += 1; return "0.6.0" }
        #expect(probes == 2)
        #expect(checker.observation?.version == "0.6.0")
    }

    @Test func transientProbeFailureRetriesAfterBackoffUpToABound() async {
        let clock = Clock()
        let checker = makeChecker(StubTransport([.success(newerFeed)]), clock: clock)
        var probes = 0
        await checker.ensureObservation(host: hostA, generation: gen1) { probes += 1; throw Boom() }
        await checker.ensureObservation(host: hostA, generation: gen1) { probes += 1; return "0.5.0" }
        #expect(probes == 1, "backing off")
        clock.advance(BridgeUpdateChecker.probeRetryInterval + 1)
        await checker.ensureObservation(host: hostA, generation: gen1) { probes += 1; throw Boom() }
        clock.advance(BridgeUpdateChecker.probeRetryInterval + 1)
        await checker.ensureObservation(host: hostA, generation: gen1) { probes += 1; throw Boom() }
        clock.advance(BridgeUpdateChecker.probeRetryInterval + 1)
        await checker.ensureObservation(host: hostA, generation: gen1) { probes += 1; return "0.5.0" }
        #expect(probes == 3, "bounded")
        #expect(checker.observation == nil)
        // A reconnect is a new generation with a fresh budget.
        await checker.ensureObservation(host: hostA, generation: gen2) { probes += 1; return "0.5.0" }
        #expect(checker.observation?.generation == gen2)
    }

    @Test func lateOldProbeCannotOverwriteANewerProbeForTheSameHostAndGeneration() async {
        let checker = makeChecker(StubTransport([.success(newerFeed)]))
        let gate = AsyncStream<Void>.makeStream()
        let old = Task {
            await checker.ensureObservation(host: hostA, generation: gen1) {
                for await _ in gate.stream { break }
                return "0.5.0" // stale: read before the update
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        checker.invalidateObservation() // explicit update completed
        await checker.ensureObservation(host: hostA, generation: gen1) { "0.6.0" }
        #expect(checker.observation?.version == "0.6.0")
        gate.continuation.yield()
        await old.value
        #expect(checker.observation?.version == "0.6.0", "stale probe must not publish")
        // And it must not have cleared the newer state: no re-probe is started.
        var reprobed = false
        await checker.ensureObservation(host: hostA, generation: gen1) { reprobed = true; return "0.5.0" }
        #expect(!reprobed)
    }

    @Test func invalidateDuringProbeDropsItsResult() async {
        let checker = makeChecker(StubTransport([.success(newerFeed)]))
        await checker.ensureObservation(host: hostA, generation: gen1) {
            checker.invalidateObservation()
            return "0.5.0"
        }
        #expect(checker.observation == nil)
    }

    @Test func dismissalIsPerHostAndReleaseForTheLaunch() async {
        let checker = makeChecker(StubTransport([.success(newerFeed)]))
        await checker.refresh(force: true)
        await observed(checker, version: "0.5.0")
        let prompt = checker.prompt(activeHost: hostA, generation: gen1)!
        checker.dismiss(prompt)
        #expect(checker.prompt(activeHost: hostA, generation: gen1) == nil)
        // Reconnect: still dismissed for the same host and release.
        await observed(checker, generation: gen2, version: "0.5.0")
        #expect(checker.prompt(activeHost: hostA, generation: gen2) == nil)
        // Another host is prompted independently.
        await observed(checker, host: hostB, generation: gen2, version: "0.5.0")
        #expect(checker.prompt(activeHost: hostB, generation: gen2) != nil)
    }

    @Test func manualOnlyReleasePromptsButOffersNoInstaller() async {
        let noDigest = feed([releaseJSON(tag: "herdcats-bridge-v0.6.0", digest: nil)])
        let checker = makeChecker(StubTransport([.success(noDigest)]))
        await checker.refresh(force: true)
        await observed(checker, version: "0.5.0")
        let prompt = checker.prompt(activeHost: hostA, generation: gen1)
        #expect(prompt != nil)
        #expect(prompt?.available.verifiedInstaller == nil)
    }
}

@Suite("Bridge update install guards")
struct BridgeUpdateInstallGuardTests {
    @Test func pinnedScriptIsUnchangedAndNewerScriptUsesItsOwnVersionAndDigest() throws {
        let pinned = HostHelperSetupPlan.installationScript(replace: false)
        #expect(pinned.contains("herdcats-bridge-v\(HostHelperSetupPlan.version)/install.sh"))
        #expect(pinned.contains("'\(HostHelperSetupPlan.installerSHA256)'"))
        let release = try #require(BridgeRelease(version: "0.6.0", installerSHA256: shaB))
        let script = HostHelperSetupPlan.installationScript(replace: true, release: release)
        #expect(script.contains("https://github.com/zhiyao/herdcats/releases/download/herdcats-bridge-v0.6.0/install.sh"))
        #expect(script.contains("[ \"$HB_SUM\" = '\(shaB)' ] || fail checksum_mismatch"))
        #expect(script.contains("--version '0.6.0' --replace"))
        #expect(!script.contains(HostHelperSetupPlan.installerSHA256))
    }

    @Test func decisionUpgradesManagedHostOnlyBelowTheTargetRelease() throws {
        let release = try #require(BridgeRelease(version: "0.6.0", installerSHA256: shaB))
        let atPin = HostHelperProbe.present(version: "0.5.0", managed: true, compatible: true)
        #expect(HostHelperSetupPlan.decision(probe: atPin, replace: false, checkOnly: false, reason: .updateRequired, target: release) == .install(replace: true))
        #expect(HostHelperSetupPlan.decision(probe: atPin, replace: false, checkOnly: false, reason: .updateRequired) == .ready)
        let current = HostHelperProbe.present(version: "0.6.0", managed: true, compatible: true)
        #expect(HostHelperSetupPlan.decision(probe: current, replace: false, checkOnly: false, reason: .updateRequired, target: release) == .ready)
    }

    @Test func verificationRejectsAnInstallThatLeftAnOlderVersion() throws {
        let release = try #require(BridgeRelease(version: "9.9.9", installerSHA256: shaB))
        let report = #"{"name":"herdcats-bridge","version":"0.5.0","protocol":1,"herdr_protocol":22,"agents":["claude"]}"#
        let output = "HC_HELPER_INSTALLED\n" + report
        #expect(throws: HostHelperSetupError.invalidResponse) {
            try HostHelperSetupPlan.verifyInstallation(output, release: release)
        }
        try HostHelperSetupPlan.verifyInstallation(output) // pinned default still passes
    }

    @Test func cacheRevalidatesEveryStoredField() throws {
        let defaults = UserDefaults(suiteName: "bridge-cache-test-\(UUID().uuidString)")!
        let cache = UserDefaultsBridgeReleaseCache(defaults: defaults)
        cache.save(BridgeReleaseCacheEntry(latest: BridgeReleaseInfo(version: "0.6.0", verifiedInstaller: BridgeRelease(version: "0.6.0", installerSHA256: shaB)), fetchedAt: Date(timeIntervalSince1970: 5)))
        #expect(cache.load()?.latest?.verifiedInstaller?.installerSHA256 == shaB)
        defaults.set(["fetchedAt": 5.0, "version": "0.6.0", "sha256": "not-hex'; evil"], forKey: UserDefaultsBridgeReleaseCache.key)
        #expect(cache.load()?.latest?.verifiedInstaller == nil)
        defaults.set(["fetchedAt": 5.0, "version": "../x"], forKey: UserDefaultsBridgeReleaseCache.key)
        #expect(cache.load()?.latest == nil)
    }
}


@Suite("Bridge update host setup")
@MainActor struct BridgeUpdateSetupTests {
    private func prompt(installed: String = "0.5.0", installer: BridgeRelease? = nil) -> BridgeUpdatePrompt {
        BridgeUpdatePrompt(host: hostA, installed: installed,
                           available: BridgeReleaseInfo(version: "0.6.0", verifiedInstaller: installer))
    }

    private func settle(_ setup: BridgeUpdateSetup) async {
        for _ in 0..<50 where setup.stage.isBusy || setup.stage == .idle && setup.feedback == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func manualSetup(probing version: String?, installed: @escaping () -> Void = {}) -> BridgeUpdateSetup {
        BridgeUpdateSetup(
            prompt: prompt(), generation: gen1,
            runner: { _, _, _, _ in Issue.record("manual-only must never run the installer runner"); return .ready },
            prober: { version },
            onInstalled: installed)
    }

    @Test func manualOnlyUnchangedOlderVersionIsNotCompletion() async {
        var installedCalls = 0
        let setup = manualSetup(probing: "0.5.0") { installedCalls += 1 }
        setup.install() // no verified installer: inert
        #expect(setup.stage == .idle)
        setup.checkAgain()
        await settle(setup)
        #expect(!setup.isFinished)
        #expect(installedCalls == 0)
        #expect(setup.stage != .installed)
        #expect(setup.feedback?.contains("still 0.5.0") == true)
    }

    @Test func manualOnlyReachingTheTargetVersionCompletesAndRefreshes() async {
        var installedCalls = 0
        let setup = manualSetup(probing: "0.6.0") { installedCalls += 1 }
        setup.checkAgain()
        await settle(setup)
        #expect(setup.isFinished)
        #expect(setup.stage == .installed)
        #expect(installedCalls == 1)
    }

    @Test func manualOnlyMissingBridgeIsNotCompletion() async {
        let setup = manualSetup(probing: nil)
        setup.checkAgain()
        await settle(setup)
        #expect(!setup.isFinished)
    }

    @Test func verifiedInstallRunsThroughRunnerWithTheTargetRelease() async throws {
        let release = try #require(BridgeRelease(version: "0.6.0", installerSHA256: shaB))
        var seen: BridgeRelease?
        var installedCalls = 0
        let setup = BridgeUpdateSetup(
            prompt: prompt(installer: release), generation: gen1,
            runner: { _, _, r, onStage in seen = r; await onStage(.installing); return .ready },
            prober: { Issue.record("not used"); return nil },
            onInstalled: { installedCalls += 1 })
        setup.install()
        await settle(setup)
        #expect(seen == release)
        #expect(setup.isFinished && installedCalls == 1)
    }

    @Test func failureAfterInstallStartedIsUncertainAndNotCompletion() async throws {
        let release = try #require(BridgeRelease(version: "0.6.0", installerSHA256: shaB))
        let setup = BridgeUpdateSetup(
            prompt: prompt(installer: release), generation: gen1,
            runner: { _, _, _, onStage in await onStage(.installing); throw HostHelperSetupError.invalidResponse },
            prober: { nil }, onInstalled: { Issue.record("must not refresh") })
        setup.install()
        await settle(setup)
        #expect(setup.stage == .uncertain)
        #expect(!setup.isFinished)
    }

    @Test func leavingTheSheetCancelsAndSnoozesTheHostRelease() async {
        let checker = makeChecker(StubTransport([.success(newerFeed)]))
        await checker.refresh(force: true)
        await checker.ensureObservation(host: hostA, generation: gen1) { "0.5.0" }
        let shown = checker.prompt(activeHost: hostA, generation: gen1)!
        let setup = BridgeUpdateSetup(
            prompt: shown, generation: gen1,
            runner: { _, _, _, _ in try await Task.sleep(for: .seconds(30)); return .ready },
            prober: { nil }, onInstalled: {})
        setup.checkAgain()
        setup.finish(snoozingIn: checker) // Not now / swipe / stale ownership
        #expect(checker.prompt(activeHost: hostA, generation: gen1) == nil, "banner must not return")
        #expect(!setup.isBusy)
        #expect(!setup.isFinished)
    }

    @Test func checkOnlyOfAnUnchangedOlderHostIsNotUpdateCompletion() throws {
        let release = try #require(BridgeRelease(version: "0.5.1", installerSHA256: shaB))
        let unchanged = HostHelperProbe.present(version: "0.5.0", managed: true, compatible: true)
        #expect(HostHelperSetupPlan.decision(probe: unchanged, replace: false, checkOnly: true, reason: .updateRequired, target: release) == .replacementRequired(unchanged))
        let updated = HostHelperProbe.present(version: "0.5.1", managed: true, compatible: true)
        #expect(HostHelperSetupPlan.decision(probe: updated, replace: false, checkOnly: true, reason: .updateRequired, target: release) == .ready)
        // Non-update checks keep their behavior.
        #expect(HostHelperSetupPlan.decision(probe: unchanged, replace: false, checkOnly: true) == .ready)
    }
}
