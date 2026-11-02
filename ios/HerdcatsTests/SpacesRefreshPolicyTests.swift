import Foundation
import Testing
@testable import Herdcats

struct SpacesRefreshPolicyTests {
    @Test func tuiPollsEveryFiveSeconds() {
        #expect(SpacesRefreshPolicy.interval(isCoreMode: false, eventsOpen: false) == 5)
        #expect(SpacesRefreshPolicy.interval(isCoreMode: false, eventsOpen: true) == 5)
    }

    @Test func coreWithOpenEventsFallsBackToSlowSafetyRefresh() {
        #expect(SpacesRefreshPolicy.interval(isCoreMode: true, eventsOpen: true) == 60)
    }

    @Test func coreWithClosedEventsPollsEveryFiveSeconds() {
        #expect(SpacesRefreshPolicy.interval(isCoreMode: true, eventsOpen: false) == 5)
    }

    @Test func intervalIsDueOnceElapsedReachesIt() {
        #expect(SpacesRefreshPolicy.isDue(elapsed: 5, interval: 5))
        #expect(!SpacesRefreshPolicy.isDue(elapsed: 55, interval: 60))
        #expect(SpacesRefreshPolicy.isDue(elapsed: 60, interval: 60))
        // Events dropped mid-wait: the shorter interval is due immediately.
        #expect(SpacesRefreshPolicy.isDue(elapsed: 10, interval: 5))
    }

    @Test func freshConnectionReportsCoreEventsClosed() async {
        #expect(await HerdrConnection().coreEventsOpen == false)
    }
}
