import XCTest
@testable import Begleiter

/// Tests for the pure-Swift `ProcessingStatus` accessor and its rawValue
/// round-trip. The ExtractionQueue itself isn't covered here because it
/// requires a live ModelContainer + ExtractionService.shared which goes
/// through MLX (unavailable on the simulator's Metal stack).
final class ProcessingStatusTests: XCTestCase {

    func test_rawValues() {
        XCTAssertEqual(ProcessingStatus.pending.rawValue, "pending")
        XCTAssertEqual(ProcessingStatus.extracting.rawValue, "extracting")
        XCTAssertEqual(ProcessingStatus.extracted.rawValue, "extracted")
        XCTAssertEqual(ProcessingStatus.failed(message: "boom").rawValue, "failed")
        XCTAssertEqual(ProcessingStatus.failed(message: nil).rawValue, "failed")
    }

    func test_failureMessage_onlySetForFailed() {
        XCTAssertNil(ProcessingStatus.pending.failureMessage)
        XCTAssertNil(ProcessingStatus.extracting.failureMessage)
        XCTAssertNil(ProcessingStatus.extracted.failureMessage)
        XCTAssertEqual(ProcessingStatus.failed(message: "oops").failureMessage, "oops")
        XCTAssertNil(ProcessingStatus.failed(message: nil).failureMessage)
    }

    func test_roundTrip_throughRawColumnAndFailureMessage() {
        let cases: [ProcessingStatus] = [
            .pending,
            .extracting,
            .extracted,
            .failed(message: "Gemma hat ungültiges JSON geliefert"),
            .failed(message: nil),
        ]
        for status in cases {
            let restored = ProcessingStatus.from(
                raw: status.rawValue,
                failureMessage: status.failureMessage
            )
            XCTAssertEqual(restored, status, "round-trip mismatch for \(status)")
        }
    }

    func test_from_unknownRawValue_defaultsToExtracted() {
        // Migration safety: existing rows that pre-date the column write
        // a default `"extracted"`, and any value we don't recognise
        // should also degrade safely to .extracted (parent's data still
        // renders, no panic banner appears).
        XCTAssertEqual(
            ProcessingStatus.from(raw: "something_new", failureMessage: nil),
            .extracted
        )
        XCTAssertEqual(
            ProcessingStatus.from(raw: "", failureMessage: nil),
            .extracted
        )
    }

    func test_journalEntry_defaultStatusIsExtracted() {
        // SwiftData migration default: existing entries (no
        // processingStatus column) become .extracted on first read
        // after upgrade, so their structured fields keep rendering.
        let entry = JournalEntry(
            childId: UUID(),
            visitDate: .now,
            phase: .inductionIA,
            dayInPhase: 1,
            riskGroup: .standardRisk,
            arm: .standard,
            inputModalities: ["text"],
            rawText: "Test"
        )
        XCTAssertEqual(entry.processingStatus, .extracted)
    }

    func test_journalEntry_pendingStatus_setsRawAndPropagates() {
        let entry = JournalEntry(
            childId: UUID(),
            visitDate: .now,
            phase: .inductionIA,
            dayInPhase: 1,
            riskGroup: .standardRisk,
            arm: .standard,
            inputModalities: ["text"],
            rawText: "Test",
            processingStatus: .pending
        )
        XCTAssertEqual(entry.processingStatusRaw, "pending")
        XCTAssertEqual(entry.processingStatus, .pending)
    }

    func test_journalEntry_failedStatus_persistsMessage() {
        let entry = JournalEntry(
            childId: UUID(),
            visitDate: .now,
            phase: .inductionIA,
            dayInPhase: 1,
            riskGroup: .standardRisk,
            arm: .standard,
            inputModalities: ["text"],
            rawText: "Test",
            processingStatus: .failed(message: "Gemma timeout")
        )
        XCTAssertEqual(entry.processingStatusRaw, "failed")
        XCTAssertEqual(entry.processingFailureMessage, "Gemma timeout")
        XCTAssertEqual(entry.processingStatus, .failed(message: "Gemma timeout"))
    }
}
