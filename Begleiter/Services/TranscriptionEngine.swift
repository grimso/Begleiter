import AVFoundation
import Foundation
import OSLog
import Speech

private let engineLog = Logger(subsystem: "io.grimso.Begleiter", category: "speech.engine")

/// Abstract transcription backend. Two implementations:
/// - `AppleSFSpeechEngine` — `SFSpeechRecognizer` on a real device.
/// - `MockTranscriptionEngine` — hardcoded transcript, for simulator
///   builds and unit tests.
///
/// The protocol exists so `VoiceRecorderViewModel` can be tested on the
/// simulator (where the microphone and Apple's Speech daemon aren't
/// available) and so we have a clean cancellation surface — every method
/// is `async` and respects task cancellation.
protocol TranscriptionEngine: Actor {
    /// Volatile transcripts — best-guess updates while audio keeps arriving.
    nonisolated var partialResults: AsyncStream<String> { get }
    /// Finalized segment transcripts — committed, won't change.
    nonisolated var finalResults: AsyncStream<String> { get }

    /// Verify (and if needed, request) authorization. Idempotent.
    /// Throws `TranscriptionEngineError.permissionDenied` if denied.
    func prepare() async throws

    /// Start a transcription session against the given mic audio buffer
    /// stream. Caller drives buffers via `AudioRecorder.bufferStream`.
    /// Results appear on `partialResults` / `finalResults`.
    func start(audioStream: AsyncStream<AVAudioPCMBuffer>) async throws

    /// Stop the session and finalize. Idempotent.
    func stop() async
}

enum TranscriptionEngineError: Error, LocalizedError {
    case permissionDenied
    case recognizerUnavailable
    case onDeviceUnavailable
    case engineFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Spracherkennung wurde verweigert. Bitte in den Einstellungen erlauben."
        case .recognizerUnavailable:
            return "Spracherkennung für Deutsch ist auf diesem Gerät nicht verfügbar."
        case .onDeviceUnavailable:
            return "On-Device-Spracherkennung ist auf diesem Gerät nicht verfügbar."
        case .engineFailed(let detail):
            return "Spracherkennung fehlgeschlagen: \(detail)"
        case .timedOut:
            return "Spracherkennung antwortet nicht (Zeitüberschreitung)."
        }
    }
}

// MARK: - Apple SFSpeechRecognizer implementation

/// `SFSpeechRecognizer`-backed engine.
///
/// Chosen over iOS 26 `SpeechAnalyzer` after the AssetInventory pipeline
/// hung on iPhone 14 Pro / iOS 26.4.2. SFSpeechRecognizer has shipped since
/// iOS 10, on-device since iOS 14, and doesn't go through `AssetInventory`
/// (German model is bundled with the system).
actor AppleSFSpeechEngine: TranscriptionEngine {
    nonisolated let partialResults: AsyncStream<String>
    nonisolated let finalResults: AsyncStream<String>
    private let partialContinuation: AsyncStream<String>.Continuation
    private let finalContinuation: AsyncStream<String>.Continuation

    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var pumpTask: Task<Void, Never>?

    init() {
        var partialCont: AsyncStream<String>.Continuation!
        self.partialResults = AsyncStream { cont in partialCont = cont }
        self.partialContinuation = partialCont
        var finalCont: AsyncStream<String>.Continuation!
        self.finalResults = AsyncStream { cont in finalCont = cont }
        self.finalContinuation = finalCont

        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))
    }

    func prepare() async throws {
        guard let recognizer else {
            throw TranscriptionEngineError.recognizerUnavailable
        }
        guard recognizer.isAvailable else {
            throw TranscriptionEngineError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionEngineError.onDeviceUnavailable
        }

        // Request authorization, awaiting completion via continuation.
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        switch status {
        case .authorized: break
        case .denied, .restricted, .notDetermined: throw TranscriptionEngineError.permissionDenied
        @unknown default: throw TranscriptionEngineError.permissionDenied
        }
        engineLog.info("SFSpeechRecognizer authorized + on-device available")
    }

    func start(audioStream: AsyncStream<AVAudioPCMBuffer>) async throws {
        guard let recognizer else {
            throw TranscriptionEngineError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        // Subscribe to results BEFORE feeding buffers, so we don't miss
        // any early callbacks.
        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    Task { await self.emitFinal(text) }
                } else {
                    Task { await self.emitPartial(text) }
                }
            }
            if let error {
                engineLog.error("recognition error: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Pump audio buffers into the recognition request. Runs until the
        // audio stream finishes or this task is cancelled.
        pumpTask = Task { [request] in
            for await buffer in audioStream {
                if Task.isCancelled { break }
                request.append(buffer)
            }
        }
    }

    func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
    }

    private func emitPartial(_ text: String) {
        partialContinuation.yield(text)
    }

    private func emitFinal(_ text: String) {
        finalContinuation.yield(text)
    }
}

// MARK: - Mock implementation (simulator + unit tests)

/// Produces a hardcoded German transcript on a delay so the UI flow can be
/// exercised on the simulator (no microphone, no Speech daemon). Each
/// `start(...)` emits a few partial updates over ~1 second then a single
/// final transcript. Ignores the actual audio buffers entirely.
actor MockTranscriptionEngine: TranscriptionEngine {
    nonisolated let partialResults: AsyncStream<String>
    nonisolated let finalResults: AsyncStream<String>
    private let partialContinuation: AsyncStream<String>.Continuation
    private let finalContinuation: AsyncStream<String>.Continuation

    /// What the mock emits as the final transcript. Overridable for tests
    /// that want to drive specific scenarios.
    var scriptedTranscript: String = "Heute Vincristin bekommen, ANC ist 0.8, alles ruhig."
    /// Override prepare()'s behaviour for failure-path tests.
    var prepareError: (any Error)?

    private var streamingTask: Task<Void, Never>?

    init(scripted: String = "Heute Vincristin bekommen, ANC ist 0.8, alles ruhig.") {
        var partialCont: AsyncStream<String>.Continuation!
        self.partialResults = AsyncStream { cont in partialCont = cont }
        self.partialContinuation = partialCont
        var finalCont: AsyncStream<String>.Continuation!
        self.finalResults = AsyncStream { cont in finalCont = cont }
        self.finalContinuation = finalCont
        self.scriptedTranscript = scripted
    }

    func setScriptedTranscript(_ text: String) { scriptedTranscript = text }
    func setPrepareError(_ error: (any Error)?) { prepareError = error }

    func prepare() async throws {
        if let prepareError { throw prepareError }
        // Tiny delay so the UI's "preparing" state is briefly observable
        // in the simulator.
        try? await Task.sleep(for: .milliseconds(200))
    }

    func start(audioStream: AsyncStream<AVAudioPCMBuffer>) async throws {
        // Drive the canned transcript on a background task. We still want
        // the audioStream to drain (so AudioRecorder's continuation doesn't
        // back-pressure forever) — but only read it, don't react.
        streamingTask = Task {
            // Drain audio in background.
            Task { for await _ in audioStream { if Task.isCancelled { break } } }

            // Emit partial slices of the scripted transcript over ~1s,
            // then the final.
            let parts = self.scriptedTranscript.split(separator: " ").map(String.init)
            var building = ""
            for (i, word) in parts.enumerated() {
                if Task.isCancelled { return }
                building = building.isEmpty ? word : building + " " + word
                self.partialContinuation.yield(building)
                let delayMs = max(100, 1000 / max(1, parts.count - 1))
                if i < parts.count - 1 {
                    try? await Task.sleep(for: .milliseconds(delayMs))
                }
            }
            if !Task.isCancelled {
                self.finalContinuation.yield(self.scriptedTranscript)
            }
        }
    }

    func stop() async {
        streamingTask?.cancel()
        streamingTask = nil
    }
}

// MARK: - Default engine selection

/// Pick the right engine for the current build configuration.
/// - Simulator: `MockTranscriptionEngine` (no microphone, no Speech daemon)
/// - Device:    `AppleSFSpeechEngine`
///
/// Returned as `any TranscriptionEngine` so callers don't need to know
/// which one they got.
enum DefaultTranscriptionEngine {
    static func make() -> any TranscriptionEngine {
        #if targetEnvironment(simulator)
        return MockTranscriptionEngine()
        #else
        return AppleSFSpeechEngine()
        #endif
    }
}
