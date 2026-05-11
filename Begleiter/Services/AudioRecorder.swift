import AVFoundation
import Foundation
import OSLog
@preconcurrency import Speech

private let recorderLog = Logger(subsystem: "io.grimso.Begleiter", category: "speech.recorder")

/// Captures microphone audio via `AVAudioEngine`, simultaneously writing a
/// compressed `.m4a` file to disk and yielding `AnalyzerInput` buffers to
/// the live transcriber.
///
/// File layout (per spec — everything stays on-device):
/// - `<Documents>/voice/<entryId>.m4a`
/// - Excluded from iCloud / iTunes backup via
///   `NSURLIsExcludedFromBackupKey`.
///
/// The transcriber and the file writer share the same audio tap so the
/// transcript and the recording stay in lockstep — no second pass needed.
@available(iOS 26.0, *)
actor AudioRecorder {

    enum RecorderError: Error, LocalizedError {
        case audioSessionFailed(String)
        case fileWriteFailed(String)
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .audioSessionFailed(let detail):
                return "Audio-Sitzung fehlgeschlagen: \(detail)"
            case .fileWriteFailed(let detail):
                return "Audio-Datei konnte nicht geschrieben werden: \(detail)"
            case .engineFailed(let detail):
                return "Audio-Engine fehlgeschlagen: \(detail)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var bufferContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var recordingURL: URL?

    /// AsyncStream of audio buffers fed to the `TranscriptionService`.
    /// Recreated on each `start(...)` call.
    private(set) var bufferStream: AsyncStream<AnalyzerInput>?

    // MARK: - Lifecycle

    /// Begin recording. Returns the file URL the audio is being written to;
    /// caller stores `lastPathComponent` on `JournalEntry.rawVoiceAudioFilename`.
    func start(entryId: UUID) throws -> URL {
        try configureAudioSession()

        let url = try Self.recordingURL(for: entryId)
        recordingURL = url

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        // Open the destination file using the same hardware format so the
        // tap callback can write buffers without resampling. The container
        // format is m4a (AAC inside MPEG-4); AVAudioFile picks AAC by
        // default when the URL extension is .m4a.
        do {
            audioFile = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            throw RecorderError.fileWriteFailed(error.localizedDescription)
        }

        // (Re)create the buffer stream that feeds the transcriber.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        bufferStream = stream
        bufferContinuation = continuation

        // Single tap dual-purposes the audio: write to file + yield to
        // transcriber. Tap runs on an audio-thread queue so we keep the
        // closure tiny.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            Task { await self.handleBuffer(buffer) }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailed(error.localizedDescription)
        }

        recorderLog.info("recording started: \(url.lastPathComponent, privacy: .public)")
        return url
    }

    /// Stop recording. Tears down the engine + closes the file.
    /// Returns the file URL of the completed recording.
    func stop() -> URL? {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        bufferContinuation?.finish()
        bufferContinuation = nil
        bufferStream = nil
        let url = recordingURL
        audioFile = nil
        recordingURL = nil
        if let url {
            recorderLog.info("recording stopped: \(url.lastPathComponent, privacy: .public)")
        }
        return url
    }

    // MARK: - Internals

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        if let audioFile {
            do {
                try audioFile.write(from: buffer)
            } catch {
                recorderLog.error("file write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        bufferContinuation?.yield(AnalyzerInput(buffer: buffer))
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            throw RecorderError.audioSessionFailed(error.localizedDescription)
        }
    }

    // MARK: - File-system helpers

    /// Compute the on-disk URL for an entry's audio file.
    static func recordingURL(for entryId: UUID) throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let voiceDir = docs.appendingPathComponent("voice", isDirectory: true)
        if !FileManager.default.fileExists(atPath: voiceDir.path) {
            try FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
            // Exclude from iCloud / iTunes backup — spec says all data
            // stays strictly on-device.
            var url = voiceDir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return voiceDir.appendingPathComponent("\(entryId.uuidString).m4a")
    }

    /// Resolve a stored `rawVoiceAudioFilename` (just the basename) back to
    /// its full URL for playback.
    static func storedURL(forFilename filename: String) -> URL? {
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return nil }
        let url = docs.appendingPathComponent("voice", isDirectory: true)
            .appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
