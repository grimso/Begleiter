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
        // Phase label and parent text stay German — they're either
        // domain terms or copied source — but the surrounding control
        // labels (`phase`, `dayInPhase`) are English now.
        XCTAssertTrue(prompt.contains("Induktion (Protokoll IA)"),
                      "Phase label is a German domain term, preserved verbatim.")
        XCTAssertTrue(prompt.contains("dayInPhase: 12"),
                      "Day-in-phase context surfaces under an English key.")
        XCTAssertTrue(prompt.contains("Heute Vincristin"),
                      "Parent's German text is embedded verbatim.")
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
        XCTAssertTrue(strict.contains("Strict mode"))
        XCTAssertFalse(lax.contains("Strict mode"))
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

    /// English control prompt; German output. Load-bearing instruction
    /// substrings the model must see every time. If a future rewrite
    /// drops one of these, the safety contract weakens before anyone
    /// notices.
    func test_buildPrompt_includesEnglishControlClauses() {
        let prompt = ExtractionService.buildPrompt(
            text: "", phase: .inductionIA, dayInPhase: 1,
            visitDate: .now, strictMode: false
        )
        XCTAssertTrue(prompt.contains("Return JSON only") || prompt.contains("Strict mode"),
                      "extraction prompt must enforce JSON-only output")
        XCTAssertTrue(prompt.contains("Never invent"),
                      "extraction prompt must carry the no-hallucination rule")
        XCTAssertTrue(prompt.contains("No advice, diagnosis, dose"),
                      "extraction prompt must carry the safety rule")
        XCTAssertTrue(prompt.contains("German"),
                      "extraction prompt must direct German JSON values")
    }

    /// Budget guard. Static (boilerplate) size when called with empty
    /// input must stay under 2 200 chars (~550 tokens) so prefill time
    /// stays predictable on every queue-driven extraction.
    func test_buildPrompt_staticSizeBelowBudget() {
        let prompt = ExtractionService.buildPrompt(
            text: "", phase: .inductionIA, dayInPhase: 0,
            visitDate: Date(timeIntervalSince1970: 0), strictMode: false
        )
        XCTAssertLessThan(prompt.count, 2200,
                          "extraction static prompt size budget: 2 200 chars")
    }

    func test_buildVisionPrompt_staticSizeBelowBudget() {
        let prompt = ExtractionService.buildVisionPrompt(
            text: "", phase: .inductionIA, dayInPhase: 0,
            visitDate: Date(timeIntervalSince1970: 0),
            imageCount: 1, strictMode: false
        )
        // Budget held at 2 600 chars — measurably below the 2 880-char
        // German baseline; the bigger win comes from English tokenizer
        // density (~3.4 → ~4 chars/token) on top of the cuts.
        XCTAssertLessThan(prompt.count, 2600,
                          "vision extraction static prompt size budget: 2 600 chars")
    }

    func test_buildVisionPrompt_includesEnglishControlClauses() {
        let prompt = ExtractionService.buildVisionPrompt(
            text: "", phase: .inductionIA, dayInPhase: 1,
            visitDate: .now, imageCount: 1, strictMode: false
        )
        XCTAssertTrue(prompt.contains("Never invent"))
        XCTAssertTrue(prompt.contains("No advice"))
        XCTAssertTrue(prompt.contains("German"))
        XCTAssertTrue(prompt.contains("Befund"),
                      "vision prompt must keep the German domain term verbatim")
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
