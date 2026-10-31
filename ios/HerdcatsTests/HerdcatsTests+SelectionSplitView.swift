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
}
