import AVFoundation
import Foundation
import OSLog
import Speech

private let transcriptionLog = Logger(subsystem: "io.grimso.Begleiter", category: "speech.transcription")

/// On-device German speech-to-text using Apple's iOS 26 `SpeechAnalyzer` +
/// `SpeechTranscriber`. Replaces WhisperKit on the principle that "100%
/// native iOS speech APIs" is a stronger privacy/architecture claim than
/// "shipped a third-party ASR model" AND avoids the ~150 MB extra resident
/// memory pressure (the Gemma 4 budget on iPhone 14 Pro is already tight).
///
/// Lifecycle:
/// 1. `prepare()` — checks that the German locale model is installed; if
///    not, asks `AssetInventory` to download it (shows the system prompt).
///    Must succeed before `start(...)` will produce useful results.
/// 2. `start(audioStream:)` — wires the analyzer to the parent's audio
///    buffer stream from `AudioRecorder` and begins emitting results.
/// 3. `partialResults` / `finalResult` async streams — UI subscribes.
/// 4. `stop()` — flushes pending audio, returns the final transcript.
@available(iOS 26.0, *)
actor TranscriptionService {

    enum TranscriptionError: Error, LocalizedError {
        case germanModelUnavailable
        case permissionDenied
        case analyzerFailed(String)

        var errorDescription: String? {
            switch self {
            case .germanModelUnavailable:
                return "Das deutsche Sprachmodell konnte nicht geladen werden."
            case .permissionDenied:
                return "Die Spracherkennung benötigt die Berechtigung."
            case .analyzerFailed(let detail):
                return "Transkription fehlgeschlagen: \(detail)"
            }
        }
    }

    enum PrepareState: Sendable, Equatable {
        case unknown
        case downloadingModel(progress: Double)
        case ready
        case failed(String)
    }

    private(set) var prepareState: PrepareState = .unknown

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?

    /// Stream of partial transcripts (volatile — best-guess updated as more
    /// audio arrives). UI uses this for live preview during recording.
    var partialTextStream: AsyncStream<String> { _partialStream }
    /// Stream of finalized segment transcripts (committed — won't change).
    /// UI concatenates these for the persisted transcript.
    var finalTextStream: AsyncStream<String> { _finalStream }

    private let _partialStream: AsyncStream<String>
    private let _partialContinuation: AsyncStream<String>.Continuation
    private let _finalStream: AsyncStream<String>
    private let _finalContinuation: AsyncStream<String>.Continuation
    private var resultsTask: Task<Void, Never>?

    init() {
        var partialCont: AsyncStream<String>.Continuation!
        self._partialStream = AsyncStream { cont in partialCont = cont }
        self._partialContinuation = partialCont

        var finalCont: AsyncStream<String>.Continuation!
        self._finalStream = AsyncStream { cont in finalCont = cont }
        self._finalContinuation = finalCont
    }

    // MARK: - Prepare (ensure German model is installed)

    /// Verify (and if needed, download) the German on-device speech model.
    /// Safe to call multiple times — no-op if already ready.
    func prepare() async throws {
        if case .ready = prepareState { return }

        // Resolve the canonical Locale form Apple uses internally — turns
        // "de-DE" / "de_DE" into whatever LocaleDependentSpeechModule's
        // catalogue expects. Returns `nil` if German is not supportable at
        // all on this device (very unlikely on iOS 26).
        let requested = Locale(identifier: "de-DE")
        guard let canonical = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            prepareState = .failed("German not supported on this device")
            throw TranscriptionError.germanModelUnavailable
        }
        transcriptionLog.info("canonical German locale: \(canonical.identifier(.bcp47), privacy: .public)")

        let candidate = SpeechTranscriber(
            locale: canonical,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        // Ensure the model is downloaded.
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [candidate]) {
                transcriptionLog.info("downloading German speech model")
                prepareState = .downloadingModel(progress: 0)
                try await request.downloadAndInstall()
            }
        } catch {
            prepareState = .failed(error.localizedDescription)
            throw TranscriptionError.analyzerFailed(error.localizedDescription)
        }

        self.transcriber = candidate
        prepareState = .ready
        transcriptionLog.info("German speech model ready")
    }

    // MARK: - Streaming session

    /// Begin a transcription session against a live audio stream. Caller
    /// must drive the stream from `AudioRecorder.audioBuffers`. The
    /// session ends when the caller calls `stop()` or the audio stream
    /// terminates.
    func start(audioStream: AsyncStream<AnalyzerInput>) async throws {
        try await prepare()
        guard let transcriber else {
            throw TranscriptionError.germanModelUnavailable
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: audioStream)

        // Drain results in the background; route to partial/final streams.
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        await self.emitFinal(text)
                    } else {
                        await self.emitPartial(text)
                    }
                }
            } catch {
                transcriptionLog.error("results stream error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Stop the session and tear down the analyzer. Idempotent.
    func stop() async {
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
    }

    // MARK: - Internals

    private func emitPartial(_ text: String) {
        _partialContinuation.yield(text)
    }

    private func emitFinal(_ text: String) {
        _finalContinuation.yield(text)
    }
}
