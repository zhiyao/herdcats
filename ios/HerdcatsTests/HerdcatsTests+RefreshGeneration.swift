import Foundation
import Security
import NIOSSH
import SwiftUI
import Testing
@testable import Herdcats

@Suite("Refresh generation gate")
struct RefreshGenerationGateTests {
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
}
