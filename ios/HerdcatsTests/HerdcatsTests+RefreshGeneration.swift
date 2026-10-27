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
    @Test
    func initialErrorExposesRetryAndSuccessfulRetryClearsIt() async {
        let model = SpacesModel()
        let connection = HerdrConnection()
        model.agentListFetch = { throw HerdrError.unexpectedResponse("Agent list failed") }
        await model.refresh(connection)
        #expect(!model.isLoading)
        #expect(!model.hasLoadedAgentList)
        #expect(model.agentListError?.contains("Agent list failed") == true)
        #expect(!model.showsAgentLoading)

        model.agentListFetch = { ([], []) }
        await model.refresh(connection)
        #expect(model.hasLoadedAgentList)
        #expect(model.agentListError == nil)
        #expect(!model.showsAgentLoading)
    }
}
