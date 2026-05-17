import XCTest
@testable import Begleiter

final class LabPlotParserTests: XCTestCase {

    // MARK: - Seed example

    func test_heuristic_seedExample_parsesCorrectly() throws {
        let spec = try LabPlotParser.parseHeuristic(
            question: "Ich möchte die Blutbild-Werte für die ersten zwei Wochen in Induktion und die letzte Woche nebeneinander sehen"
        )
        // CBC expansion
        XCTAssertEqual(Set(spec.parameters), Set(["WBC", "ANC", "HB", "PLT"]))
        // Two windows
        XCTAssertEqual(spec.windows.count, 2)
        // Window 1: phase IA, day 1-14
        if case let .phase(phase, fromDay, toDay, _) = spec.windows[0] {
            XCTAssertEqual(phase, "inductionIA")
            XCTAssertEqual(fromDay, 1)
            XCTAssertEqual(toDay, 14)
        } else {
            XCTFail("expected phase window first, got \(spec.windows[0])")
        }
        // Window 2: relative 7 days
        if case let .relativeDays(days, _) = spec.windows[1] {
            XCTAssertEqual(days, 7)
        } else {
            XCTFail("expected relativeDays window second, got \(spec.windows[1])")
        }
        // Layout side-by-side
        XCTAssertEqual(spec.layout, .sideBySideByParameter)
        // Title is non-empty
        XCTAssertFalse(spec.title.isEmpty)
    }

    // MARK: - Parameter resolution

    func test_heuristic_singleParameter_HB_lastMonth() throws {
        let spec = try LabPlotParser.parseHeuristic(question: "Zeig HB im letzten Monat")
        XCTAssertEqual(spec.parameters, ["HB"])
        XCTAssertEqual(spec.windows.count, 1)
        if case let .relativeDays(days, _) = spec.windows[0] {
            XCTAssertEqual(days, 30)
        } else {
            XCTFail("expected relativeDays(30), got \(spec.windows[0])")
        }
    }

    func test_heuristic_leberwerte_overlayReinduktion() throws {
        let spec = try LabPlotParser.parseHeuristic(
            question: "Leberwerte überlagern für die Reinduktion"
        )
        XCTAssertEqual(Set(spec.parameters), Set(["ALT", "AST", "GGT", "Bili"]))
        XCTAssertEqual(spec.layout, .overlayWindowsPerParameter)
        // One window: full reinductionII phase
        XCTAssertEqual(spec.windows.count, 1)
        if case let .phase(phase, fromDay, _, _) = spec.windows[0] {
            XCTAssertEqual(phase, "reinductionII")
            XCTAssertEqual(fromDay, 1)
        } else {
            XCTFail("expected phase window, got \(spec.windows[0])")
        }
    }

    func test_heuristic_individualParameterMentions() throws {
        let spec = try LabPlotParser.parseHeuristic(
            question: "CRP und ANC nebeneinander für die ersten 7 Tage in Konsolidierung"
        )
        XCTAssertTrue(spec.parameters.contains("CRP"))
        XCTAssertTrue(spec.parameters.contains("ANC"))
        if case let .phase(phase, fromDay, toDay, _) = spec.windows.first {
            XCTAssertEqual(phase, "consolidationM")
            XCTAssertEqual(fromDay, 1)
            XCTAssertEqual(toDay, 7)
        }
    }

    // MARK: - Error paths

    func test_heuristic_noParametersAtAll_throwsNoParameters() {
        XCTAssertThrowsError(try LabPlotParser.parseHeuristic(
            question: "Was hat das Wetter gestern gemacht?"
        )) { error in
            guard case LabPlotParserError.noParametersResolved = error else {
                XCTFail("expected .noParametersResolved, got \(error)")
                return
            }
        }
    }

    func test_heuristic_parameterButNoWindow_throwsNoWindow() {
        XCTAssertThrowsError(try LabPlotParser.parseHeuristic(
            question: "Was ist mit dem CRP?"
        )) { error in
            guard case LabPlotParserError.noWindowsResolved = error else {
                XCTFail("expected .noWindowsResolved, got \(error)")
                return
            }
        }
    }

    func test_heuristic_gibberish_throws() {
        XCTAssertThrowsError(try LabPlotParser.parseHeuristic(
            question: "lorem ipsum dolor sit amet"
        ))
    }

    // MARK: - Layout detection

    func test_heuristic_layoutPhrases() throws {
        let sideBy = try LabPlotParser.parseHeuristic(
            question: "Blutbild für Induktion IA und letzte Woche nebeneinander"
        )
        XCTAssertEqual(sideBy.layout, .sideBySideByParameter)

        let overlay = try LabPlotParser.parseHeuristic(
            question: "Blutbild für Induktion IA und letzte Woche überlagern"
        )
        XCTAssertEqual(overlay.layout, .overlayWindowsPerParameter)
    }

    // MARK: - Gemma JSON parser

    func test_gemma_parsesValidJSON() throws {
        let raw = """
        Hier ist die Spezifikation:
        {
          "title": "Blutbild Vergleich",
          "parameters": ["WBC", "ANC", "HB", "PLT"],
          "windows": [
            {"kind": "phase", "phase": "inductionIA", "fromDay": 1, "toDay": 14, "label": "IA Woche 1-2"},
            {"kind": "relativeDays", "daysBack": 7, "label": "letzte Woche"}
          ],
          "layout": "sideBySideByParameter"
        }
        """
        let spec = try LabPlotParser.parseGemmaJSON(raw)
        XCTAssertEqual(spec.title, "Blutbild Vergleich")
        XCTAssertEqual(spec.parameters, ["WBC", "ANC", "HB", "PLT"])
        XCTAssertEqual(spec.windows.count, 2)
        if case let .phase(phase, fromDay, toDay, label) = spec.windows[0] {
            XCTAssertEqual(phase, "inductionIA")
            XCTAssertEqual(fromDay, 1)
            XCTAssertEqual(toDay, 14)
            XCTAssertEqual(label, "IA Woche 1-2")
        } else {
            XCTFail("expected phase window, got \(spec.windows[0])")
        }
        if case let .relativeDays(days, label) = spec.windows[1] {
            XCTAssertEqual(days, 7)
            XCTAssertEqual(label, "letzte Woche")
        } else {
            XCTFail("expected relativeDays window, got \(spec.windows[1])")
        }
        XCTAssertEqual(spec.layout, .sideBySideByParameter)
    }

    func test_gemma_throwsOnMissingJSON() {
        XCTAssertThrowsError(try LabPlotParser.parseGemmaJSON("kein JSON")) { error in
            guard case LabPlotParserError.gemmaReturnedNoJSON = error else {
                XCTFail("expected .gemmaReturnedNoJSON, got \(error)")
                return
            }
        }
    }

    func test_gemma_promptIncludesParameterAndPhaseLists() {
        let prompt = LabPlotParser.buildGemmaPrompt(question: "Blutbild seit Tag 1")
        XCTAssertTrue(prompt.contains("WBC"))
        XCTAssertTrue(prompt.contains("ANC"))
        XCTAssertTrue(prompt.contains("inductionIA"))
        XCTAssertTrue(prompt.contains("reinductionII"))
        XCTAssertTrue(prompt.contains("sideBySideByParameter"))
        XCTAssertTrue(prompt.contains("Question (German): Blutbild seit Tag 1"))
    }

    /// English control prompt; German output. Load-bearing clauses.
    func test_gemma_promptIncludesEnglishControlClauses() {
        let prompt = LabPlotParser.buildGemmaPrompt(question: "x")
        XCTAssertTrue(prompt.contains("JSON only"))
        XCTAssertTrue(prompt.contains("Never invent"))
        XCTAssertTrue(prompt.contains("German"),
                      "lab-plot prompt must direct German title / label values")
    }

    /// Budget guard. Includes the typical-duration table + one example,
    /// so the budget is wider than the original 1 200 chars. Bumped to
    /// 2 200 chars (~550 tokens) — still well inside the 512 max-tokens
    /// reply budget Gemma uses for plots.
    func test_gemma_promptStaticSizeBelowBudget() {
        let prompt = LabPlotParser.buildGemmaPrompt(question: "")
        XCTAssertLessThan(prompt.count, 2200,
                          "lab-plot static prompt size budget: 2 200 chars")
    }

    // MARK: - Tolerant decoding (P1 fix)

    func test_gemma_decodes_snakeCase_relativeDays() throws {
        let raw = """
        {
          "title": "HB letzter Monat",
          "parameters": ["HB"],
          "windows": [
            {"kind": "relative_days", "days_back": 30, "label": "letzter Monat"}
          ],
          "layout": "side_by_side"
        }
        """
        let spec = try LabPlotParser.parseGemmaJSON(raw)
        XCTAssertEqual(spec.parameters, ["HB"])
        if case let .relativeDays(days, _) = spec.windows[0] {
            XCTAssertEqual(days, 30)
        } else {
            XCTFail("expected relativeDays, got \(spec.windows[0])")
        }
        XCTAssertEqual(spec.layout, .sideBySideByParameter)
    }

    func test_gemma_decodes_overlayAlias() throws {
        let raw = """
        {"title":"x","parameters":["WBC"],"windows":[{"kind":"phase","phase":"inductionIA","fromDay":1,"toDay":14}],"layout":"overlay"}
        """
        let spec = try LabPlotParser.parseGemmaJSON(raw)
        XCTAssertEqual(spec.layout, .overlayWindowsPerParameter)
    }

    func test_gemma_decodes_relativeDays_fromLabelOnly() throws {
        let raw = """
        {"title":"x","parameters":["HB"],"windows":[{"kind":"relativeDays","label":"last 30 days"}],"layout":"sideBySideByParameter"}
        """
        let spec = try LabPlotParser.parseGemmaJSON(raw)
        if case let .relativeDays(days, _) = spec.windows[0] {
            XCTAssertEqual(days, 30, "should parse 30 out of 'last 30 days' label")
        } else {
            XCTFail("expected relativeDays, got \(spec.windows[0])")
        }
    }

    // MARK: - Normalizer (P1 fix)

    func test_normalizer_canonicalizesGermanParameterSynonyms() {
        let raw = LabPlotSpec(
            title: "x",
            parameters: ["Leukozyten", "Neutrophile", "Platelets"],
            windows: [.relativeDays(daysBack: 7, label: nil)],
            layout: .sideBySideByParameter
        )
        guard case .success(let spec) = LabPlotSpecNormalizer.normalize(raw) else {
            XCTFail("expected success"); return
        }
        XCTAssertEqual(spec.parameters, ["WBC", "ANC", "PLT"])
    }

    func test_normalizer_canonicalizesHumanReadablePhase() {
        let raw = LabPlotSpec(
            title: "x",
            parameters: ["HB"],
            windows: [.phase(phase: "Induktion IA", fromDay: 1, toDay: 14, label: nil)],
            layout: .sideBySideByParameter
        )
        guard case .success(let spec) = LabPlotSpecNormalizer.normalize(raw) else {
            XCTFail("expected success"); return
        }
        if case let .phase(rawPhase, _, _, _) = spec.windows[0] {
            XCTAssertEqual(rawPhase, "inductionIA")
        } else {
            XCTFail("expected phase, got \(spec.windows[0])")
        }
    }

    func test_normalizer_rejectsEmptyParameters() {
        let raw = LabPlotSpec(
            title: "x",
            parameters: [],
            windows: [.relativeDays(daysBack: 7, label: nil)],
            layout: .sideBySideByParameter
        )
        guard case .failure(let err) = LabPlotSpecNormalizer.normalize(raw) else {
            XCTFail("expected failure"); return
        }
        guard case .noParametersResolved = err else {
            XCTFail("expected .noParametersResolved, got \(err)"); return
        }
    }

    func test_normalizer_rejectsAllUnknownPhases() {
        let raw = LabPlotSpec(
            title: "x",
            parameters: ["WBC"],
            windows: [.phase(phase: "TotallyUnknownPhase", fromDay: 1, toDay: 7, label: nil)],
            layout: .sideBySideByParameter
        )
        guard case .failure(let err) = LabPlotSpecNormalizer.normalize(raw) else {
            XCTFail("expected failure"); return
        }
        guard case .noWindowsResolved = err else {
            XCTFail("expected .noWindowsResolved, got \(err)"); return
        }
    }

    func test_normalizer_expandsDegenerateRangeToWholePhase() {
        // Gemma's lazy default: emit `fromDay: 1, toDay: 1` when the
        // parent asks for "the whole phase". The resolver would turn
        // that into a 1-day window starting at phase day 1, which never
        // matches the lab measurements taken later in the phase.
        let raw = LabPlotSpec(
            title: "x",
            parameters: ["WBC"],
            windows: [.phase(phase: "inductionIB", fromDay: 1, toDay: 1, label: nil)],
            layout: .sideBySideByParameter
        )
        guard case .success(let spec) = LabPlotSpecNormalizer.normalize(raw) else {
            XCTFail("expected success"); return
        }
        if case let .phase(_, fromDay, toDay, _) = spec.windows[0] {
            XCTAssertEqual(fromDay, 1)
            XCTAssertEqual(toDay, PhaseMetadata.for(.inductionIB).typicalDurationDays,
                           "degenerate 1..1 should expand to typicalDurationDays")
        } else {
            XCTFail("expected phase window")
        }
    }

    func test_normalizer_preservesIntentionalShortRange() {
        // `fromDay: 1, toDay: 7` is a legitimate "first 7 days" window.
        // Must NOT be expanded — the parent asked for a specific slice.
        let raw = LabPlotSpec(
            title: "x",
            parameters: ["WBC"],
            windows: [.phase(phase: "inductionIB", fromDay: 1, toDay: 7, label: nil)],
            layout: .sideBySideByParameter
        )
        guard case .success(let spec) = LabPlotSpecNormalizer.normalize(raw) else {
            XCTFail("expected success"); return
        }
        if case let .phase(_, fromDay, toDay, _) = spec.windows[0] {
            XCTAssertEqual(fromDay, 1)
            XCTAssertEqual(toDay, 7)
        } else {
            XCTFail("expected phase window")
        }
    }

    func test_normalizer_clampsExtremeDayRange() {
        let raw = LabPlotSpec(
            title: "x",
            parameters: ["WBC"],
            windows: [.phase(phase: "inductionIA", fromDay: 1, toDay: 9999, label: nil)],
            layout: .sideBySideByParameter
        )
        guard case .success(let spec) = LabPlotSpecNormalizer.normalize(raw) else {
            XCTFail("expected success"); return
        }
        if case let .phase(_, _, toDay, _) = spec.windows[0] {
            let cap = PhaseMetadata.for(.inductionIA).typicalDurationDays * 2
            XCTAssertLessThanOrEqual(toDay, cap)
        } else {
            XCTFail("expected phase window")
        }
    }

    // MARK: - Context-aware prompt (P2 fix)

    func test_gemma_promptIncludesAvailableParameters() {
        let ctx = LabPlotPromptContext(
            availableParameters: ["WBC", "ANC", "HB", "PLT", "CRP"],
            enteredPhases: ["inductionIB", "consolidationM"],
            earliestDataDate: "2026-02-01",
            latestDataDate: "2026-05-01"
        )
        let prompt = LabPlotParser.buildGemmaPrompt(question: "Blutbild", context: ctx, strict: false)
        XCTAssertTrue(prompt.contains("AVAILABLE parameters"))
        XCTAssertTrue(prompt.contains("WBC, ANC, HB, PLT, CRP"))
        XCTAssertTrue(prompt.contains("phases the child has entered"))
        XCTAssertTrue(prompt.contains("inductionIB, consolidationM"))
        XCTAssertTrue(prompt.contains("2026-02-01"))
    }

    func test_gemma_strictPromptStartsWithOutputDirective() {
        let prompt = LabPlotParser.buildGemmaPrompt(
            question: "x",
            context: .empty,
            strict: true
        )
        XCTAssertTrue(prompt.hasPrefix("OUTPUT JSON ONLY"),
                      "strict-mode prompt must lead with the JSON-only directive")
    }

    func test_gemma_emptyContext_omitsConstraintClauses() {
        let prompt = LabPlotParser.buildGemmaPrompt(question: "x", context: .empty, strict: false)
        XCTAssertFalse(prompt.contains("AVAILABLE parameters"))
        XCTAssertFalse(prompt.contains("phases the child has entered"))
    }
}
