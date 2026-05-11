import AVFoundation
import Foundation
import OSLog

private let recorderLog = Logger(subsystem: "io.grimso.Begleiter", category: "speech.recorder")

/// Captures microphone audio via `AVAudioEngine`, simultaneously writing a
/// compressed `.m4a` file to disk and yielding raw `AVAudioPCMBuffer`s to
/// the transcription engine.
///
/// File layout (per spec — everything stays on-device):
/// - `<Documents>/voice/<entryId>.m4a`
/// - Excluded from iCloud / iTunes backup via `NSURLIsExcludedFromBackupKey`.
///
/// One mic tap dual-purposes the audio so the transcript and the persisted
/// recording stay in lockstep — no second pass.
///
/// **Simulator behavior**: `AVAudioSession.setCategory` is iOS-only; on
/// macOS-targeted builds we'd no-op. Within iOS simulator builds the
/// session calls work but the microphone hardware isn't connected, so the
/// recorder still drives the file writer (silence) and emits an empty
/// buffer stream — enough to keep the UI flow alive for testing.
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
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var recordingURL: URL?

    /// AsyncStream of audio buffers fed to the `TranscriptionEngine`.
    /// Recreated on each `start(...)` call. `nil` when not recording.
    private(set) var bufferStream: AsyncStream<AVAudioPCMBuffer>?

    // MARK: - Lifecycle

    /// Begin recording. Returns the file URL the audio is being written to;
    /// caller stores `lastPathComponent` on `JournalEntry.rawVoiceAudioFilename`.
    func start(entryId: UUID) throws -> URL {
        try configureAudioSession()

        let url = try Self.recordingURL(for: entryId)
        recordingURL = url

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

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

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        bufferStream = stream
        bufferContinuation = continuation

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
    /// Returns the file URL of the completed recording, or nil if no
    /// recording was active.
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
        bufferContinuation?.yield(buffer)
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
