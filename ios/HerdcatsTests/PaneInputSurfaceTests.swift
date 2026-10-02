import Testing
@testable import Herdcats

/// Transition coverage for the pane input surface state machine that replaces
/// the Compose/Live segmented control: keyboard opens Compose directly, Voice
/// opens recording, and tapping output collapses Compose back to Live.
@Suite("Pane input surface state machine")
@MainActor
struct PaneInputSurfaceTests {
    @Test func liveToolbarIsTheDefaultSurface() {
        let model = PaneInputSurfaceModel()
        #expect(model.surface == .liveToolbar)
        #expect(model.isLiveKeyboardSurface)
        #expect(!model.isComposeSurface)
        #expect(!model.isDrainingDictation)
    }

    @Test func keyboardOpensComposeDirectly() {
        let model = PaneInputSurfaceModel()
        #expect(model.requestComposeDraft())
        #expect(model.surface == .composeDraft)
        #expect(!model.requestComposeDraft())
    }

    @Test func keyboardCannotInterruptRecording() {
        let model = PaneInputSurfaceModel()
        model.requestVoiceRecording()
        #expect(!model.requestComposeDraft())
        #expect(model.surface == .voiceRecording)
    }

    @Test func photoRestoresComposeAfterPickerResignsFocus() {
        let model = PaneInputSurfaceModel()
        model.requestComposeDraft()
        model.collapseToLiveToolbar()

        model.notePhotoSelected()
        #expect(model.surface == .composeDraft)

        model.notePhotoSelected()
        #expect(model.surface == .composeDraft)
    }

    @Test func photoSelectionCannotInterruptRecording() {
        let model = PaneInputSurfaceModel()
        model.requestVoiceRecording()

        model.notePhotoSelected()
        #expect(model.surface == .voiceRecording)
    }

    @Test func voiceOpensRecordingFromToolbarAndComposeBubble() {
        let model = PaneInputSurfaceModel()

        model.requestVoiceRecording()
        #expect(model.surface == .voiceRecording)

        // Dictation finishes → Compose bubble; Voice re-enters from there.
        model.noteDictationIdle()
        #expect(model.surface == .composeDraft)

        model.requestVoiceRecording()
        #expect(model.surface == .voiceRecording)
    }

    @Test func voiceWhileRecordingIsRejected() {
        let model = PaneInputSurfaceModel()
        model.requestVoiceRecording()

        model.requestVoiceRecording()
        #expect(model.surface == .voiceRecording)
        #expect(!model.isDrainingDictation)
    }

    @Test func checkmarkKeepsRecordingUntilDictationDrains() {
        let model = PaneInputSurfaceModel()
        model.requestVoiceRecording()

        // `PaneDictation.finish()` returns immediately while `isBusy` stays
        // true up to ~15s; the recording surface must survive that drain so a
        // partial transcript is never shown or sent.
        model.requestFinishDictation()
        #expect(model.isDrainingDictation)
        #expect(model.surface == .voiceRecording)

        model.noteDictationIdle()
        #expect(model.surface == .composeDraft)
        #expect(!model.isDrainingDictation)
    }

    @Test func repeatedCheckmarkTapsDuringDrainAreNoOps() {
        let model = PaneInputSurfaceModel()
        model.requestVoiceRecording()
        model.requestFinishDictation()

        model.requestFinishDictation()
        #expect(model.isDrainingDictation)
        #expect(model.surface == .voiceRecording)
    }

    @Test func dictationIdleWithoutCheckmarkStillOpensCompose() {
        // Interruptions (audio-session interruption, backgrounding) cancel
        // dictation without the checkmark; the captured draft must stay
        // visible and editable in the Compose bubble rather than vanishing
        // back to the toolbar.
        let model = PaneInputSurfaceModel()
        model.requestVoiceRecording()

        model.noteDictationIdle()
        #expect(model.surface == .composeDraft)
        #expect(!model.isDrainingDictation)
    }

    @Test func dictationIdleIsIgnoredOutsideRecording() {
        let model = PaneInputSurfaceModel()

        model.noteDictationIdle()
        #expect(model.surface == .liveToolbar)
    }

    @Test func sendSuccessReturnsToLiveToolbar() {
        let model = PaneInputSurfaceModel()
        model.requestVoiceRecording()
        model.noteDictationIdle()
        #expect(model.surface == .composeDraft)

        model.noteSendSucceeded()
        #expect(model.surface == .liveToolbar)
    }

    @Test func sendSuccessIsIgnoredOutsideCompose() {
        let model = PaneInputSurfaceModel()

        model.noteSendSucceeded()
        #expect(model.surface == .liveToolbar)

        model.requestVoiceRecording()
        model.noteSendSucceeded()
        #expect(model.surface == .voiceRecording)
    }

    @Test func collapseReturnsToLiveToolbarWithoutSending() {
        let model = PaneInputSurfaceModel()
        model.requestVoiceRecording()
        model.noteDictationIdle()

        model.collapseToLiveToolbar()
        #expect(model.surface == .liveToolbar)
    }

    @Test func collapseIsIgnoredOutsideCompose() {
        let model = PaneInputSurfaceModel()
        model.requestVoiceRecording()

        model.collapseToLiveToolbar()
        #expect(model.surface == .voiceRecording)
    }

    @Test func paneResetClearsSurfaceAndDrain() {
        let model = PaneInputSurfaceModel()
        model.requestVoiceRecording()
        model.requestFinishDictation()

        model.resetToLiveToolbar()
        #expect(model.surface == .liveToolbar)
        #expect(!model.isDrainingDictation)
    }
}
