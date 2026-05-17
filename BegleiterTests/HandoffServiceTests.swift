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
        let uuidA = UUID()
        let uuidB = UUID()
        let json = """
        {
          "behandlungsverlauf": [
            {"text": "Induktion komplett", "entryId": "\(uuidA.uuidString)"},
            {"text": "Konsolidierung läuft", "entryId": null}
          ],
          "reaktionen": [
            {"text": "Hautausschlag nach Asparaginase", "entryId": "\(uuidB.uuidString)"}
          ],
          "familienanliegen": [
            {"text": "Schlafmangel der Eltern", "entryId": null}
          ]
        }
        """
        let prose = try HandoffService.parseProseSections(from: json)
        XCTAssertEqual(prose.behandlungsverlauf.count, 2)
        XCTAssertEqual(prose.behandlungsverlauf[0].text, "Induktion komplett")
        XCTAssertEqual(prose.behandlungsverlauf[0].entryId, uuidA)
        XCTAssertNil(prose.behandlungsverlauf[1].entryId)
        XCTAssertEqual(prose.reaktionen.first?.text, "Hautausschlag nach Asparaginase")
        XCTAssertEqual(prose.reaktionen.first?.entryId, uuidB)
        XCTAssertEqual(prose.familienanliegen.first?.text, "Schlafmangel der Eltern")
        XCTAssertNil(prose.familienanliegen.first?.entryId)
    }

    /// Legacy wire shape from before §S4 added citations — flat strings
    /// without entryId. Tolerant Codable decoder on HandoffDocument
    /// keeps reading older persisted blobs without crashing; same
    /// pattern needs to hold for the wire shape Gemma emits when
    /// instruction-following slips. (HandoffClaim's tolerant decoder
    /// already handles a malformed entryId; this test pins the
    /// HandoffDocument-side string fallback.)
    func test_handoffDocument_legacyStringArrays_decodeToClaims() throws {
        let json = """
        {
          "generatedAt": "2026-05-17T10:00:00Z",
          "language": "de",
          "patientId": "ABC",
          "diagnose": "ALL",
          "riskGroupLabel": "SR",
          "randomizationLabel": "STANDARD",
          "phaseLabel": "Konsolidierung",
          "dayInPhase": 18,
          "behandlungsverlauf": ["legacy bullet 1", "legacy bullet 2"],
          "aktuelleLabore": [],
          "reaktionen": [],
          "aktuelleMedikation": [],
          "familienanliegen": ["legacy concern"]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(HandoffDocument.self, from: Data(json.utf8))
        XCTAssertEqual(doc.behandlungsverlauf.count, 2)
        XCTAssertEqual(doc.behandlungsverlauf[0].text, "legacy bullet 1")
        XCTAssertNil(doc.behandlungsverlauf[0].entryId,
                     "Legacy string bullets must decode with entryId == nil")
        XCTAssertEqual(doc.familienanliegen.first?.text, "legacy concern")
    }

    func test_parseProseSections_throwsOnMissingJSON() {
        XCTAssertThrowsError(try HandoffService.parseProseSections(from: "kein JSON"))
    }

    // MARK: - Filter + scrub

    /// Bullets whose entryId isn't in the surfaced set must be dropped
    /// before the document is returned to the rotating doctor — same
    /// contract as BriefingService.filterUngroundedClaims.
    func test_filterAndScrub_dropsUnknownEntryIds() {
        let surfaced = UUID()
        let hallucinated = UUID()
        let prose = HandoffService.ProseSections(
            behandlungsverlauf: [
                HandoffClaim(text: "Surfaced bullet", entryId: surfaced),
                HandoffClaim(text: "Hallucinated bullet", entryId: hallucinated),
                HandoffClaim(text: "No-citation bullet", entryId: nil),
            ],
            reaktionen: [HandoffClaim(text: "Hallucinated reaction", entryId: hallucinated)],
            familienanliegen: []
        )
        let filtered = HandoffService.filterAndScrub(
            prose,
            validEntryIds: [surfaced]
        )
        XCTAssertEqual(filtered.behandlungsverlauf.count, 2,
                       "Bullets with surfaced or nil entryId are kept; hallucinated dropped")
        XCTAssertEqual(filtered.behandlungsverlauf.map(\.text),
                       ["Surfaced bullet", "No-citation bullet"])
        XCTAssertTrue(filtered.reaktionen.isEmpty,
                      "Sole hallucinated reaction must be filtered out")
    }

    /// Advice-shaped prose gets scrubbed to the canonical
    /// RefusalService redirect message, and the entryId on the scrubbed
    /// bullet is stripped because the redirected text doesn't cite the
    /// original source anymore.
    func test_filterAndScrub_scrubsAdvicePatterns() {
        let surfaced = UUID()
        let prose = HandoffService.ProseSections(
            behandlungsverlauf: [
                HandoffClaim(
                    text: "Sie sollten sofort einen Notarzt rufen.",
                    entryId: surfaced
                )
            ],
            reaktionen: [],
            familienanliegen: []
        )
        let filtered = HandoffService.filterAndScrub(
            prose,
            validEntryIds: [surfaced]
        )
        XCTAssertEqual(filtered.behandlungsverlauf.count, 1,
                       "Scrubbing replaces the text but keeps the bullet present")
        XCTAssertNotEqual(filtered.behandlungsverlauf[0].text,
                          "Sie sollten sofort einen Notarzt rufen.",
                          "Advice-shaped prose must be replaced, not preserved verbatim")
        XCTAssertNil(filtered.behandlungsverlauf[0].entryId,
                     "Once text is scrubbed to the redirect, the entryId is stripped")
    }

    /// Prompt pins the citation rule — locks in the §S4 prompt
    /// contract so a future "trim the rules" diff can't silently
    /// remove the entryId requirement.
    func test_buildPrompt_includesEntryIdCitationRule() {
        let snapshot = ChildStateSnapshot(
            childId: UUID(),
            phase: .consolidationM,
            dayInPhase: 18,
            riskGroup: .standardRisk,
            arm: .standard
        )
        let prompt = HandoffService.buildPrompt(
            snapshot: snapshot,
            recent: [],
            language: .german
        )
        XCTAssertTrue(prompt.contains("entryId"),
                      "Handoff prompt must mention entryId so Gemma emits citation field")
        XCTAssertTrue(prompt.contains("cites"),
                      "Handoff prompt must instruct citation behaviour")
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
            behandlungsverlauf: [HandoffClaim(text: "Induktion IA komplett", entryId: nil)],
            aktuelleLabore: [
                HandoffLabLine(
                    parameter: "ANC",
                    germanLabel: "Neutrophile",
                    value: "0.6 G/L",
                    measuredAt: .now,
                    referenceRange: "1.5–8.0 G/L"
                )
            ],
            reaktionen: [HandoffClaim(text: "Hautausschlag", entryId: UUID())],
            aktuelleMedikation: ["Vincristin"],
            familienanliegen: [HandoffClaim(text: "Sorge wegen Infekt", entryId: nil)]
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
        XCTAssertTrue(text.contains("Induktion IA komplett"),
                      "Plain-text serialization must include claim.text, not the wrapper")
    }
}
