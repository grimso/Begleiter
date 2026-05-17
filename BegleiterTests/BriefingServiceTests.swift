import XCTest
@testable import Begleiter

final class BriefingServiceTests: XCTestCase {

    private func entry(
        id: UUID = UUID(),
        text: String = "x",
        summary: String? = nil,
        dayInPhase: Int = 1
    ) -> JournalEntry {
        JournalEntry(
            entryId: id,
            childId: UUID(),
            visitDate: .now,
            phase: .inductionIA,
            dayInPhase: dayInPhase,
            riskGroup: .standardRisk,
            arm: .standard,
            inputModalities: ["text"],
            rawText: text,
            extractedFields: ExtractedFields(
                summary: summary.map { ConfidenceField(value: $0, confidence: 0.9) }
            )
        )
    }

    private func snapshot(phase: Phase = .inductionIA, day: Int = 12) -> ChildStateSnapshot {
        ChildStateSnapshot(
            childId: UUID(),
            phase: phase,
            dayInPhase: day,
            riskGroup: .standardRisk,
            arm: .standard
        )
    }

    // MARK: - Prompt construction

    func test_buildPrompt_includesEntryIdsAndPhaseLabel() {
        let id1 = UUID()
        let id2 = UUID()
        let entries = [
            entry(id: id1, summary: "Vincristin OK"),
            entry(id: id2, summary: "ANC 0.6"),
        ]
        let prompt = BriefingService.buildPrompt(
            visitDate: .now,
            child: snapshot(),
            entries: entries
        )
        XCTAssertTrue(prompt.contains(id1.uuidString))
        XCTAssertTrue(prompt.contains(id2.uuidString))
        XCTAssertTrue(prompt.contains("Vincristin OK"))
        XCTAssertTrue(prompt.contains("Induktion (Protokoll IA)"))
    }

    func test_buildPrompt_includesPhaseDrugList() {
        let prompt = BriefingService.buildPrompt(
            visitDate: .now,
            child: snapshot(phase: .inductionIA),
            entries: [entry(summary: "x")]
        )
        // Should mention at least one of IA's canonical drugs.
        let iaDrugs = ["Vincristin", "PEG-Asparaginase", "Daunorubicin", "Prednison"]
        XCTAssertTrue(iaDrugs.contains { prompt.contains($0) },
                      "Prompt should list at least one canonical IA drug")
    }

    /// English control prompt; German output. Load-bearing clauses.
    func test_buildPrompt_includesEnglishControlClauses() {
        let prompt = BriefingService.buildPrompt(
            visitDate: .now,
            child: snapshot(),
            entries: [entry(summary: "x")]
        )
        XCTAssertTrue(prompt.contains("JSON only"))
        XCTAssertTrue(prompt.contains("German"),
                      "briefing prompt must direct German JSON values")
        XCTAssertTrue(prompt.contains("Never invent"))
        XCTAssertTrue(prompt.contains("No advice"))
    }

    /// Budget guard. Static (boilerplate) size with no entries must
    /// stay under 1 700 chars. The default snapshot is inductionIA;
    /// PhaseMetadata.for(.inductionIA) embeds the IA drug list +
    /// typical parent concerns into the "static" frame, which lifts
    /// the floor above the pure-prose 1 300 char target.
    func test_buildPrompt_staticSizeBelowBudget() {
        let prompt = BriefingService.buildPrompt(
            visitDate: Date(timeIntervalSince1970: 0),
            child: snapshot(),
            entries: []
        )
        XCTAssertLessThan(prompt.count, 1700,
                          "briefing static prompt size budget: 1 700 chars (inductionIA snapshot)")
    }

    // MARK: - Verifiable-generation guard

    func test_filterUngroundedClaims_dropsUnknownEntryIds() {
        let validId = UUID()
        let unknownId = UUID()
        let briefing = Briefing(
            targetDate: .now,
            aktuellerStand: BriefingClaim(text: "Phase IA Tag 12", entryId: validId),
            seitDemLetztenTermin: [
                BriefingClaim(text: "valid claim", entryId: validId),
                BriefingClaim(text: "fabricated claim", entryId: unknownId),
                BriefingClaim(text: "from state machine", entryId: nil),
            ],
            offenePunkte: [
                BriefingClaim(text: "fabricated open", entryId: unknownId),
            ],
            fragenVorschlaege: ["Frage 1"],
            mitzunehmen: ["Heparin"]
        )
        let filtered = BriefingService.filterUngroundedClaims(briefing, validEntryIds: [validId])
        XCTAssertEqual(filtered.seitDemLetztenTermin.count, 2,
                       "Valid + nil-entryId claims should be kept, fabricated dropped")
        XCTAssertTrue(filtered.seitDemLetztenTermin.contains {
            $0.text == "valid claim"
        })
        XCTAssertTrue(filtered.seitDemLetztenTermin.contains {
            $0.text == "from state machine"
        })
        XCTAssertTrue(filtered.offenePunkte.isEmpty)
    }

    func test_filterUngroundedClaims_aktuellerStand_unknownIdStripsId() {
        let validId = UUID()
        let unknownId = UUID()
        let briefing = Briefing(
            targetDate: .now,
            aktuellerStand: BriefingClaim(text: "header", entryId: unknownId),
            seitDemLetztenTermin: [],
            offenePunkte: [],
            fragenVorschlaege: [],
            mitzunehmen: []
        )
        let filtered = BriefingService.filterUngroundedClaims(briefing, validEntryIds: [validId])
        // Keeps the text but strips the bogus entryId so the UI doesn't show
        // a broken citation chip.
        XCTAssertEqual(filtered.aktuellerStand.text, "header")
        XCTAssertNil(filtered.aktuellerStand.entryId)
    }

    // MARK: - JSON parsing

    func test_parseBriefing_decodesValidJSON() throws {
        let id = UUID()
        let json = """
        {
          "targetDate": "2026-05-12T00:00:00Z",
          "aktuellerStand": {"text": "Phase IA Tag 12", "entryId": "\(id.uuidString)"},
          "seitDemLetztenTermin": [],
          "offenePunkte": [],
          "fragenVorschlaege": ["Frage A"],
          "mitzunehmen": ["Pass"]
        }
        """
        let briefing = try BriefingService.parseBriefing(from: json, visitDate: .now)
        XCTAssertEqual(briefing.aktuellerStand.text, "Phase IA Tag 12")
        XCTAssertEqual(briefing.aktuellerStand.entryId, id)
        XCTAssertEqual(briefing.fragenVorschlaege, ["Frage A"])
    }

    func test_parseBriefing_throwsOnMissingJSON() {
        XCTAssertThrowsError(try BriefingService.parseBriefing(from: "kein JSON", visitDate: .now))
    }
}
