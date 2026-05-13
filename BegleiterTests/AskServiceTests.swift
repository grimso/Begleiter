import XCTest
@testable import Begleiter

final class AskServiceTests: XCTestCase {

    // MARK: - Citation token parsing

    func test_citation_parsesEntryUUID() {
        let uuid = UUID()
        let parsed = Citation.parse("E:\(uuid.uuidString)")
        XCTAssertEqual(parsed, .entry(uuid))
    }

    func test_citation_parsesCorpusChunkId() {
        let parsed = Citation.parse("K:glossary_labs/anc")
        XCTAssertEqual(parsed, .corpus(chunkId: "glossary_labs/anc"))
    }

    func test_citation_rejectsMalformedTokens() {
        XCTAssertNil(Citation.parse(""))
        XCTAssertNil(Citation.parse("not-a-token"))
        XCTAssertNil(Citation.parse("E:"))
        XCTAssertNil(Citation.parse("E:not-a-uuid"))
        XCTAssertNil(Citation.parse("X:glossary_labs/anc"))
        XCTAssertNil(Citation.parse("K:"))
    }

    // MARK: - JSON parsing

    func test_parseAnswer_decodesValidJSON() throws {
        let uuid = UUID()
        let raw = """
        Hier ist die Antwort:
        {
          "claims": [
            { "text": "Vincristin wurde gegeben.", "citations": ["E:\(uuid.uuidString)"] },
            { "text": "Häufige Nebenwirkungen sind Neuropathie.", "citations": ["K:glossary_drugs/vincristine"] }
          ],
          "followUps": [
            "Wie war der ANC-Verlauf?",
            "Welche Nebenwirkungen sind aufgetreten?"
          ]
        }
        """
        let parsed = try AskService.parseAnswer(from: raw)
        XCTAssertEqual(parsed.claims.count, 2)
        XCTAssertEqual(parsed.claims[0].text, "Vincristin wurde gegeben.")
        XCTAssertEqual(parsed.claims[0].citations, [.entry(uuid)])
        XCTAssertEqual(parsed.claims[1].citations, [.corpus(chunkId: "glossary_drugs/vincristine")])
        XCTAssertEqual(parsed.followUps.count, 2)
    }

    func test_parseAnswer_throwsOnMissingJSON() {
        XCTAssertThrowsError(try AskService.parseAnswer(from: "Es tut mir leid, kein JSON.")) { error in
            guard case AskError.modelReturnedNoJSON = error else {
                XCTFail("expected modelReturnedNoJSON, got \(error)")
                return
            }
        }
    }

    func test_parseAnswer_ignoresMalformedCitations() throws {
        let raw = """
        {
          "claims": [
            { "text": "Aussage.", "citations": ["not-a-token", "K:glossary_labs/anc"] }
          ],
          "followUps": []
        }
        """
        let parsed = try AskService.parseAnswer(from: raw)
        XCTAssertEqual(parsed.claims.count, 1)
        // The malformed "not-a-token" should be dropped but the valid one kept.
        XCTAssertEqual(parsed.claims[0].citations, [.corpus(chunkId: "glossary_labs/anc")])
    }

    // MARK: - Verifiable-generation filter

    func test_filterUngrounded_dropsUnknownEntryIds() {
        let valid = UUID()
        let fabricated = UUID()
        let claims = [
            AnswerClaim(text: "valide Aussage", citations: [.entry(valid)]),
            AnswerClaim(text: "erfundene Aussage", citations: [.entry(fabricated)]),
        ]
        let filtered = AskService.filterUngrounded(
            claims: claims,
            validEntryIds: [valid],
            validChunkIds: []
        )
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].text, "valide Aussage")
    }

    func test_filterUngrounded_dropsUnknownCorpusIds() {
        let claims = [
            AnswerClaim(text: "korrekte Quelle", citations: [.corpus(chunkId: "glossary_labs/anc")]),
            AnswerClaim(text: "erfundene Quelle", citations: [.corpus(chunkId: "fake/chunk")]),
        ]
        let filtered = AskService.filterUngrounded(
            claims: claims,
            validEntryIds: [],
            validChunkIds: ["glossary_labs/anc"]
        )
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].text, "korrekte Quelle")
    }

    func test_filterUngrounded_keepsClaimWithMixedCitations() {
        let valid = UUID()
        let fabricated = UUID()
        let claims = [
            AnswerClaim(text: "gemischt", citations: [
                .entry(valid),
                .entry(fabricated),
                .corpus(chunkId: "glossary_labs/anc"),
                .corpus(chunkId: "fake/chunk"),
            ]),
        ]
        let filtered = AskService.filterUngrounded(
            claims: claims,
            validEntryIds: [valid],
            validChunkIds: ["glossary_labs/anc"]
        )
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].citations.count, 2,
                       "fabricated citations should be dropped but valid ones kept")
    }

    func test_filterUngrounded_scrubsAdviceClaimText() {
        let valid = UUID()
        let claims = [
            AnswerClaim(text: "Sie sollten sofort einen Notarzt rufen.", citations: [.entry(valid)]),
        ]
        let filtered = AskService.filterUngrounded(
            claims: claims,
            validEntryIds: [valid],
            validChunkIds: []
        )
        XCTAssertEqual(filtered.count, 1)
        // Per RefusalService.scrubbed: advice text is replaced with the redirect.
        XCTAssertEqual(filtered[0].text, RefusalService.redirectMessage)
    }

    // MARK: - Basis

    func test_computeBasis_journalOnly() {
        let uuid = UUID()
        let claims = [AnswerClaim(text: "x", citations: [.entry(uuid)])]
        XCTAssertEqual(AskService.computeBasis(for: claims), .journal)
    }

    func test_computeBasis_corpusOnly() {
        let claims = [AnswerClaim(text: "x", citations: [.corpus(chunkId: "glossary_labs/anc")])]
        XCTAssertEqual(AskService.computeBasis(for: claims), .corpus)
    }

    func test_computeBasis_both() {
        let uuid = UUID()
        let claims = [
            AnswerClaim(text: "x", citations: [.entry(uuid)]),
            AnswerClaim(text: "y", citations: [.corpus(chunkId: "glossary_labs/anc")]),
        ]
        XCTAssertEqual(AskService.computeBasis(for: claims), .both)
    }

    func test_computeBasis_emptyIsRefusal() {
        XCTAssertEqual(AskService.computeBasis(for: []), .refusal)
        XCTAssertEqual(
            AskService.computeBasis(for: [AnswerClaim(text: "x", citations: [])]),
            .refusal
        )
    }

    // MARK: - Refusal

    func test_refusal_carriesRedirectMessageAndRefusalBasis() {
        let refusal = AskAnswer.refusal(question: "Was bedeutet ANC?")
        XCTAssertEqual(refusal.basis, .refusal)
        XCTAssertEqual(refusal.claims.count, 1)
        XCTAssertEqual(refusal.claims[0].text, RefusalService.redirectMessage)
        XCTAssertTrue(refusal.followUps.isEmpty)
    }

    // MARK: - Suggested starters

    func test_suggestedStarters_differByScope() {
        let all = AskService.suggestedStarters(for: .all)
        let labs = AskService.suggestedStarters(for: .labs)
        XCTAssertGreaterThanOrEqual(all.count, 3)
        XCTAssertGreaterThanOrEqual(labs.count, 3)
        XCTAssertNotEqual(Set(all), Set(labs),
                          "Lab starters should differ from generic starters")
    }

    // MARK: - Prompt

    func test_buildPrompt_includesEntryIdsAndCorpusIds() {
        let entry = JournalEntry(
            entryId: UUID(),
            childId: UUID(),
            visitDate: .now,
            phase: .inductionIA,
            dayInPhase: 1,
            riskGroup: .standardRisk,
            arm: .standard,
            inputModalities: ["text"],
            rawText: "Vincristin gegeben",
            extractedFields: ExtractedFields(
                summary: ConfidenceField(value: "Vincristin gegeben", confidence: 0.9)
            )
        )
        let chunk = CorpusChunk(
            id: "glossary_drugs/vincristine",
            source: .glossaryDrugs,
            topicTags: ["drug"],
            title: "Vincristin",
            text: "Standardchemotherapie.",
            referenceURL: nil,
            updatedAt: "2026-05-13"
        )
        let prompt = AskService.buildPrompt(
            question: "Was ist Vincristin?",
            entries: [entry],
            chunks: [chunk]
        )
        XCTAssertTrue(prompt.contains(entry.entryId.uuidString))
        XCTAssertTrue(prompt.contains(chunk.id))
        XCTAssertTrue(prompt.contains("FRAGE: Was ist Vincristin?"))
        XCTAssertTrue(prompt.contains("REGELN"))
        XCTAssertTrue(prompt.contains("\"claims\""))
        XCTAssertTrue(prompt.contains("\"followUps\""))
    }

    func test_buildPrompt_omitsJournalSectionWhenEmpty() {
        let chunk = CorpusChunk(
            id: "glossary_drugs/vincristine",
            source: .glossaryDrugs,
            topicTags: ["drug"],
            title: "Vincristin",
            text: "Standardchemotherapie.",
            referenceURL: nil,
            updatedAt: "2026-05-13"
        )
        let prompt = AskService.buildPrompt(question: "x", entries: [], chunks: [chunk])
        XCTAssertFalse(prompt.contains("EINTRÄGE AUS DEM JOURNAL"),
                       "Empty journal context should omit the journal section header")
        XCTAssertTrue(prompt.contains("REFERENZKORPUS"))
    }
}
