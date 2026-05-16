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

    // MARK: - Filter + warn (warn-don't-replace)

    func test_filterAndWarn_dropsUnknownEntryCitationsKeepsClaim() {
        let valid = UUID()
        let fabricated = UUID()
        let claims = [
            AnswerClaim(text: "valide Aussage", citations: [.entry(valid)]),
            AnswerClaim(text: "erfundene Aussage", citations: [.entry(fabricated)]),
        ]
        let outcome = AskService.filterAndWarn(
            claims: claims,
            validEntryIds: [valid],
            validChunkIds: []
        )
        // Both claims survive; texts preserved.
        XCTAssertEqual(outcome.claims.count, 2)
        XCTAssertEqual(outcome.claims[0].text, "valide Aussage")
        XCTAssertEqual(outcome.claims[0].citations, [.entry(valid)])
        XCTAssertEqual(outcome.claims[1].text, "erfundene Aussage")
        XCTAssertTrue(outcome.claims[1].citations.isEmpty,
                      "fabricated citations should be dropped from the claim")
        XCTAssertEqual(outcome.droppedCitations, 1)
        // Mixed survival → partialCitations rather than noCitations.
        XCTAssertTrue(outcome.warnings.contains(.partialCitations))
    }

    func test_filterAndWarn_dropsUnknownCorpusCitations() {
        let claims = [
            AnswerClaim(text: "korrekte Quelle", citations: [.corpus(chunkId: "glossary_labs/anc")]),
            AnswerClaim(text: "erfundene Quelle", citations: [.corpus(chunkId: "fake/chunk")]),
        ]
        let outcome = AskService.filterAndWarn(
            claims: claims,
            validEntryIds: [],
            validChunkIds: ["glossary_labs/anc"]
        )
        XCTAssertEqual(outcome.claims.count, 2)
        XCTAssertEqual(outcome.claims[0].citations, [.corpus(chunkId: "glossary_labs/anc")])
        XCTAssertTrue(outcome.claims[1].citations.isEmpty)
        XCTAssertEqual(outcome.droppedCitations, 1)
        XCTAssertTrue(outcome.warnings.contains(.partialCitations))
    }

    func test_filterAndWarn_allCitationsFabricated_emitsNoCitationsWarning() {
        let claims = [
            AnswerClaim(text: "Aussage 1", citations: [.corpus(chunkId: "fake/a")]),
            AnswerClaim(text: "Aussage 2", citations: [.corpus(chunkId: "fake/b")]),
        ]
        let outcome = AskService.filterAndWarn(
            claims: claims,
            validEntryIds: [],
            validChunkIds: ["glossary_labs/anc"]
        )
        // Claims preserved with empty citations.
        XCTAssertEqual(outcome.claims.count, 2)
        XCTAssertTrue(outcome.claims.allSatisfy { $0.citations.isEmpty })
        XCTAssertTrue(outcome.warnings.contains(.noCitations),
                      ".noCitations fires when every citation was a fabrication")
    }

    func test_filterAndWarn_keepsClaimWithMixedCitations() {
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
        let outcome = AskService.filterAndWarn(
            claims: claims,
            validEntryIds: [valid],
            validChunkIds: ["glossary_labs/anc"]
        )
        XCTAssertEqual(outcome.claims.count, 1)
        XCTAssertEqual(outcome.claims[0].citations.count, 2,
                       "fabricated citations dropped, valid kept")
        XCTAssertEqual(outcome.droppedCitations, 2)
    }

    func test_filterAndWarn_preservesAdviceClaimTextAndEmitsWarning() {
        let valid = UUID()
        let adviceText = "Sie sollten sofort einen Notarzt rufen."
        let claims = [
            AnswerClaim(text: adviceText, citations: [.entry(valid)]),
        ]
        let outcome = AskService.filterAndWarn(
            claims: claims,
            validEntryIds: [valid],
            validChunkIds: []
        )
        XCTAssertEqual(outcome.claims.count, 1)
        // WARN, DON'T REPLACE — the claim text stays verbatim.
        XCTAssertEqual(outcome.claims[0].text, adviceText)
        XCTAssertTrue(outcome.warnings.contains(.adviceDrift),
                      "advice-pattern match emits a warning rather than scrubbing the text")
    }

    func test_filterAndWarn_modelReturnedNoCitationsAtAll() {
        let claims = [
            AnswerClaim(text: "Aussage ohne Citations", citations: []),
        ]
        let outcome = AskService.filterAndWarn(
            claims: claims,
            validEntryIds: [],
            validChunkIds: []
        )
        XCTAssertEqual(outcome.claims.count, 1)
        XCTAssertTrue(outcome.warnings.contains(.noCitations),
                      "answer text without any citations is preserved with a warning")
    }

    func test_filterUngrounded_backCompat_returnsClaimsOnly() {
        // The old API is preserved for legacy callers; the new semantics
        // mean it no longer drops claims for missing citations.
        let valid = UUID()
        let claims = [
            AnswerClaim(text: "ok", citations: [.entry(valid)]),
            AnswerClaim(text: "fabricated", citations: [.entry(UUID())]),
        ]
        let filtered = AskService.filterUngrounded(
            claims: claims,
            validEntryIds: [valid],
            validChunkIds: []
        )
        XCTAssertEqual(filtered.count, 2)
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

    // MARK: - Refusal helpers

    func test_refusal_carriesRedirectMessageAndRefusalReason() {
        let refusal = AskAnswer.refusal(question: "Was bedeutet ANC?", reason: .emptyRetrieval)
        XCTAssertEqual(refusal.basis, .refusal)
        XCTAssertEqual(refusal.claims.count, 1)
        XCTAssertEqual(refusal.claims[0].text, RefusalService.redirectMessage)
        XCTAssertTrue(refusal.followUps.isEmpty)
        XCTAssertEqual(refusal.debug.refusalReason, .emptyRetrieval)
    }

    func test_refusal_eachReasonRoundtripsThroughDebugInfo() {
        for reason in [
            RefusalReason.emptyRetrieval,
            .modelError,
            .parseFailure,
            .emptyClaims,
        ] {
            let answer = AskAnswer.refusal(question: "x", reason: reason)
            XCTAssertEqual(answer.debug.refusalReason, reason)
        }
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

    // MARK: - Surfaced-IDs scan (custom-agent citation universe)

    /// Tool outputs always emit `[E:<UUID>]` for journal hits and
    /// `[K:<chunkId>]` for corpus hits. The custom-agent loop scans
    /// each tool result for those markers so the verifiable-generation
    /// filter validates against IDs *actually surfaced this
    /// conversation* — not the static universe of every entry +
    /// every bundled corpus chunk.
    func test_extractSurfacedIds_pullsBothMarkerKinds() {
        let entryA = UUID()
        let entryB = UUID()
        let toolResult = """
        Treffer (2):
        [E:\(entryA.uuidString)] 2026-04-12 · Induktion IA · ANC 0.4
        [E:\(entryB.uuidString)] 2026-04-15 · Induktion IA · Methotrexat
        [K:glossary_drugs/methotrexate] Methotrexat: Standard.
        """
        let out = AskService.extractSurfacedIds(from: toolResult)
        XCTAssertEqual(out.entries, [entryA, entryB])
        XCTAssertEqual(out.chunks, ["glossary_drugs/methotrexate"])
    }

    func test_extractSurfacedIds_dropsMalformedUUID() {
        let toolResult = "[E:not-a-uuid] junk [K:glossary_labs/anc] ok"
        let out = AskService.extractSurfacedIds(from: toolResult)
        XCTAssertTrue(out.entries.isEmpty,
                      "malformed UUID payload must not pollute the surfaced set")
        XCTAssertEqual(out.chunks, ["glossary_labs/anc"])
    }

    func test_extractSurfacedIds_emptyTextReturnsEmptySets() {
        let out = AskService.extractSurfacedIds(from: "")
        XCTAssertTrue(out.entries.isEmpty)
        XCTAssertTrue(out.chunks.isEmpty)
    }

    func test_extractSurfacedIds_dedupsRepeatedMarkers() {
        let uuid = UUID()
        let toolResult = """
        [E:\(uuid.uuidString)] erste Erwähnung
        [E:\(uuid.uuidString)] zweite Erwähnung
        [K:foo] [K:foo]
        """
        let out = AskService.extractSurfacedIds(from: toolResult)
        XCTAssertEqual(out.entries.count, 1)
        XCTAssertEqual(out.chunks, ["foo"])
    }

    // MARK: - Custom-agent transcript framing

    /// When the loop has already dispatched tools, each completed turn
    /// is re-injected wrapped in Gemma 4's native
    /// `<|tool_call>…<tool_call|>` / `<|tool_response>…<tool_response|>`
    /// framing so the model sees its own emit format reflected back
    /// instead of the previous prose form. The extractor strips the
    /// wrappers on input (see `GemmaToolCallExtractorTests`), so the
    /// round-trip is safe.
    func test_buildCustomAgentInstructions_includesNativeFraming() {
        let call = GemmaToolCallExtractor.Call(
            name: "search_journal",
            arguments: ["query": .string("Asparaginase-Reaktion")]
        )
        let toolCallWrapped = GemmaToolCallExtractor.format(call)
        let toolResponseWrapped = GemmaToolCallExtractor.formatResponse(
            "Keine Treffer."
        )
        let transcript = ["\(toolCallWrapped)\n\(toolResponseWrapped)"]
        let instructions = AskService.buildCustomAgentInstructions(
            base: "BASE",
            transcript: transcript,
            forceFinal: false
        )
        XCTAssertTrue(instructions.contains("<|tool_call>"),
                      "transcript turn must surface the native tool-call wrapper")
        XCTAssertTrue(instructions.contains("<|tool_response>"),
                      "transcript turn must surface the native tool-response wrapper")
        XCTAssertTrue(instructions.contains("call:search_journal"))
    }

    func test_buildCustomAgentInstructions_forceFinalAddsBudgetWarning() {
        let instructions = AskService.buildCustomAgentInstructions(
            base: "BASE",
            transcript: [],
            forceFinal: true
        )
        XCTAssertTrue(instructions.contains("Werkzeug-Budget"),
                      "force-final turn must tell the model to stop calling tools")
    }
}
