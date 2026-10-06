import Foundation
import Security
import NIOSSH
import SwiftUI
import Testing
@testable import Herdcats

@Suite("Refresh generation gate")
struct RefreshGenerationGateTests {
    @MainActor
    @Test func newSpacesModelIsLoadingBeforeRefreshStarts() {
        let model = SpacesModel()
        #expect(model.isLoading)
        #expect(model.lastUpdated == nil)
        #expect(!model.hasLoadedAgentList)
        #expect(model.showsAgentLoading)
    }

    @MainActor
    @Test func failedInitialRefreshDoesNotConfirmAnEmptyAgentList() async {
        let model = SpacesModel()
        await model.refresh(HerdrConnection())
        #expect(!model.isLoading)
        #expect(!model.hasLoadedAgentList)
    }

    @Test func staleCompletionAfterWatchdogIsDropped() {
        var gate = RefreshGenerationGate()
        let first = gate.begin()
        let timeout = gate.watchdogTimeout(for: first)
        #expect(timeout)
        let finishFirst = gate.finishIfCurrent(first)
        #expect(!finishFirst)
        let second = gate.begin()
        let finishSecond = gate.finishIfCurrent(second)
        #expect(finishSecond)
        #expect(!gate.isLoading)
    }

    @MainActor
    @Test(arguments: [false, true])
    func initialErrorExposesRetryAndSuccessfulRetryClearsIt(allMachines: Bool) async throws {
        let model = SpacesModel()
        let connection = HerdrConnection()
        let source: SpacesModel
        if allMachines {
            let app = AppModel(autoConnectOnLaunch: false)
            app.connectionIdentity = ConnectionIdentity(host: "fixture", port: 22, username: "tester")
            await model.bindMachines(app)
            source = try #require(model.machineSources.first?.model)
        } else {
            source = model
        }
        source.agentListFetch = { throw HerdrError.unexpectedResponse("Agent list failed") }
        await model.refresh(connection)
        #expect(!model.isLoading)
        #expect(!model.hasLoadedAgentList)
        #expect(model.agentListError?.contains("Agent list failed") == true)
        #expect(!model.showsAgentLoading)

        source.agentListFetch = { ([], []) }
        await model.refresh(connection)
        #expect(model.hasLoadedAgentList)
        #expect(model.agentListError == nil)
        #expect(!model.showsAgentLoading)
    }
}
