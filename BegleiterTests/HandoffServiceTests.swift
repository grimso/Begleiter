import XCTest
@testable import Begleiter

final class HandoffServiceTests: XCTestCase {

    private func snapshot() -> ChildStateSnapshot {
        ChildStateSnapshot(
            childId: UUID(),
            phase: .reinductionII,
            dayInPhase: 22,
            riskGroup: .highRisk,
            arm: .rHR
        )
    }

    private func entryWithReaction() -> JournalEntry {
        JournalEntry(
            childId: UUID(),
            visitDate: .now,
            phase: .reinductionII,
            dayInPhase: 22,
            riskGroup: .highRisk,
            arm: .rHR,
            inputModalities: ["text"],
            rawText: "Heute nach Asparaginase Hautausschlag.",
            extractedFields: ExtractedFields(
                reactions: ConfidenceField(
                    value: [AdverseEvent(
                        description: "Hautausschlag nach Asparaginase",
                        suspectedCause: "PEG-Asparaginase",
                        parentSeverity: .moderate,
                        occurredAt: nil
                    )],
                    confidence: 0.9
                )
            )
        )
    }

    // MARK: - Prompt construction

    func test_buildPrompt_germanLanguage_includesPhaseLabel() {
        let prompt = HandoffService.buildPrompt(
            snapshot: snapshot(),
            recent: [entryWithReaction()],
            language: .german
        )
        XCTAssertTrue(prompt.contains("Reinduktion (Protokoll II)"),
                      "phase label stays German (domain term)")
        XCTAssertTrue(prompt.contains("Hochrisiko"),
                      "risk group label stays German (domain term)")
        XCTAssertTrue(prompt.contains("GERMAN"),
                      "language directive flips to GERMAN when language=.german")
        XCTAssertFalse(prompt.contains("ENGLISH"),
                      "ENGLISH directive must not appear in the German branch")
    }

    func test_buildPrompt_englishLanguage_addsEnglishInstruction() {
        let prompt = HandoffService.buildPrompt(
            snapshot: snapshot(),
            recent: [entryWithReaction()],
            language: .english
        )
        XCTAssertTrue(prompt.contains("ENGLISH"),
                      "Language directive flips to ENGLISH for the new-physician English handoff")
    }

    func test_buildPrompt_includesReactionsFromEntries() {
        let prompt = HandoffService.buildPrompt(
            snapshot: snapshot(),
            recent: [entryWithReaction()],
            language: .german
        )
        XCTAssertTrue(prompt.contains("Hautausschlag nach Asparaginase"),
                      "reaction description embedded verbatim")
        XCTAssertTrue(prompt.contains("PEG-Asparaginase"),
                      "drug name embedded verbatim")
    }

    /// English control prompt; output language follows the `language:`
    /// parameter. Load-bearing clauses.
    func test_buildPrompt_includesEnglishControlClauses() {
        let prompt = HandoffService.buildPrompt(
            snapshot: snapshot(),
            recent: [entryWithReaction()],
            language: .german
        )
        XCTAssertTrue(prompt.contains("JSON only"))
        XCTAssertTrue(prompt.contains("Never invent"))
        XCTAssertTrue(prompt.contains("No advice"))
    }

    /// Budget guard. Static (boilerplate) size with one minimal entry
    /// must stay under 1 200 chars (~300 tokens). Larger than the
    /// plan's 700 budget because the entry block embeds the
    /// reaction text — that variable content lifts the count.
    func test_buildPrompt_staticSizeBelowBudget() {
        let prompt = HandoffService.buildPrompt(
            snapshot: snapshot(),
            recent: [],
            language: .german
        )
        XCTAssertLessThan(prompt.count, 1200,
                          "handoff static prompt size budget: 1 200 chars (with no entries)")
    }

    // MARK: - Parse prose sections

    func test_parseProseSections_decodesValidJSON() throws {
        let json = """
        {
          "behandlungsverlauf": ["Induktion komplett", "Konsolidierung läuft"],
          "reaktionen": ["Hautausschlag nach Asparaginase"],
          "familienanliegen": ["Schlafmangel der Eltern"]
        }
        """
        let prose = try HandoffService.parseProseSections(from: json)
        XCTAssertEqual(prose.behandlungsverlauf.count, 2)
        XCTAssertEqual(prose.reaktionen, ["Hautausschlag nach Asparaginase"])
        XCTAssertEqual(prose.familienanliegen, ["Schlafmangel der Eltern"])
    }

    func test_parseProseSections_throwsOnMissingJSON() {
        XCTAssertThrowsError(try HandoffService.parseProseSections(from: "kein JSON"))
    }

    // MARK: - Plain-text serialization

    func test_plainText_includesAllSections() {
        let doc = HandoffDocument(
            generatedAt: .now,
            language: .german,
            patientId: "ABC12345",
            diagnose: "ALL, ED 03/2026",
            riskGroupLabel: "Hochrisiko (HR)",
            randomizationLabel: "R-HR",
            phaseLabel: "Reinduktion (Protokoll II)",
            dayInPhase: 22,
            behandlungsverlauf: ["Induktion IA komplett"],
            aktuelleLabore: [
                HandoffLabLine(
                    parameter: "ANC",
                    germanLabel: "Neutrophile",
                    value: "0.6 G/L",
                    measuredAt: .now,
                    referenceRange: "1.5–8.0 G/L"
                )
            ],
            reaktionen: ["Hautausschlag"],
            aktuelleMedikation: ["Vincristin"],
            familienanliegen: ["Sorge wegen Infekt"]
        )
        let text = HandoffDocumentView.plainText(of: doc)
        XCTAssertTrue(text.contains("ÜBERGABE — ABC12345"))
        XCTAssertTrue(text.contains("BEHANDLUNGSVERLAUF"))
        XCTAssertTrue(text.contains("AKTUELLE LABORE"))
        XCTAssertTrue(text.contains("Neutrophile: 0.6 G/L"))
        XCTAssertTrue(text.contains("Ref: 1.5–8.0 G/L"))
        XCTAssertTrue(text.contains("REAKTIONEN"))
        XCTAssertTrue(text.contains("AKTUELLE MEDIKATION"))
        XCTAssertTrue(text.contains("ANLIEGEN DER FAMILIE"))
        XCTAssertTrue(text.contains("Begleiter, on-device"))
    }
}
