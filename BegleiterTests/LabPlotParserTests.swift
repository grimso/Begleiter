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

    /// Budget guard. Static size under 1 200 chars (~300 tokens).
    func test_gemma_promptStaticSizeBelowBudget() {
        let prompt = LabPlotParser.buildGemmaPrompt(question: "")
        XCTAssertLessThan(prompt.count, 1200,
                          "lab-plot static prompt size budget: 1 200 chars")
    }
}
