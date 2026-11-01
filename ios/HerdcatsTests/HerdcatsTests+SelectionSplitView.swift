import SwiftUI
import Testing
@testable import Herdcats

@Suite("Selection split view")
struct SelectionSplitViewTests {
    @Test func columnVisibilityRoundTripsThroughSceneStorage() {
        for visibility in [NavigationSplitViewVisibility.all, .doubleColumn, .detailOnly, .automatic] {
            #expect(NavigationSplitViewVisibility(storageValue: visibility.storageValue) == visibility)
        }
    }

    @Test func unknownStoredVisibilityShowsBothColumns() {
        #expect(NavigationSplitViewVisibility(storageValue: "garbage") == .all)
    }

    @Test func openPaneMemoryKeepsTheSiblingPerEntryPane() {
        let memory = OpenPaneMemory()
        #expect(memory.paneID(forEntryPane: "a") == nil)
        memory.remember("b", forEntryPane: "a")
        memory.remember("d", forEntryPane: "c")
        #expect(memory.paneID(forEntryPane: "a") == "b")
        #expect(memory.paneID(forEntryPane: "c") == "d")
        memory.remember("e", forEntryPane: "a")
        #expect(memory.paneID(forEntryPane: "a") == "e")
    }
}
