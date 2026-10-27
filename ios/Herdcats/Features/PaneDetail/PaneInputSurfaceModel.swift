import Foundation
import Observation
import SwiftUI
import UIKit

// MARK: - Pending pane attachment

struct PendingPaneAttachment: Identifiable {
    let id: UUID
    let paneId: String
    let preview: UIImage
    let imageData: Data
    let fileExtension: String
    var remotePath: String?
    var uploadError: String?
    var isUploading: Bool

    func with(remotePath: String?, uploadError: String?, isUploading: Bool) -> PendingPaneAttachment {
        PendingPaneAttachment(
            id: id,
            paneId: paneId,
            preview: preview,
            imageData: imageData,
            fileExtension: fileExtension,
            remotePath: remotePath,
            uploadError: uploadError,
            isUploading: isUploading
        )
    }
}

// MARK: - Pane input surface model

@MainActor
@Observable
final class PaneInputSurfaceModel {
    enum Surface: Equatable {
        case liveToolbar
        case voiceRecording
        case composeDraft
    }

    private(set) var surface: Surface = .liveToolbar
    private var composeVisibleByDefault = false

    /// Applies the saved default without interrupting recording or discarding a draft.
    func setComposeVisibleByDefault(_ visible: Bool) {
        composeVisibleByDefault = visible
        if visible, surface == .liveToolbar {
            surface = .composeDraft
        }
    }
    /// True after the recording bar's checkmark stops capture and while final
    /// recognition drains — `PaneDictation.finish()` returns immediately but
    /// `isBusy` stays true up to ~15s until the final transcript lands. The
    /// recording surface must stay mounted and inert during the drain so an
    /// incomplete transcript is never shown or sent.
    private(set) var isDrainingDictation = false
    /// Set by the recording bar's Send action: the drained transcript is sent
    /// instead of opening the Compose bubble for editing.
    private(set) var sendsWhenDictationDone = false
    private var surfaceBeforeVoice: Surface = .liveToolbar

    var isLiveKeyboardSurface: Bool { surface == .liveToolbar }
    var isComposeSurface: Bool { surface == .composeDraft }

    /// Direct entry from the Live toolbar keeps any existing pane draft.
    @discardableResult
    func requestComposeDraft() -> Bool {
        guard surface == .liveToolbar else { return false }
        surface = .composeDraft
        return true
    }

    /// The photo picker can resign Compose focus and return to Live before its
    /// image finishes loading. A selected photo always restores Compose.
    func notePhotoSelected() {
        guard surface != .voiceRecording else { return }
        surface = .composeDraft
    }

    /// Voice starts from the toolbar, or again from inside the Compose bubble,
    /// merging the new transcript into the existing pane-scoped draft (the
    /// merge itself is `PaneDictation`'s `initialText` behavior).
    func requestVoiceRecording() {
        guard surface != .voiceRecording else { return }
        surfaceBeforeVoice = surface
        surface = .voiceRecording
        isDrainingDictation = false
        sendsWhenDictationDone = false
    }

    /// The recording bar's cancel action: return to the surface Voice started
    /// from. The caller restores the pre-recording draft. Returns false
    /// outside the recording surface.
    @discardableResult
    func cancelVoiceRecording() -> Bool {
        guard surface == .voiceRecording else { return false }
        surface = surfaceBeforeVoice
        isDrainingDictation = false
        sendsWhenDictationDone = false
        return true
    }

    /// The recording bar's Stop (or Send) action: stop capture. Returns false (and
    /// does nothing) for repeat taps or taps outside the recording surface.
    /// The surface stays `.voiceRecording` (draining) until dictation reports
    /// idle; `PaneDictation` delivers its final `onText` (full merged
    /// transcript, prior draft included) on the main actor *before* `isBusy`
    /// clears, so opening the Compose bubble on idle can never surface a
    /// partial transcript.
    @discardableResult
    func requestFinishDictation(sendWhenDone: Bool = false) -> Bool {
        guard surface == .voiceRecording, !isDrainingDictation else { return false }
        isDrainingDictation = true
        sendsWhenDictationDone = sendWhenDone
        return true
    }

    /// `isBusy` became false — successful drain, error, timeout, or
    /// interruption alike. Opening the bubble on error and timeout too is
    /// deliberate: the captured draft stays visible, editable, and unsent,
    /// and the existing dictation error alert reports what went wrong.
    /// Returns true when the caller should send the drained draft now —
    /// only after Send, and never after a failure.
    @discardableResult
    func noteDictationIdle(failed: Bool = false) -> Bool {
        guard surface == .voiceRecording else { return false }
        let send = sendsWhenDictationDone && !failed
        isDrainingDictation = false
        sendsWhenDictationDone = false
        surface = .composeDraft
        return send
    }

    /// Send success returns to the preferred idle surface. Failures never call this,
    /// so the bubble (with its retained draft and attachment) stays up for a
    /// retry alongside the existing error banner.
    func noteSendSucceeded() {
        guard surface == .composeDraft else { return }
        surface = composeVisibleByDefault ? .composeDraft : .liveToolbar
    }

    /// Explicit collapse from the Compose bubble back to the Live toolbar
    /// without sending. The pane-scoped draft is preserved untouched.
    func collapseToLiveToolbar() {
        guard surface == .composeDraft else { return }
        surface = .liveToolbar
    }

    /// Pane switches and view teardown reset to the preferred default surface.
    func resetToDefaultSurface() {
        surface = composeVisibleByDefault ? .composeDraft : .liveToolbar
        isDrainingDictation = false
        sendsWhenDictationDone = false
    }
}

extension PaneInputSurfaceModel.Surface {
    /// Visual mode of `PaneVoiceComposeBar` for this surface.
    var barMode: PaneVoiceComposeBarMode {
        switch self {
        case .liveToolbar: .live
        case .voiceRecording: .recording
        case .composeDraft: .compose
        }
    }
}

extension PaneAttachmentInfo {
    init(_ pending: PendingPaneAttachment) {
        self.init(
            id: pending.id,
            preview: pending.preview,
            remotePath: pending.remotePath,
            uploadError: pending.uploadError,
            isUploading: pending.isUploading
        )
    }
}

/// DEBUG-only aggregate Live diagnostics formatting, kept by the pane wiring
/// so `PaneVoiceComposeBar` stays a pure visual component. Durations,
/// depths, and counts only — no text, output, host, pane, machine, or
/// credential data. `outΔ` is the acknowledgement → next changed read
/// duration, a proxy for echo.
enum PaneLiveDiagnostics {
    static func summaryLine(for summary: PaneLiveInputMetricsSummary) -> String {
        func fmt(_ percentiles: PaneLiveInputMetricPercentiles) -> String {
            guard let p50 = percentiles.p50Millis, let p95 = percentiles.p95Millis else {
                return "n/a"
            }
            return "p50\(Int(p50.rounded()))ms p95\(Int(p95.rounded()))ms n\(percentiles.sampleCount)"
        }
        return "ack \(fmt(summary.enqueueToAck)) · outΔ \(fmt(summary.ackToOutputChange)) · "
            + "depth \(summary.maxQueueDepth) · "
            + "timeouts \(summary.timeoutCount) · fails \(summary.failureCount) · "
            + "dropped \(summary.discardedEventCount)"
    }
}
