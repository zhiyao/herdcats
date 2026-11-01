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

    @Test func openPaneMemoryKeepsTheSiblingOfTheSelectedItem() {
        let memory = OpenPaneMemory()
        let slot = OpenPaneSlot(memory: memory, selection: "a")
        #expect(slot.paneID == nil)
        slot.remember("b")
        #expect(slot.paneID == "b")
        // Another selection neither sees nor keeps it.
        #expect(OpenPaneSlot(memory: memory, selection: "c").paneID == nil)
        OpenPaneSlot(memory: memory, selection: "c").remember("d")
        #expect(slot.paneID == nil)
    }

    @Test func openPaneMemoryIsClearedWhenBackingOut() {
        let memory = OpenPaneMemory()
        let slot = OpenPaneSlot(memory: memory, selection: "a")
        slot.remember("b")
        memory.forget()
        #expect(slot.paneID == nil)
    }
}
