import AVFoundation
import Foundation
import SwiftUI

/// View model for the modal voice-recording sheet.
///
/// Owns:
/// - a `TranscriptionEngine` (Apple SFSpeechRecognizer on device, mock on
///   simulator and in unit tests),
/// - an `AudioRecorder` that captures mic audio + writes the .m4a file.
///
/// Lifecycle is a small state machine and every async operation runs in a
/// child `Task` so the **Abbrechen** button always works — even mid-prepare.
/// `prepare()` is wrapped in a 30s timeout so we never hang on a backend
/// that misbehaves.
@MainActor
@Observable
final class VoiceRecorderViewModel {
    enum Phase: Equatable {
        case idle
        case preparing
        case recording
        case stopped
        case failed(String)
    }

    var phase: Phase = .idle
    /// Live (volatile) partial transcript shown while recording.
    var partialText: String = ""
    /// Accumulated finalized segments. This is what gets handed back to
    /// `CaptureView` when the parent taps "Übernehmen".
    var finalText: String = ""
    /// File URL of the recording (set after recording starts). Caller uses
    /// `.lastPathComponent` for the JournalEntry's
    /// `rawVoiceAudioFilename`.
    private(set) var recordingURL: URL?

    private let entryId: UUID
    private let recorder: AudioRecorder
    private let engine: any TranscriptionEngine

    private var prepareTask: Task<Void, Never>?
    private var partialTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?

    init(
        entryId: UUID = UUID(),
        recorder: AudioRecorder = AudioRecorder(),
        engine: any TranscriptionEngine = DefaultTranscriptionEngine.make()
    ) {
        self.entryId = entryId
        self.recorder = recorder
        self.engine = engine
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    /// Final segments + the trailing partial. UI displays this.
    var displayedTranscript: String {
        let combined = finalText
        if !partialText.isEmpty {
            return combined.isEmpty
                ? partialText
                : combined + " " + partialText
        }
        return combined
    }

    // MARK: - Start

    /// Begin preparation, model download (if needed), mic capture, and
    /// transcription. All in a single child Task that the cancel button
    /// can interrupt.
    func startRecording() {
        guard phase == .idle || phase == .stopped else { return }
        partialText = ""
        finalText = ""
        recordingURL = nil
        phase = .preparing

        prepareTask = Task { [engine, recorder, entryId] in
            do {
                // 1. Authorise + ready the recognizer. Wrap in a timeout
                //    so a hung Apple API doesn't freeze the UI forever.
                try await Self.withTimeout(.seconds(30)) {
                    try await engine.prepare()
                }
                try Task.checkCancellation()

                // 2. Start mic capture; gives us the audio buffer stream.
                let url = try await recorder.start(entryId: entryId)
                try Task.checkCancellation()
                await MainActor.run {
                    self.recordingURL = url
                }

                guard let bufferStream = await recorder.bufferStream else {
                    throw TranscriptionEngineError.engineFailed("audio stream missing")
                }

                // 3. Hand the buffer stream to the recognizer.
                try await engine.start(audioStream: bufferStream)
                try Task.checkCancellation()

                // 4. Subscribe to result streams.
                let partialStream = engine.partialResults
                let finalStream = engine.finalResults
                await MainActor.run {
                    self.partialTask = Task { @MainActor in
                        for await text in partialStream {
                            self.partialText = text
                        }
                    }
                    self.finalTask = Task { @MainActor in
                        for await text in finalStream {
                            self.partialText = ""
                            self.finalText = self.finalText.isEmpty
                                ? text
                                : self.finalText + " " + text
                        }
                    }
                    self.phase = .recording
                }
            } catch is CancellationError {
                // Cancel button was tapped during prepare/start. Clean up.
                await self.teardown(reason: nil)
            } catch {
                await self.teardown(reason: error.localizedDescription)
            }
        }
    }

    // MARK: - Stop

    func stopRecording() {
        guard case .recording = phase else { return }
        Task {
            await engine.stop()
            _ = await recorder.stop()
            partialTask?.cancel(); partialTask = nil
            finalTask?.cancel(); finalTask = nil
            // Promote any trailing partial into final so nothing the
            // parent saw on screen is lost.
            if !partialText.isEmpty {
                finalText = finalText.isEmpty ? partialText : finalText + " " + partialText
                partialText = ""
            }
            phase = .stopped
        }
    }

    /// Cancel — works from any phase. Used by the "Abbrechen" button.
    /// Safe to call repeatedly.
    func cancel() {
        prepareTask?.cancel(); prepareTask = nil
        Task {
            await teardown(reason: nil)
        }
    }

    // MARK: - Internals

    private func teardown(reason: String?) async {
        await engine.stop()
        _ = await recorder.stop()
        partialTask?.cancel(); partialTask = nil
        finalTask?.cancel(); finalTask = nil
        partialText = ""
        finalText = ""
        recordingURL = nil
        if let reason {
            phase = .failed(reason)
        } else {
            phase = .idle
        }
    }

    /// Run an async block, throwing `TranscriptionEngineError.timedOut`
    /// if it doesn't complete within `duration`. The inner task is
    /// cancelled when the timeout fires.
    private static func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw TranscriptionEngineError.timedOut
            }
            guard let value = try await group.next() else {
                throw TranscriptionEngineError.timedOut
            }
            group.cancelAll()
            return value
        }
    }
}
