import AVFoundation
import XCTest
@testable import Begleiter

/// State-machine tests for `VoiceRecorderViewModel`. Run on the simulator
/// using `MockTranscriptionEngine` — no microphone, no Speech daemon,
/// no Apple ASR involvement.
///
/// The model also depends on `AudioRecorder` which tries to start
/// `AVAudioEngine`. In simulator builds without a microphone, that may or
/// may not succeed — these tests therefore focus on the prepare/transcribe
/// state transitions and don't assert on `recordingURL` (which depends on
/// `AVAudioEngine.start()` returning successfully).
@MainActor
final class VoiceRecorderViewModelTests: XCTestCase {

    // MARK: - Mock helpers

    /// Wait for `model.phase` to reach `target` (or any of `target...`)
    /// up to `timeout` seconds. Polls every 50ms.
    private func waitForPhase(
        _ model: VoiceRecorderViewModel,
        matching predicate: @escaping (VoiceRecorderViewModel.Phase) -> Bool,
        timeout: Duration = .seconds(3)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate(model.phase) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return predicate(model.phase)
    }

    // MARK: - Tests

    func test_initialState_isIdle() {
        let model = VoiceRecorderViewModel(engine: MockTranscriptionEngine())
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.partialText.isEmpty)
        XCTAssertTrue(model.finalText.isEmpty)
    }

    func test_startRecording_immediatelyTransitionsToPreparing() {
        // The full prepare → recording transition needs real AVAudioEngine
        // hardware (microphone, audio session permission) which simulator
        // unit tests can't reliably provide. We only assert the synchronous
        // transition into .preparing — the rest of the path is exercised
        // on-device.
        let mock = MockTranscriptionEngine(scripted: "Test")
        let model = VoiceRecorderViewModel(engine: mock)

        model.startRecording()
        XCTAssertEqual(model.phase, .preparing)

        // Clean up so we don't leak the still-running AudioRecorder.
        model.cancel()
    }

    func test_prepareError_transitionsToFailed() async {
        let mock = MockTranscriptionEngine()
        await mock.setPrepareError(TranscriptionEngineError.permissionDenied)
        let model = VoiceRecorderViewModel(engine: mock)

        model.startRecording()

        let failed = await waitForPhase(model) { phase in
            if case .failed = phase { return true }
            return false
        }
        XCTAssertTrue(failed, "Should reach .failed when prepare throws")
        if case .failed(let message) = model.phase {
            XCTAssertTrue(message.contains("Spracherkennung wurde verweigert"))
        }
    }

    func test_cancelDuringPrepare_returnsToIdle() async {
        // Use a long-running mock prepare to give us time to cancel.
        let mock = SlowPrepareMockEngine()
        let model = VoiceRecorderViewModel(engine: mock)

        model.startRecording()
        XCTAssertEqual(model.phase, .preparing)

        // Yield, then cancel before prepare can complete.
        try? await Task.sleep(for: .milliseconds(50))
        model.cancel()

        let idleAgain = await waitForPhase(model) { phase in
            phase == .idle || phase == .failed("")
                || { if case .failed = phase { return true }; return false }()
        }
        XCTAssertTrue(idleAgain, "Should leave preparing after cancel, got \(model.phase)")
        XCTAssertNotEqual(model.phase, .preparing, "Cancel must exit preparing")
        XCTAssertNotEqual(model.phase, .recording, "Cancel must not transition into recording")
    }

    func test_displayedTranscript_combinesFinalAndPartial() {
        let model = VoiceRecorderViewModel(engine: MockTranscriptionEngine())
        model.finalText = "Heute Vincristin"
        model.partialText = "bekommen"
        XCTAssertEqual(model.displayedTranscript, "Heute Vincristin bekommen")
    }

    func test_displayedTranscript_emptyWhenBothEmpty() {
        let model = VoiceRecorderViewModel(engine: MockTranscriptionEngine())
        XCTAssertEqual(model.displayedTranscript, "")
    }
}

// MARK: - Test-only mock with a configurable delay

/// `MockTranscriptionEngine` resolves prepare() within 200ms by default.
/// For the cancel-during-prepare test we want a longer delay so we can
/// reliably interject `cancel()` before prepare completes.
private actor SlowPrepareMockEngine: TranscriptionEngine {
    nonisolated let partialResults: AsyncStream<String>
    nonisolated let finalResults: AsyncStream<String>

    init() {
        self.partialResults = AsyncStream { _ in }
        self.finalResults = AsyncStream { _ in }
    }

    func prepare() async throws {
        // 5s — long enough for the test to cancel before completion.
        try await Task.sleep(for: .seconds(5))
    }

    func start(audioStream: AsyncStream<AVAudioPCMBuffer>) async throws {
        // unreachable in this test
    }

    func stop() async {
        // no-op
    }
}
