import Foundation
import Observation

// MARK: - Release model

/// A Herdcats Bridge release whose installer this app may run: strict version
/// and a SHA-256 of `install.sh`. Both are validated on construction, so they
/// are safe to interpolate into the single-quoted install script.
struct BridgeRelease: Equatable, Sendable {
    let version: String
    let installerSHA256: String

    /// The release compiled into this app build.
    static let pinned = BridgeRelease(
        validatedVersion: HostHelperSetupPlan.version,
        installerSHA256: HostHelperSetupPlan.installerSHA256
    )

    init?(version: String, installerSHA256: String) {
        guard BridgeReleaseFeed.isCanonicalVersion(version),
              BridgeReleaseFeed.isSHA256Hex(installerSHA256)
        else { return nil }
        self.init(validatedVersion: version, installerSHA256: installerSHA256)
    }

    private init(validatedVersion: String, installerSHA256: String) {
        self.version = validatedVersion
        self.installerSHA256 = installerSHA256
    }
}

/// The newest stable bridge release. `verifiedInstaller` is nil when no
/// trustworthy installer checksum is available; the UI then offers manual
/// setup only and never an in-app install.
struct BridgeReleaseInfo: Equatable, Sendable {
    let version: String
    let verifiedInstaller: BridgeRelease?

    static var pinned: BridgeReleaseInfo { .init(version: BridgeRelease.pinned.version, verifiedInstaller: .pinned) }
}

// MARK: - Feed parsing

/// Filters and validates GitHub release metadata. Everything that reaches an
/// install script is derived here from strict patterns, never copied from the
/// response.
enum BridgeReleaseFeed {
    static let repository = "zhiyao/herdcats"
    static let tagPrefix = "herdcats-bridge-v"
    static let listURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!

    static func installerURL(version: String) -> String {
        "https://github.com/\(repository)/releases/download/\(tagPrefix)\(version)/install.sh"
    }

    static func isCanonicalVersion(_ version: String) -> Bool {
        guard let numbers = HostHelperProbe.versionNumbers(version) else { return false }
        // Reject "01" and the like so the version always round-trips into the tag and URL.
        return numbers.map(String.init).joined(separator: ".") == version
    }

    static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// Strict `herdcats-bridge-vX.Y.Z` tag → version, otherwise nil.
    static func stableVersion(tag: String) -> String? {
        guard tag.hasPrefix(tagPrefix) else { return nil }
        let version = String(tag.dropFirst(tagPrefix.count))
        return isCanonicalVersion(version) ? version : nil
    }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]?
    }
    private struct Asset: Decodable {
        let name: String
        let digest: String?
        let browser_download_url: String?
        let state: String?
    }

    /// Newest stable bridge release in a `/releases` array, or nil when none qualifies.
    /// Throws when the payload is not a release list at all.
    static func latestStable(in data: Data) throws -> BridgeReleaseInfo? {
        let releases = try JSONDecoder().decode([Release].self, from: data)
        var best: (numbers: [Int], release: Release, version: String)?
        for release in releases where !release.draft && !release.prerelease {
            guard let version = stableVersion(tag: release.tag_name),
                  let numbers = HostHelperProbe.versionNumbers(version)
            else { continue }
            if let current = best, !current.numbers.lexicographicallyPrecedes(numbers) { continue }
            best = (numbers, release, version)
        }
        guard let best else { return nil }
        // The version this build ships carries its own compiled checksum.
        if best.version == BridgeRelease.pinned.version {
            return BridgeReleaseInfo(version: best.version, verifiedInstaller: .pinned)
        }
        return BridgeReleaseInfo(version: best.version, verifiedInstaller: verifiedInstaller(version: best.version, assets: best.release.assets ?? []))
    }

    /// An installer is trusted only when exactly one `install.sh` asset is
    /// uploaded, lives at the URL this app derives itself, and carries a
    /// well-formed `sha256:` digest recorded by GitHub.
    private static func verifiedInstaller(version: String, assets: [Asset]) -> BridgeRelease? {
        let installers = assets.filter { $0.name == "install.sh" }
        guard installers.count == 1, let asset = installers.first,
              asset.state == nil || asset.state == "uploaded",
              asset.browser_download_url == installerURL(version: version),
              let digest = asset.digest, digest.hasPrefix("sha256:")
        else { return nil }
        return BridgeRelease(version: version, installerSHA256: String(digest.dropFirst("sha256:".count)))
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let candidate = HostHelperProbe.versionNumbers(candidate),
              let installed = HostHelperProbe.versionNumbers(installed)
        else { return false }
        return installed.lexicographicallyPrecedes(candidate)
    }
}

// MARK: - Transport and cache

protocol BridgeReleaseTransport: Sendable {
    func fetchReleaseList() async throws -> Data
}

struct GitHubBridgeReleaseTransport: BridgeReleaseTransport {
    static let maxBytes = 1_000_000
    enum TransportError: Error { case badResponse }

    func fetchReleaseList() async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        var request = URLRequest(url: BridgeReleaseFeed.listURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Herdcats-iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.host == "api.github.com", data.count <= Self.maxBytes
        else { throw TransportError.badResponse }
        return data
    }
}

/// Last good result, so a launch can show a known update before (or without) the network.
struct BridgeReleaseCacheEntry: Equatable, Sendable {
    var latest: BridgeReleaseInfo?
    var fetchedAt: Date
}

protocol BridgeReleaseCache: Sendable {
    func load() -> BridgeReleaseCacheEntry?
    func save(_ entry: BridgeReleaseCacheEntry)
}

struct UserDefaultsBridgeReleaseCache: BridgeReleaseCache, @unchecked Sendable {
    static let key = "bridge-release-cache.v1"
    var defaults: UserDefaults = .standard

    func load() -> BridgeReleaseCacheEntry? {
        guard let raw = defaults.dictionary(forKey: Self.key),
              let fetched = raw["fetchedAt"] as? Double
        else { return nil }
        let fetchedAt = Date(timeIntervalSince1970: fetched)
        // Re-validate everything: the cache is input, not trust.
        guard let version = raw["version"] as? String, BridgeReleaseFeed.isCanonicalVersion(version) else {
            return BridgeReleaseCacheEntry(latest: nil, fetchedAt: fetchedAt)
        }
        var installer: BridgeRelease?
        if version == BridgeRelease.pinned.version {
            installer = .pinned
        } else if let sha = raw["sha256"] as? String {
            installer = BridgeRelease(version: version, installerSHA256: sha)
        }
        return BridgeReleaseCacheEntry(latest: BridgeReleaseInfo(version: version, verifiedInstaller: installer), fetchedAt: fetchedAt)
    }

    func save(_ entry: BridgeReleaseCacheEntry) {
        var raw: [String: Any] = ["fetchedAt": entry.fetchedAt.timeIntervalSince1970]
        if let latest = entry.latest {
            raw["version"] = latest.version
            if let installer = latest.verifiedInstaller { raw["sha256"] = installer.installerSHA256 }
        }
        defaults.set(raw, forKey: Self.key)
    }
}

// MARK: - Prompt

struct BridgeUpdatePrompt: Equatable, Identifiable {
    let host: ConnectionIdentity
    let installed: String
    let available: BridgeReleaseInfo
    var id: String { Self.key(host: host, version: available.version) }
    static func key(host: ConnectionIdentity, version: String) -> String { "\(host.storageKey)|\(version)" }
}

// MARK: - Checker

/// Launch- and foreground-driven check for a newer stable Herdcats Bridge.
/// It talks only to GitHub — never to a saved SSH machine — and never installs.
/// Whether a given host should be prompted is derived on demand from the
/// latest release plus that host's reported version, so a stale result can
/// never attach to the wrong host.
@MainActor @Observable
final class BridgeUpdateChecker {
    struct Policy: Sendable {
        /// Minimum spacing between non-forced successful checks.
        var refreshInterval: TimeInterval = 60 * 60
        /// Minimum spacing after a failed check (offline, rate-limited, malformed).
        var failureBackoff: TimeInterval = 10 * 60
    }

    private(set) var latest: BridgeReleaseInfo?
    private(set) var lastSuccess: Date?
    private(set) var lastFailure: Date?
    private(set) var fetchCount = 0

    private let transport: any BridgeReleaseTransport
    private let cache: any BridgeReleaseCache
    private let policy: Policy
    private let now: @Sendable () -> Date
    private var inFlight: Task<Void, Never>?
    private var generation = 0
    private var dismissed: Set<String> = []

    init(
        transport: any BridgeReleaseTransport = GitHubBridgeReleaseTransport(),
        cache: any BridgeReleaseCache = UserDefaultsBridgeReleaseCache(),
        policy: Policy = Policy(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.cache = cache
        self.policy = policy
        self.now = now
        if let entry = cache.load() {
            latest = entry.latest
            lastSuccess = entry.fetchedAt
        }
    }

    var isRefreshing: Bool { inFlight != nil }

    /// `force` is for launch: always ask GitHub (unless a request is already in flight).
    /// Otherwise a recent success or failure suppresses the request.
    func refresh(force: Bool = false) async {
        if let inFlight {
            await inFlight.value
            return
        }
        guard force || isDue else { return }
        let mine = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performFetch(generation: mine)
        }
        inFlight = task
        await task.value
    }

    /// Drops any in-flight result (e.g. on teardown); a later refresh starts clean.
    func cancelInFlight() {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
    }

    private var isDue: Bool {
        let current = now()
        if let lastFailure, current.timeIntervalSince(lastFailure) < policy.failureBackoff { return false }
        if let lastSuccess, current.timeIntervalSince(lastSuccess) < policy.refreshInterval { return false }
        return true
    }

    private func performFetch(generation mine: Int) async {
        fetchCount += 1
        do {
            let data = try await transport.fetchReleaseList()
            try Task.checkCancellation()
            let info = try BridgeReleaseFeed.latestStable(in: data)
            guard generation == mine else { return }
            latest = info
            lastSuccess = now()
            lastFailure = nil
            cache.save(BridgeReleaseCacheEntry(latest: info, fetchedAt: lastSuccess ?? now()))
        } catch is CancellationError {
            // Cancelled work is neither a result nor a failure.
        } catch {
            guard generation == mine else { return }
            // Keep the last known release; offline must not erase a known update.
            lastFailure = now()
        }
        if generation == mine { inFlight = nil }
    }

    // MARK: Installed-version observation

    /// The installed bridge version seen on one host over one connection
    /// generation. A reconnect (new generation) never reuses it.
    struct InstalledObservation: Equatable {
        let host: ConnectionIdentity
        let generation: ConnectionGeneration
        let version: String?
    }
    struct ObservationKey: Hashable {
        let host: ConnectionIdentity
        let generation: ConnectionGeneration
    }

    private(set) var observation: InstalledObservation?
    /// Bumped by `invalidateObservation()`; observers key their probe task on it.
    private(set) var observationRevision = 0
    /// Identity of the one probe whose result may still be applied. Every probe
    /// gets a fresh token, so an older probe for the *same* host and generation
    /// can never publish over (or clear) a newer one.
    private var activeProbe: (token: UUID, key: ObservationKey)?
    private var failures: [ObservationKey: (count: Int, at: Date)] = [:]
    static let maxProbeFailures = 3
    static let probeRetryInterval: TimeInterval = 60

    /// Probes the active host with a read-only probe supplied by the caller,
    /// at most once per (host, generation) unless it failed: failures retry on
    /// later calls (e.g. foreground) after a backoff, up to a small bound.
    func ensureObservation(
        host: ConnectionIdentity,
        generation: ConnectionGeneration,
        probe: () async throws -> String?
    ) async {
        let key = ObservationKey(host: host, generation: generation)
        if let observation, observation.host == host, observation.generation == generation { return }
        if activeProbe?.key == key { return }
        if let failure = failures[key],
           failure.count >= Self.maxProbeFailures || now().timeIntervalSince(failure.at) < Self.probeRetryInterval { return }
        let token = UUID()
        activeProbe = (token, key)
        let version: String?
        do { version = try await probe() } catch {
            guard activeProbe?.token == token else { return }
            activeProbe = nil
            // A cancelled probe (view churn) is not the host's fault.
            if !(error is CancellationError) && !Task.isCancelled {
                failures[key] = ((failures[key]?.count ?? 0) + 1, now())
            }
            return
        }
        guard activeProbe?.token == token else { return }
        activeProbe = nil
        failures[key] = nil
        observation = InstalledObservation(host: host, generation: generation, version: version)
    }

    /// Forget what was seen (after an explicit update) so the next probe
    /// re-reads the host. Any probe still in flight is orphaned.
    func invalidateObservation() {
        observation = nil
        activeProbe = nil
        failures = [:]
        observationRevision += 1
    }

    // MARK: Prompt ownership

    /// The prompt for the active host, or nil. The installed version must have
    /// been observed on this exact host and connection generation.
    func prompt(activeHost: ConnectionIdentity?, generation: ConnectionGeneration?) -> BridgeUpdatePrompt? {
        guard let latest, let activeHost, let generation,
              let observation, observation.host == activeHost, observation.generation == generation,
              let installed = observation.version, HostHelperProbe.versionNumbers(installed) != nil,
              BridgeReleaseFeed.isNewer(latest.version, than: installed)
        else { return nil }
        let prompt = BridgeUpdatePrompt(host: activeHost, installed: installed, available: latest)
        return dismissed.contains(prompt.id) ? nil : prompt
    }

    /// Dismissal (or acting on the prompt) lasts for this launch, per host and
    /// release. A still-newer release prompts again.
    func dismiss(_ prompt: BridgeUpdatePrompt) {
        dismissed.insert(prompt.id)
    }
}
