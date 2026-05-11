import Foundation
import SwiftUI

/// View model for the modal voice-recording sheet.
///
/// Wires together `AudioRecorder` (mic capture + file write) and
/// `TranscriptionService` (Apple SpeechAnalyzer). One mic tap drives both:
/// the same `AVAudioBuffer` is written to disk for replay AND yielded to
/// the transcriber as `AnalyzerInput`.
@available(iOS 26.0, *)
@MainActor
@Observable
final class VoiceRecorderViewModel {
    enum Phase: Equatable {
        case idle
        case preparingModel(progress: Double)
        case recording
        case stopped
        case failed(String)
    }

    var phase: Phase = .idle
    /// Live (volatile) partial transcript shown while recording.
    var partialText: String = ""
    /// Accumulated finalized segments, joined with spaces. This is what
    /// gets handed back to `CaptureView` when the parent taps "Übernehmen".
    var finalText: String = ""
    /// File URL of the recording (set after `start()`). Caller uses
    /// `.lastPathComponent` for the JournalEntry's
    /// `rawVoiceAudioFilename`.
    private(set) var recordingURL: URL?

    private let entryId: UUID
    private let recorder = AudioRecorder()
    private let transcription = TranscriptionService()
    private var partialTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?

    init(entryId: UUID = UUID()) {
        self.entryId = entryId
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    /// Convenience: the transcript the parent should see right now — final
    /// segments plus the trailing partial (which is volatile).
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

    func startRecording() {
        guard phase == .idle || phase == .stopped else { return }
        partialText = ""
        finalText = ""
        recordingURL = nil
        phase = .preparingModel(progress: 0)

        Task {
            do {
                // 1. Make sure the German model is installed.
                try await transcription.prepare()

                // 2. Start mic capture; gives us the audio buffer stream.
                let url = try await recorder.start(entryId: entryId)
                recordingURL = url

                guard let bufferStream = await recorder.bufferStream else {
                    throw TranscriptionService.TranscriptionError.analyzerFailed("audio stream missing")
                }

                // 3. Wire the buffers into the transcriber.
                try await transcription.start(audioStream: bufferStream)

                // 4. Subscribe to result streams.
                let partialStream = await transcription.partialTextStream
                let finalStream = await transcription.finalTextStream
                partialTask = Task { @MainActor [weak self] in
                    for await text in partialStream {
                        self?.partialText = text
                    }
                }
                finalTask = Task { @MainActor [weak self] in
                    for await text in finalStream {
                        guard let self else { return }
                        self.partialText = ""
                        self.finalText = self.finalText.isEmpty
                            ? text
                            : self.finalText + " " + text
                    }
                }

                phase = .recording
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Stop

    func stopRecording() {
        guard case .recording = phase else { return }
        Task {
            await transcription.stop()
            _ = await recorder.stop()
            partialTask?.cancel(); partialTask = nil
            finalTask?.cancel(); finalTask = nil
            // Promote any trailing partial into the final transcript so
            // nothing the parent saw on screen is lost.
            if !partialText.isEmpty {
                finalText = finalText.isEmpty ? partialText : finalText + " " + partialText
                partialText = ""
            }
            phase = .stopped
        }
    }

    /// Discard the in-progress recording (used by "Abbrechen").
    func cancel() {
        Task {
            await transcription.stop()
            _ = await recorder.stop()
            partialTask?.cancel(); partialTask = nil
            finalTask?.cancel(); finalTask = nil
            partialText = ""
            finalText = ""
            recordingURL = nil
            phase = .idle
        }
    }
}
