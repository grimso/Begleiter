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
        let prompt = ExtractionService.buildVisionPrompt(strictMode: false)
        // CBC-focused prompt (#7 explicit_dual_value_handling) is far
        // smaller than the prior all-in-one schema; tightened budget
        // guards against future bloat.
        XCTAssertLessThan(prompt.count, 1500,
                          "vision extraction static prompt size budget: 1 500 chars")
    }

    /// Load-bearing instruction substrings the model must see every
    /// time. Sourced from the winning prompt in the sweep
    /// (`kaggle_gemma4-prompts/research/REPORT_prompt_engineering.md`,
    /// #7 explicit_dual_value_handling). If a future rewrite drops one,
    /// recall regresses to ~0.43 because the dual-value rows drop.
    func test_buildVisionPrompt_includesLoadBearingClauses() {
        let prompt = ExtractionService.buildVisionPrompt(strictMode: false)
        XCTAssertTrue(prompt.contains("blood_count"),
                      "vision prompt must request the proven blood_count schema")
        XCTAssertTrue(prompt.contains("NEUT#") && prompt.contains("NEUT%"),
                      "vision prompt must carry the dual-value split rule")
        XCTAssertTrue(prompt.contains("Sysmex"),
                      "vision prompt must anchor on the Sysmex report layout")
        XCTAssertTrue(prompt.contains("\"flag\": \"abnormal\""),
                      "vision prompt must carry the Sysmex flag legend")
        XCTAssertTrue(prompt.contains("Never invent"),
                      "vision prompt must keep the no-hallucination rule")
    }

    func test_buildVisionPrompt_strictMode_addsJSONOnlyDirective() {
        let strict = ExtractionService.buildVisionPrompt(strictMode: true)
        let lax = ExtractionService.buildVisionPrompt(strictMode: false)
        XCTAssertTrue(strict.contains("Strict mode"))
        XCTAssertFalse(lax.contains("Strict mode"))
    }

    // MARK: - buildLabsOnlyPrompt (text path, "Befund auslesen" shortcut)

    func test_buildLabsOnlyPrompt_embedsOCRTextVerbatim() {
        let ocr = "WBC 1.82 * [10^3/uL]\nHGB 10.3 - [g/dL]"
        let prompt = ExtractionService.buildLabsOnlyPrompt(ocrText: ocr, strictMode: false)
        XCTAssertTrue(prompt.contains(ocr),
                      "OCR block must be embedded verbatim so Gemma sees the source rows")
        XCTAssertTrue(prompt.contains("OCR TEXT:"),
                      "OCR block must be labelled so the model knows where the source starts")
    }

    func test_buildLabsOnlyPrompt_includesLoadBearingClauses() {
        let prompt = ExtractionService.buildLabsOnlyPrompt(ocrText: "x", strictMode: false)
        XCTAssertTrue(prompt.contains("blood_count"))
        XCTAssertTrue(prompt.contains("NEUT#") && prompt.contains("NEUT%"))
        XCTAssertTrue(prompt.contains("Sysmex"))
        XCTAssertTrue(prompt.contains("\"flag\": \"abnormal\""))
        XCTAssertTrue(prompt.contains("Never invent"))
    }

    func test_buildLabsOnlyPrompt_strictMode_addsJSONOnlyDirective() {
        let strict = ExtractionService.buildLabsOnlyPrompt(ocrText: "x", strictMode: true)
        let lax = ExtractionService.buildLabsOnlyPrompt(ocrText: "x", strictMode: false)
        XCTAssertTrue(strict.contains("Strict mode"))
        XCTAssertFalse(lax.contains("Strict mode"))
    }

    func test_buildLabsOnlyPrompt_staticSizeBelowBudget() {
        let prompt = ExtractionService.buildLabsOnlyPrompt(ocrText: "", strictMode: false)
        XCTAssertLessThan(prompt.count, 1600,
                          "labs-only static prompt size budget: 1 600 chars (slightly wider than vision because of the OCR block scaffolding)")
    }

    // MARK: - parseVisionFields

    func test_parseVisionFields_mapsBloodCountIntoLabValues() throws {
        let raw = """
        ```json
        {
          "blood_count": [
            {"parameter": "WBC", "value": 1.82, "unit": "10^3/uL", "flag": "abnormal"},
            {"parameter": "HGB", "value": 10.3, "unit": "g/dL"},
            {"parameter": "NEUT#", "value": 0.38, "unit": "10^3/uL", "flag": "abnormal"},
            {"parameter": "NEUT%", "value": 20.9, "unit": "%", "flag": "abnormal"}
          ]
        }
        ```
        """
        let visitDate = Date(timeIntervalSince1970: 1_700_000_000)
        let fields = try ExtractionService.parseVisionFields(from: raw, visitDate: visitDate)
        let labs = try XCTUnwrap(fields.labValues?.value)
        XCTAssertEqual(labs.count, 4)
        XCTAssertEqual(labs.map(\.parameter), ["WBC", "HGB", "NEUT#", "NEUT%"])
        XCTAssertEqual(labs[0].value, 1.82, accuracy: 0.001)
        XCTAssertEqual(labs[1].unit, "g/dL")
        // Every entry stamped with the visit date — the model isn't
        // asked to read dates off the report.
        XCTAssertTrue(labs.allSatisfy { $0.measuredAt == visitDate })
        XCTAssertTrue(labs.allSatisfy { $0.source == .befundPhoto })
    }

    func test_parseVisionFields_dropsEntriesWithNullValue() throws {
        let raw = #"{"blood_count":[{"parameter":"WBC","value":1.0,"unit":"x"},{"parameter":"HGB","value":null,"unit":"y"}]}"#
        let fields = try ExtractionService.parseVisionFields(from: raw, visitDate: .now)
        XCTAssertEqual(fields.labValues?.value.count, 1)
        XCTAssertEqual(fields.labValues?.value.first?.parameter, "WBC")
    }

    func test_parseVisionFields_throwsWhenEverythingDropped() {
        let raw = #"{"blood_count":[{"parameter":"WBC","value":null}]}"#
        XCTAssertThrowsError(try ExtractionService.parseVisionFields(from: raw, visitDate: .now))
    }

    func test_parseVisionFields_throwsOnMissingJSON() {
        XCTAssertThrowsError(try ExtractionService.parseVisionFields(from: "no json", visitDate: .now)) { error in
            guard case ExtractionError.modelReturnedNoJSON = error else {
                return XCTFail("Expected .modelReturnedNoJSON, got \(error)")
            }
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
