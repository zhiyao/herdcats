import AVFoundation
import Foundation
import Observation
import Speech
import UIKit

/// Owns microphone capture and ignores callbacks from a previous dictation session.
@MainActor
@Observable
final class PaneDictation: NSObject, SFSpeechRecognizerDelegate {
    private(set) var isBusy = false
    private(set) var isPreparing = false
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var modernSession: (any PaneSpeechSession)?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private var sessionID: UUID?
    private var segmentID: UUID?
    private var nextRequest: SFSpeechAudioBufferRecognitionRequest?
    private let audioRouter = DictationAudioRouter()
    private var transcript = DictationTranscript()
    private var onText: ((String) -> Void)?
    private var isFinishing = false
    private var hasTap = false
    private var audioSessionActive = false
    private var reportError: ((String) -> Void)?

#if DEBUG && targetEnvironment(simulator)
    /// Displays the recording surface for screenshots without opening a microphone.
    func showScreenshotRecording() {
        guard ScreenshotFixtures.enabled else { return }
        isBusy = true
        isPreparing = false
    }
#endif

    func start(onText: @escaping (String) -> Void,
               onError: @escaping (String) -> Void,
               initialText: () -> String) async {
        guard !isBusy else { return }
        let id = UUID()
        sessionID = id
        isBusy = true
        isPreparing = true
        reportError = onError
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard sessionID == id else { return }
        guard authorization == .authorized else {
            fail("Allow Speech Recognition for Herdcats in Settings to dictate messages.")
            return
        }
        let microphoneAllowed = await AVAudioApplication.requestRecordPermission()
        guard sessionID == id else { return }
        guard microphoneAllowed else {
            fail("Allow Microphone access for Herdcats in Settings to dictate messages.")
            return
        }
        transcript = DictationTranscript(committed: initialText())
        self.onText = onText
        isFinishing = false
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true)
            audioSessionActive = true
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                fail("No microphone is available. Check your audio input and try again.")
                return
            }
            if #available(iOS 26, *), SpeechTranscriber.isAvailable,
               let locale = await SpeechTranscriber.supportedLocale(
                   equivalentTo: recognizer?.locale ?? Locale.current) {
                guard sessionID == id else { return }
                let modern = AnalyzerDictationSession(locale: locale)
                modernSession = modern
                var modernTranscript = AnalyzerDictationTranscript(draft: transcript.text)
                do {
                    try await modern.prepare(format: format) { [weak self] text, isFinal in
                        guard let self, self.sessionID == id else { return }
                        modernTranscript.receive(text, isFinal: isFinal)
                        self.onText?(modernTranscript.text)
                    } onError: { [weak self] message in
                        guard let self, self.sessionID == id else { return }
                        self.fail(message)
                    }
                    guard sessionID == id else { modern.cancel(); return }
                    modern.installTap(on: input, format: format)
                    hasTap = true
                    engine.prepare()
                    try engine.start()
                    isPreparing = false
                    return
                } catch {
                    modern.cancel()
                    guard sessionID == id else { return }
                    modernSession = nil
                    if hasTap {
                        input.removeTap(onBus: 0)
                        hasTap = false
                    }
                    // Download/setup failures can still use the existing recognizer.
                }
            }
            guard sessionID == id else { return }
            guard let recognizer, recognizer.isAvailable else {
                fail("Speech recognition is currently unavailable. Please try again later.")
                return
            }
            recognizer.delegate = self
            let request = makeRequest()
            audioRouter.replace(with: request)
            let router = audioRouter
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                router.append(buffer)
            }
            hasTap = true
            beginRecognition(request)
            engine.prepare()
            try engine.start()
            isPreparing = false
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.taskHint = .dictation
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = recognizer?.supportsOnDeviceRecognition == true
        return request
    }

    private func beginRecognition(_ request: SFSpeechAudioBufferRecognitionRequest) {
        guard let recognizer, let sessionID else { return }
        let segmentID = UUID()
        self.segmentID = segmentID
        self.request = request
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let speechDuration = result?.speechRecognitionMetadata?.speechDuration
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == sessionID,
                      self.segmentID == segmentID else { return }
                let ended = self.transcript.receive(text, isFinal: isFinal,
                                                    speechDuration: speechDuration)
                self.onText?(self.transcript.text)
                // On-device recognition can finish an utterance after a pause without
                // marking the task final. Start a fresh request at that boundary:
                // otherwise its next hypothesis can replace the preceding sentence.
                // completeSegment invalidates this task's ID before cancellation, so
                // a late final/error callback cannot duplicate text or stop capture.
                if ended { self.completeSegment() }
                else if let message { self.fail(message) }
            }
        }
        if isFinishing {
            request.endAudio()
            awaitFinalResult()
        } else {
            // Leave room for audio buffered while the previous segment finalized.
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(40)) } catch { return }
                self?.rollover()
            }
        }
    }

    private func rollover() {
        guard !isFinishing, nextRequest == nil else { return }
        let next = makeRequest()
        nextRequest = next
        // Capture keeps running into the next request while the old task finalizes.
        audioRouter.replace(with: next)
        awaitFinalResult()
    }

    private func completeSegment() {
        timeout?.cancel()
        segmentID = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        if let next = nextRequest {
            nextRequest = nil
            beginRecognition(next)
        } else if isFinishing {
            cancel()
        } else {
            let next = makeRequest()
            audioRouter.replace(with: next)
            beginRecognition(next)
        }
    }

    /// Stop capture, then drain both the active and any buffered recognition requests.
    func finish() {
        guard !isFinishing else { return }
        if let modernSession {
            guard hasTap, let id = sessionID else { cancel(); return }
            isFinishing = true
            stopCapture()
            awaitFinalResult()
            modernSession.finish { [weak self] in
                guard let self, self.sessionID == id else { return }
                self.cancel()
            }
            return
        }
        guard request != nil else { cancel(); return }
        isFinishing = true
        stopCapture()
        audioRouter.replace(with: nil)
        awaitFinalResult()
    }

    private func awaitFinalResult() {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.fail("Dictation could not finish processing. Your recognized text has been kept; please check the last words before sending.")
        }
    }

    func cancel() {
        sessionID = nil
        segmentID = nil
        timeout?.cancel()
        timeout = nil
        stopCapture()
        modernSession?.cancel()
        modernSession = nil
        audioRouter.replace(with: nil)
        request?.endAudio()
        nextRequest?.endAudio()
        nextRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        reportError = nil
        onText = nil
        isFinishing = false
        isBusy = false
        isPreparing = false
    }

    private func stopCapture() {
        engine.stop()
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }
    }

    private func fail(_ message: String) {
        let handler = reportError
        cancel()
        handler?(message)
    }

    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer,
                                     availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.isBusy, self.modernSession == nil, !available else { return }
            self.fail("Speech recognition became unavailable. Please try again later.")
        }
    }
}

@MainActor
protocol PaneSpeechSession: AnyObject {
    func finish(onComplete: @escaping () -> Void)
    func cancel()
}

/// Analyzer results contain their own spacing, including within-word boundaries.
/// Only the boundary between the pre-existing draft and new speech needs a separator.
struct AnalyzerDictationTranscript {
    let draft: String
    private var finalized = ""
    private var volatile = ""

    init(draft: String = "") { self.draft = draft }

    var text: String {
        let speech = finalized + volatile
        guard !speech.isEmpty else { return draft }
        let separator = draft.isEmpty || draft.last?.isWhitespace == true || speech.first?.isWhitespace == true ? "" : " "
        return draft + separator + speech
    }

    mutating func receive(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized += text
            volatile = ""
        } else {
            volatile = text
        }
    }
}

/// A single continuous, on-device recognition session for supported iOS 26 devices.
@available(iOS 26, *)
@MainActor
final class AnalyzerDictationSession: PaneSpeechSession {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private var audio: AnalyzerAudioInput?
    private var resultsTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var cancelled = false
    private var onError: ((String) -> Void)?

    init(locale: Locale) {
        transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    func prepare(format: AVAudioFormat,
                 onResult: @escaping (String, Bool) -> Void,
                 onError: @escaping (String) -> Void) async throws {
        self.onError = onError
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            guard !cancelled else { throw CancellationError() }
            try await installation.downloadAndInstall()
        }
        guard !cancelled else { throw CancellationError() }
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw CocoaError(.featureUnsupported)
        }
        guard !cancelled else { throw CancellationError() }
        let audio = try AnalyzerAudioInput(source: format, target: target)
        self.audio = audio
        try await analyzer.prepareToAnalyze(in: target)
        guard !cancelled else { throw CancellationError() }
        try await analyzer.start(inputSequence: audio.stream)
        guard !cancelled else { throw CancellationError() }
        resultsTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    guard let self, !self.cancelled, !Task.isCancelled else { return }
                    onResult(String(result.text.characters), result.isFinal)
                }
            } catch {
                guard let self, !self.cancelled, !Task.isCancelled else { return }
                self.onError?(error.localizedDescription)
            }
        }
    }

    func installTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        guard let audio else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            audio.append(buffer)
        }
    }

    func finish(onComplete: @escaping () -> Void) {
        audio?.finish()
        finishTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.analyzer.finalizeAndFinishThroughEndOfInput()
                // Finalization can return before the UI has consumed the last result.
                await self.resultsTask?.value
                guard !self.cancelled, !Task.isCancelled else { return }
                onComplete()
            } catch {
                guard !self.cancelled, !Task.isCancelled else { return }
                self.onError?(error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        audio?.finish()
        resultsTask?.cancel()
        finishTask?.cancel()
        onError = nil
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }
}

/// Conversion runs serially under the lock. Each yielded buffer owns its samples;
/// the audio engine's borrowed tap buffer never escapes the callback.
@available(iOS 26, *)
final class AnalyzerAudioInput: @unchecked Sendable {
    let stream: AsyncThrowingStream<AnalyzerInput, Error>
    private let continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let lock = NSLock()
    private var ended = false

    init(source: AVAudioFormat, target: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw CocoaError(.featureUnsupported)
        }
        self.converter = converter
        // Live buffers are contiguous; don't add converter priming at the boundaries.
        converter.primeMethod = .none
        self.target = target
        (stream, continuation) = AsyncThrowingStream.makeStream(of: AnalyzerInput.self)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            ended = true
            continuation.finish(throwing: CocoaError(.coderInvalidValue))
            return
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            ended = true
            continuation.finish(throwing: error ?? CocoaError(.coderInvalidValue) as NSError)
        } else if output.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: output))
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return }
        ended = true
        continuation.finish()
    }
}

/// Partial hypotheses replace only the current segment, never earlier dictation.
struct DictationTranscript {
    private(set) var committed = ""
    private var partial = ""

    init(committed: String = "") { self.committed = committed }

    var text: String {
        guard !partial.isEmpty else { return committed }
        let separator = committed.isEmpty || committed.last?.isWhitespace == true ? "" : " "
        return committed + separator + partial
    }

    mutating func update(_ text: String) { partial = text }

    /// Returns true when the owner must retire this recognition request. A positive
    /// speech duration is an utterance boundary even when `isFinal` remains false.
    /// Retiring the request also prevents cumulative/duplicate callbacks from being
    /// mistaken for the next utterance. The microphone stays running across requests.
    mutating func receive(_ text: String?, isFinal: Bool,
                          speechDuration: TimeInterval? = nil) -> Bool {
        if let text, !text.isEmpty { update(text) }
        let ended = isFinal || (speechDuration ?? 0) > 0
        if ended { commit() }
        return ended
    }

    mutating func commit() {
        committed = text
        partial = ""
    }
}

/// Serializes tap delivery with request handoff so no buffer reaches an ended request.
final class DictationAudioRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        request?.append(buffer)
    }

    func replace(with next: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        defer { lock.unlock() }
        request?.endAudio()
        request = next
    }
}
