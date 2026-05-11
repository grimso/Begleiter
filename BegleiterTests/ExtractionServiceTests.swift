import XCTest
@testable import Begleiter

/// Tests for the pure-Swift surface of `ExtractionService`:
/// prompt construction and tolerant JSON parsing. On-device Gemma
/// generation is exercised manually via the CaptureView on the iPhone.
final class ExtractionServiceTests: XCTestCase {

    // MARK: - Prompt construction

    func test_buildPrompt_includesPhaseContext() {
        let prompt = ExtractionService.buildPrompt(
            text: "Heute Vincristin bekommen, ANC 0.8.",
            phase: .inductionIA,
            dayInPhase: 12,
            visitDate: Date(timeIntervalSince1970: 1_700_000_000),
            strictMode: false
        )
        XCTAssertTrue(prompt.contains("Induktion (Protokoll IA)"),
                      "Prompt must label phase in German.")
        XCTAssertTrue(prompt.contains("Tag in dieser Phase: 12"),
                      "Prompt must include day-in-phase context.")
        XCTAssertTrue(prompt.contains("Heute Vincristin"),
                      "Prompt must include parent's text.")
    }

    func test_buildPrompt_strictMode_addsJSONOnlyDirective() {
        let strict = ExtractionService.buildPrompt(
            text: "x", phase: .inductionIA, dayInPhase: 1,
            visitDate: .now, strictMode: true
        )
        let lax = ExtractionService.buildPrompt(
            text: "x", phase: .inductionIA, dayInPhase: 1,
            visitDate: .now, strictMode: false
        )
        XCTAssertTrue(strict.contains("AUSSCHLIESSLICH"))
        XCTAssertFalse(lax.contains("AUSSCHLIESSLICH"))
    }

    func test_buildPrompt_alwaysIncludesSchema() {
        let prompt = ExtractionService.buildPrompt(
            text: "x", phase: .maintenance, dayInPhase: 200,
            visitDate: .now, strictMode: false
        )
        // Schema keys that every prompt must list.
        let requiredKeys = [
            "visitType", "doctorName", "drugsMentioned", "labValues",
            "proceduresMentioned", "decisions", "parentObservations",
            "openQuestions", "reactions", "summary"
        ]
        for key in requiredKeys {
            XCTAssertTrue(prompt.contains(key), "Prompt missing schema key: \(key)")
        }
    }

    // MARK: - Tolerant JSON parsing

    func test_firstJSONObject_extractsFromMarkdownFence() {
        let raw = """
        Hier ist die Antwort:
        ```json
        {"visitType": {"value": "ambulant", "confidence": 0.9}}
        ```
        """
        let extracted = ExtractionService.firstJSONObject(in: raw)
        XCTAssertNotNil(extracted)
        XCTAssertTrue(extracted!.contains("\"visitType\""))
        XCTAssertTrue(extracted!.hasPrefix("{"))
        XCTAssertTrue(extracted!.hasSuffix("}"))
    }

    func test_firstJSONObject_handlesNestedBraces() {
        let raw = #"{"a": {"b": {"c": 1}, "d": 2}, "e": 3}"#
        let extracted = ExtractionService.firstJSONObject(in: raw)
        XCTAssertEqual(extracted, raw)
    }

    func test_firstJSONObject_ignoresBracesInsideStrings() {
        let raw = #"prose {"text": "this { is } not a brace", "x": 1} more prose"#
        let extracted = ExtractionService.firstJSONObject(in: raw)
        XCTAssertEqual(extracted, #"{"text": "this { is } not a brace", "x": 1}"#)
    }

    func test_firstJSONObject_returnsNilForUnbalanced() {
        XCTAssertNil(ExtractionService.firstJSONObject(in: "no json here at all"))
        XCTAssertNil(ExtractionService.firstJSONObject(in: "{ unterminated"))
    }

    func test_parseExtractedFields_decodesFromMarkdownWrapper() throws {
        let raw = """
        Selbstverständlich, hier ist das JSON:
        ```json
        {
          "summary": {"value": "Routine-Termin", "confidence": 0.85}
        }
        ```
        """
        let fields = try ExtractionService.parseExtractedFields(from: raw)
        XCTAssertEqual(fields.summary?.value, "Routine-Termin")
        XCTAssertEqual(fields.summary?.confidence ?? 0, 0.85, accuracy: 0.001)
    }

    func test_parseExtractedFields_throwsOnMissingJSON() {
        XCTAssertThrowsError(try ExtractionService.parseExtractedFields(from: "Tut mir leid, ich kann das nicht.")) { error in
            guard let extractionError = error as? ExtractionError else {
                return XCTFail("Expected ExtractionError, got \(error)")
            }
            if case .modelReturnedNoJSON = extractionError {
                // ok
            } else {
                XCTFail("Expected .modelReturnedNoJSON, got \(extractionError)")
            }
        }
    }

    func test_parseExtractedFields_tolerates_malformedFieldsByDropping() throws {
        // Mixed JSON: visitType has wrong shape (String instead of
        // ConfidenceField), summary is well-formed. New tolerant decoder
        // should drop the bad field and keep the good one.
        let raw = #"{"visitType": "ambulant", "summary": {"value": "ok", "confidence": 0.8}}"#
        let fields = try ExtractionService.parseExtractedFields(from: raw)
        XCTAssertNil(fields.visitType, "malformed visitType field should be dropped silently")
        XCTAssertEqual(fields.summary?.value, "ok")
    }

    func test_parseExtractedFields_tolerates_nullValueByDropping() throws {
        // Real-world Gemma 4 E2B output: `"doctorName": {"value": null}`.
        // Previously this threw and killed the whole extraction — now we
        // drop doctorName and keep the rest.
        let raw = """
        {
          "doctorName": {"value": null, "confidence": 0.0},
          "summary": {"value": "Routine-Termin", "confidence": 0.85}
        }
        """
        let fields = try ExtractionService.parseExtractedFields(from: raw)
        XCTAssertNil(fields.doctorName)
        XCTAssertEqual(fields.summary?.value, "Routine-Termin")
    }

    func test_parseExtractedFields_tolerates_missingConfidence() throws {
        // Another real Gemma output: empty-array fields sometimes omit
        // `confidence`. ConfidenceField now defaults it to 0.5.
        let raw = #"{"openQuestions": {"value": []}}"#
        let fields = try ExtractionService.parseExtractedFields(from: raw)
        XCTAssertEqual(fields.openQuestions?.value, [])
        XCTAssertEqual(fields.openQuestions?.confidence ?? 0, 0.5, accuracy: 0.0001)
    }
}
