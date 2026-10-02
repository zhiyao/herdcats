import Foundation
import Testing
@testable import Herdcats

@Suite("Continuous analyzer dictation")
struct AnalyzerDictationTranscriptTests {
    @Test func revisionsReplaceOnlyVolatileText() {
        var transcript = AnalyzerDictationTranscript(draft: "Existing draft.")
        transcript.receive("Send on Monday", isFinal: false)
        transcript.receive("Send on Tuesday.", isFinal: true)
        transcript.receive(" Next sent", isFinal: false)
        transcript.receive(" Next sentence.", isFinal: false)
        #expect(transcript.text == "Existing draft. Send on Tuesday. Next sentence.")
        transcript.receive(" Next sentence.", isFinal: true)
        #expect(transcript.text == "Existing draft. Send on Tuesday. Next sentence.")
    }

    @Test func preservesModelSpacingAcrossFinalBoundaries() {
        var transcript = AnalyzerDictationTranscript()
        transcript.receive("你", isFinal: true)
        transcript.receive("好", isFinal: true)
        transcript.receive("。", isFinal: true)
        #expect(transcript.text == "你好。")
    }

    @Test func emptyFinalRemovesRetractedHypothesis() {
        var transcript = AnalyzerDictationTranscript(draft: "Draft\n")
        transcript.receive("Keep this.", isFinal: true)
        transcript.receive(" discarded guess", isFinal: false)
        transcript.receive("", isFinal: true)
        #expect(transcript.text == "Draft\nKeep this.")
    }

    @Test func preservesDraftWhenNoSpeechArrives() {
        var transcript = AnalyzerDictationTranscript(draft: "Unchanged draft")
        transcript.receive("", isFinal: true)
        #expect(transcript.text == "Unchanged draft")
    }
}

@Suite("Pane command history")
struct PaneCommandHistoryTests {
    @Test func recordsNewestFirstAndDedupes() {
        var raw = "[]"
        PaneCommandHistory.record("first", into: &raw)
        PaneCommandHistory.record("second", into: &raw)
        PaneCommandHistory.record("first", into: &raw)
        #expect(PaneCommandHistory.load(from: raw) == ["first", "second"])
    }

    @Test func ignoresBlankEntries() {
        var raw = "[]"
        PaneCommandHistory.record("  ", into: &raw)
        PaneCommandHistory.record("\n", into: &raw)
        #expect(PaneCommandHistory.load(from: raw).isEmpty)
    }

    @Test func capsAtMaxEntries() {
        var raw = "[]"
        for index in 0..<(PaneCommandHistory.maxEntries + 5) {
            PaneCommandHistory.record("cmd-\(index)", into: &raw)
        }
        let items = PaneCommandHistory.load(from: raw)
        #expect(items.count == PaneCommandHistory.maxEntries)
        #expect(items.first == "cmd-\(PaneCommandHistory.maxEntries + 4)")
        #expect(items.last == "cmd-5")
    }
}
