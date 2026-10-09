import Foundation
import Security
import NIOSSH
import SwiftUI
import Testing
@testable import Herdcats

@Suite("Timeout teardown notify policy")
struct TimeoutTeardownNotifyTests {
    /// Mirrors HerdrConnection: timeout notifies loss; explicit close does not.
    @Test func currentGenerationTimeoutNotifiesWhileExplicitCloseSilent() {
        final class HandlerBox: @unchecked Sendable {
            var count = 0
        }
        let box = HandlerBox()
        var handler: (@Sendable () -> Void)? = { box.count += 1 }

        var slot = ConnectionClientSlot<Int>()
        let (gen, _) = slot.beginReplace()
        let install1 = slot.install(1, expected: gen)
        #expect(install1 == nil)

        // timeoutTeardown path
        switch slot.invalidate(gen) {
        case .stale:
            Issue.record("expected invalidate")
        case .invalidated:
            let captured = handler
            handler = nil
            captured?()
        }
        #expect(box.count == 1)

        let (gen2, _) = slot.beginReplace()
        let install2 = slot.install(2, expected: gen2)
        #expect(install2 == nil)
        handler = { box.count += 1 }
        // invalidateAndTeardown / forceClose path — clear without notify
        switch slot.invalidate(gen2) {
        case .stale:
            Issue.record("expected invalidate")
        case .invalidated:
            handler = nil
        }
        #expect(box.count == 1)

        // Stale timeout leaves handler alone
        handler = { box.count += 1 }
        switch slot.invalidate(gen2) {
        case .stale:
            break
        case .invalidated:
            Issue.record("stale timeout must not invalidate")
        }
        #expect(handler != nil)
        #expect(box.count == 1)
    }

    @Test func silentTimeoutStillInvalidatesItsGeneration() {
        var slot = ConnectionClientSlot<Int>()
        let (generation, _) = slot.beginReplace()
        #expect(slot.install(42, expected: generation) == nil)

        let result = slot.invalidate(generation)
        switch result {
        case .stale:
            Issue.record("expected timeout to invalidate its owned generation")
        case let .invalidated(client):
            #expect(client == 42)
        }
        #expect(slot.current == nil)
    }

    @Test func timeoutPoliciesSeparateTeardownFromNotification() async {
        let actions = Counter()
        let notifications = Counter()
        for policy in [
            HerdrCommandTimeoutPolicy.teardownAndNotify,
            .teardownSilently,
            .preserveConnection
        ] {
            do {
                _ = try await withTimeout(
                    seconds: 0.01,
                    label: "command",
                    onTimeout: {
                        await policy.apply { notify in
                            await actions.increment()
                            if notify { await notifications.increment() }
                        }
                    },
                    operation: {
                        try await Task.sleep(for: .seconds(1))
                        return 1
                    }
                )
                Issue.record("expected command timeout")
            } catch let error as HerdrError {
                #expect(error == .timeout("command"))
            } catch {
                Issue.record("unexpected timeout error: \(error)")
            }
        }

        #expect(await actions.value == 2)
        #expect(await notifications.value == 1)
    }
}

@Suite("AppModel stale reservation")
struct AppModelStaleReservationTests {
    @Test func staleAssociateDoesNotImplyUIReset() {
        // AppModel closes only the reserved generation when associateReserved
        // fails — a newer attempt already owns connectionIdentity/phase.
        var ownership = ConnectionSessionOwnership()
        let first = ownership.beginAttempt()
        let reserved = ConnectionGeneration(rawValue: 5)
        let firstAssoc = ownership.associateReserved(reserved, for: first)
        #expect(firstAssoc)

        let second = ownership.beginAttempt()
        let orphan = ConnectionGeneration(rawValue: 6)
        let staleAssoc = ownership.associateReserved(orphan, for: first)
        #expect(!staleAssoc)
        #expect(ownership.isCurrent(second))
        let secondAssoc = ownership.associateReserved(orphan, for: second)
        #expect(secondAssoc)
    }
}

@Suite("Standard button styles")
struct ButtonStyleTests {
    @Test func primaryButtonStyleDefaultsAndCustomizations() {
        let defaultStyle = HerdrPrimaryButtonStyle()
        #expect(defaultStyle.fullWidth == true)
        #expect(defaultStyle.cornerRadius == DesignSystem.CornerRadius.button)
        #expect(defaultStyle.cornerRadius == 8)
        #expect(defaultStyle.tint == nil)

        let customStyle = HerdrPrimaryButtonStyle(
            fullWidth: false,
            cornerRadius: DesignSystem.CornerRadius.md,
            tint: .red
        )
        #expect(customStyle.fullWidth == false)
        #expect(customStyle.cornerRadius == 8)
        #expect(customStyle.tint == .red)
    }

    @Test func secondaryButtonStyleDefaultsAndCustomizations() {
        let defaultStyle = HerdrSecondaryButtonStyle()
        #expect(defaultStyle.fullWidth == true)
        #expect(defaultStyle.cornerRadius == DesignSystem.CornerRadius.button)

        let customStyle = HerdrSecondaryButtonStyle(
            fullWidth: false,
            cornerRadius: DesignSystem.CornerRadius.lg
        )
        #expect(customStyle.fullWidth == false)
        #expect(customStyle.cornerRadius == 16)
    }

    @Test func ghostButtonStyleDefaults() {
        let defaultStyle = HerdrGhostButtonStyle()
        #expect(defaultStyle.fullWidth == true)

        let inlineStyle = HerdrGhostButtonStyle(fullWidth: false)
        #expect(inlineStyle.fullWidth == false)
    }

    @Test func buttonStyleExtensionsAccessible() {
        _ = HerdrPrimaryButtonStyle.herdrPrimary
        _ = HerdrPrimaryButtonStyle.herdrPrimary(fullWidth: false)
        _ = HerdrSecondaryButtonStyle.herdrSecondary
        _ = HerdrSecondaryButtonStyle.herdrSecondary(fullWidth: false)
        _ = HerdrGhostButtonStyle.herdrGhost
        _ = HerdrGhostButtonStyle.herdrGhost(fullWidth: false)
        _ = HerdrCardButtonStyle.herdrCard
    }

    @Test func designTokensMatchSpecification() {
        // DESIGN.md §5: 8pt controls, 16pt cards.
        #expect(DesignSystem.CornerRadius.lg == 16)
        #expect(DesignSystem.CornerRadius.md == 8)
        #expect(DesignSystem.CornerRadius.sm == 8)
        #expect(DesignSystem.CornerRadius.button == 8)
        #expect(DesignSystem.CornerRadius.xl == 16)
        #expect(DesignSystem.Spacing.md == 12)
        #expect(DesignSystem.Spacing.base == 16)
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

actor EventLog {
    private var events: [String] = []
    func append(_ event: String) { events.append(event) }
    func snapshot() -> [String] { events }
}

func waitUntilQueued(
    _ coordinator: PaneInputCoordinator,
    paneId: String,
    count: Int
) async {
    while await coordinator.queuedCount(paneId: paneId) < count {
        await Task.yield()
    }
}

actor Flag {
    private(set) var value = false
    func set() { value = true }
}

@Suite("Agent status alerts")
struct AgentStatusAlertTests {
    func agent(_ id: String, _ status: String) -> AgentEntry {
        AgentEntry(
            agent: "codex", agentStatus: status, stateChangeSeq: nil,
            cwd: nil, paneId: id, tabId: "t1", workspaceId: "w1",
            terminalTitle: nil, terminalTitleStripped: nil, focused: false,
            revision: nil
        )
    }

    @Test
    func firstLoadNeverAlerts() {
        #expect(AgentStatusAlerts.event(previous: nil, current: [agent("p1", "blocked")]) == nil)
    }

    @Test
    func workingToDoneOrIdleAlertsDone() {
        let before: [String: AgentStatus] = ["p1": .working]
        #expect(AgentStatusAlerts.event(previous: before, current: [agent("p1", "done")]) == .done)
        #expect(AgentStatusAlerts.event(previous: before, current: [agent("p1", "idle")]) == .done)
    }

    @Test
    func enteringBlockedAlertsBlockedAndOutranksDone() {
        let before: [String: AgentStatus] = ["p1": .working, "p2": .working]
        let current = [agent("p1", "done"), agent("p2", "blocked")]
        #expect(AgentStatusAlerts.event(previous: before, current: current) == .blocked)
    }

    @Test
    func unchangedSeenOrNewAgentsDoNotAlert() {
        let before: [String: AgentStatus] = ["p1": .blocked, "p2": .done, "p3": .idle]
        let current = [
            agent("p1", "blocked"),   // still blocked
            agent("p2", "idle"),      // done was seen on the Mac
            agent("p3", "working"),   // started work
            agent("p4", "blocked")    // new pane, not a transition
        ]
        #expect(AgentStatusAlerts.event(previous: before, current: current) == nil)
    }

    @Test
    func selectedSoundFallsBackToDefaultsAndReadsStoredChoice() throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentStatusAlertTests"))
        defaults.removePersistentDomain(forName: "AgentStatusAlertTests")
        #expect(AgentAlertSound.selected(for: .done, defaults: defaults) == .defaultDone)
        #expect(AgentAlertSound.selected(for: .blocked, defaults: defaults) == .defaultBlocked)
        defaults.set(AgentAlertSound.off.rawValue, forKey: AgentAlertSound.blockedStorageKey)
        #expect(AgentAlertSound.selected(for: .blocked, defaults: defaults) == .off)
        #expect(AgentAlertSound.off.systemSoundID == nil)
    }
}

@Suite("Saved Herdr machines")
struct HerdrMachineTests {
    func machine(id: String = "mini", session: String = "default", target: String = "example-mini") -> HerdrMachine {
        HerdrMachine(id: id, label: "Example Mac Mini", target: target, session: session, enabled: true)
    }

    @Test func decodesBareMachineCatalog() throws {
        let json = #"""
        [{"id":"mini","label":"Example Mac Mini","target":"example-mini","session":"default",
          "enabled":true,"selected":false},
         {"id":"off","label":"Offline","target":"other","session":"work","enabled":false}]
        """#
        let machines = try JSONDecoder().decode([HerdrMachine].self, from: Data(json.utf8))
        #expect(machines.count == 2)
        #expect(machines[0] == machine())
        #expect(!machines[1].enabled)
        #expect(try JSONDecoder().decode([HerdrMachine].self, from: Data("[]".utf8)).isEmpty)
    }

    @Test func paneStorageSeparatesMachinesSessionsAndTargets() throws {
        let gateway = ConnectionIdentity(host: "Mac.local", port: 22, username: "Owner")
        #expect(gateway.storageKey == "u=Owner|h=mac.local|p=22")
        let scopes = [gateway, gateway.scoped(to: machine()),
                      gateway.scoped(to: machine(id: "other")),
                      gateway.scoped(to: machine(session: "other")),
                      gateway.scoped(to: machine(target: "other"))]
        #expect(Set(scopes.map { PanePersistenceKeys.draft(scope: $0, paneId: "w1:p1") }).count == 5)
        #expect(Set(scopes.map { PanePersistenceKeys.history(scope: $0, paneId: "w1:p1") }).count == 5)
        let legacy = #"{"host":"Mac.local","port":22,"username":"Owner"}"#
        #expect(try JSONDecoder().decode(ConnectionIdentity.self, from: Data(legacy.utf8)) == gateway)
        let scope = gateway.scoped(to: machine(id: "a|s=b", session: "c/d"))
        #expect(scope.storageKey.contains("m=a%7Cs%3Db"))
        #expect(scope.storageKey.contains("s=c%2Fd"))
    }

    @Test func machineSelectorCannotInjectShellCommands() {
        let id = "mini'; $(touch /tmp/unsafe); `whoami`\n"
        let arguments = HerdrConnection.machineArguments("pane list", machineID: id)
        #expect(arguments.hasPrefix("--machine "))
        #expect(arguments.hasSuffix(" pane list"))
        #expect(!arguments.contains("touch"))
        #expect(!arguments.contains("whoami"))
        #expect(!arguments.contains("'"))
        let encoded = arguments.dropFirst("--machine ".count).dropLast(" pane list".count)
        let octal = encoded.dropFirst("\"$(printf \"".count).dropLast(3)
        let bytes = octal.split(separator: "\\").compactMap { UInt8($0, radix: 8) }
        #expect(String(bytes: bytes, encoding: .utf8) == id)
    }

    @Test func routedConnectionRejectsGatewayOnlyFeaturesAndStaleTransport() async {
        let gateway = HerdrConnection()
        let routed = HerdrConnection(gateway: gateway, machine: machine(),
                                     generation: ConnectionGeneration(rawValue: 0), identity: nil)
        #expect(!routed.supportsHostServices)
        #expect(gateway.supportsHostServices)
        await #expect(throws: HerdrError.notConnected) { try await routed.workspaceList() }
        do {
            _ = try await routed.quotaReport()
            Issue.record("A routed quota call must not use the gateway")
        } catch {
            #expect((error as? HerdrError)?.errorDescription?.contains("not yet available") == true)
        }
        do {
            _ = try await routed.uploadAttachment(data: Data([1]), fileExtension: "png")
            Issue.record("A routed upload must not write to the gateway")
        } catch {
            #expect((error as? HerdrError)?.errorDescription?.contains("not yet available") == true)
        }
        _ = await gateway.reserveConnectGeneration()
        await #expect(throws: HerdrError.notConnected) { try await routed.paneSendText(paneId: "w1:p1", text: "hello") }
        #expect(await gateway.generation == ConnectionGeneration(rawValue: 1))
    }
}

@Suite("Bundled typefaces")
struct BundledTypefaceTests {
    /// Every name `Font.jost` and `Font.pixel` ask for must resolve, or SwiftUI
    /// silently falls back to the system font.
    @Test func jostAndSilkscreenResolve() {
        let weights: [Font.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        for weight in weights {
            let name = AppTypeface.jostName(weight)
            #expect(UIFont(name: name, size: 17) != nil, "Missing \(name)")
        }
        #expect(UIFont(name: AppTypeface.silkscreenName(bold: false), size: 10) != nil)
        #expect(UIFont(name: AppTypeface.silkscreenName(bold: true), size: 10) != nil)
    }

    /// Named instances of the variable font must render at their own weight,
    /// not fall back to the default Regular instance.
    @Test func jostWeightsRenderDistinctly() {
        func width(_ weight: Font.Weight) -> CGFloat {
            let font = AppTypeface.uiJost(17, weight: weight)
            return ("Herdcats wrangles agents" as NSString).size(withAttributes: [.font: font]).width
        }
        #expect(width(.light) < width(.regular))
        #expect(width(.regular) < width(.semibold))
        #expect(width(.semibold) < width(.bold))
    }
}
