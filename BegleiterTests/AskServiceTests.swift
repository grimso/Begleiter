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

    func test_citation_parsesDocumentRef() {
        let uuid = UUID()
        let parsed = Citation.parse("D:\(uuid.uuidString)#3")
        XCTAssertEqual(parsed, .document(docId: uuid, chunkIndex: 3))
    }

    func test_citation_rejectsMalformedTokens() {
        XCTAssertNil(Citation.parse(""))
        XCTAssertNil(Citation.parse("not-a-token"))
        XCTAssertNil(Citation.parse("E:"))
        XCTAssertNil(Citation.parse("E:not-a-uuid"))
        XCTAssertNil(Citation.parse("X:glossary_labs/anc"))
        XCTAssertNil(Citation.parse("K:"))
        // Document-specific malformed cases
        XCTAssertNil(Citation.parse("D:"))
        XCTAssertNil(Citation.parse("D:not-a-uuid#0"))
        XCTAssertNil(Citation.parse("D:\(UUID().uuidString)"))      // missing #
        XCTAssertNil(Citation.parse("D:\(UUID().uuidString)#abc"))  // non-int index
        XCTAssertNil(Citation.parse("D:\(UUID().uuidString)#-1"))   // negative index
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
        XCTAssertTrue(prompt.contains("QUESTION: Was ist Vincristin?"))
        XCTAssertTrue(prompt.contains("Rules:"))
        XCTAssertTrue(prompt.contains("\"claims\""))
        XCTAssertTrue(prompt.contains("\"followUps\""))
    }

    /// English control prompt with German output. Required clauses:
    /// JSON-only directive, German-output directive, no-invent rule,
    /// no-advice rule. Also assert the EventQuestionDetector handoff —
    /// the prompt no longer carries the long "Quellenwahl" rule, so
    /// the load-bearing safety net is the Swift-side guard plus the
    /// "no entry matches → reply with empty citations" line below.
    func test_buildPrompt_includesEnglishControlClauses() {
        let prompt = AskService.buildPrompt(question: "x", entries: [], chunks: [])
        XCTAssertTrue(prompt.contains("JSON only"),
                      "single-shot prompt must enforce JSON-only output")
        XCTAssertTrue(prompt.contains("plain German"),
                      "single-shot prompt must direct German output")
        XCTAssertTrue(prompt.contains("Never invent"),
                      "single-shot prompt must carry the no-hallucination rule")
        XCTAssertTrue(prompt.contains("No advice"),
                      "single-shot prompt must carry the safety rule")
        XCTAssertTrue(prompt.contains("Im Journal finde ich dazu keinen Eintrag."),
                      "the canonical event-question refusal text must be quoted exactly so the model copies it verbatim")
    }

    /// Budget guard. Static (boilerplate) char count when called with
    /// empty inputs must stay under 1 200 chars (~300 tokens). If a
    /// future change makes the prompt longer, this test fails before
    /// the prefill regression reaches users.
    func test_buildPrompt_staticSizeBelowBudget() {
        let prompt = AskService.buildPrompt(question: "", entries: [], chunks: [])
        XCTAssertLessThan(prompt.count, 1200,
                          "single-shot static prompt size budget: 1 200 chars")
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
        XCTAssertFalse(prompt.contains("JOURNAL ENTRIES:"),
                       "Empty journal context should omit the journal section header")
        XCTAssertTrue(prompt.contains("REFERENCE CORPUS"))
    }

    /// Timeline pack story: when AskService passes 12 entries to
    /// buildPrompt, the prompt must include every entry id (not a top-4
    /// subset). Locks in the S2 fix — old code path silently dropped
    /// entries 5 through 12 via `.prefix(4)`.
    func test_buildPrompt_withTimelinePack_includesAllEntries() {
        let entries = (0..<12).map { idx in
            JournalEntry(
                entryId: UUID(),
                childId: UUID(),
                visitDate: Calendar(identifier: .gregorian)
                    .date(byAdding: .day, value: -idx, to: Date()) ?? Date(),
                phase: .consolidationM,
                dayInPhase: 1,
                riskGroup: .standardRisk,
                arm: .standard,
                inputModalities: ["text"],
                rawText: nil,
                extractedFields: ExtractedFields(
                    summary: ConfidenceField(value: "Eintrag-\(idx)", confidence: 0.9)
                )
            )
        }
        let prompt = AskService.buildPrompt(question: "x", entries: entries, chunks: [])
        for entry in entries {
            XCTAssertTrue(
                prompt.contains(entry.entryId.uuidString),
                "Prompt must include every entry's UUID — entry \(entry.entryId) missing"
            )
        }
        XCTAssertTrue(prompt.contains("[ENTRY 12]"),
                      "Prompt must enumerate all 12 entries, not just the first 4")
    }

    /// When the timeline pack drops older entries, AskService passes an
    /// `omittedMarker` to buildPrompt. The marker must surface inside
    /// the JOURNAL ENTRIES block so the model knows it's looking at a
    /// window, not the full journal.
    func test_buildPrompt_withOmittedMarker_includesMarkerAboveEntries() {
        let entry = JournalEntry(
            entryId: UUID(),
            childId: UUID(),
            visitDate: .now,
            phase: .consolidationM,
            dayInPhase: 1,
            riskGroup: .standardRisk,
            arm: .standard,
            inputModalities: ["text"],
            rawText: nil,
            extractedFields: .empty
        )
        let marker = "NOTE: 5 earlier journal entries from 2026-01-01 to 2026-02-01 were omitted from this pack."
        let prompt = AskService.buildPrompt(
            question: "x",
            entries: [entry],
            chunks: [],
            omittedMarker: marker
        )
        XCTAssertTrue(prompt.contains(marker), "Omitted marker must appear in the prompt")
        // Marker should precede the entry block: the marker's position
        // must be less than the first [ENTRY n] position.
        guard let markerRange = prompt.range(of: marker),
              let entryRange = prompt.range(of: "[ENTRY 1]") else {
            XCTFail("Marker and entry block must both be present")
            return
        }
        XCTAssertLessThan(markerRange.lowerBound, entryRange.lowerBound,
                          "Omitted marker must precede the entry blocks so the model reads the window note first")
    }

    /// Existing call sites that don't pass `omittedMarker` keep the
    /// previous byte shape — no leading "NOTE:" line creeps into the
    /// prompt when entries fit entirely.
    func test_buildPrompt_withoutOmittedMarker_hasNoNoteLine() {
        let entry = JournalEntry(
            entryId: UUID(),
            childId: UUID(),
            visitDate: .now,
            phase: .consolidationM,
            dayInPhase: 1,
            riskGroup: .standardRisk,
            arm: .standard,
            inputModalities: ["text"],
            rawText: nil,
            extractedFields: .empty
        )
        let prompt = AskService.buildPrompt(question: "x", entries: [entry], chunks: [])
        XCTAssertFalse(prompt.contains("NOTE:"),
                       "Prompt must not include a NOTE marker when omittedMarker is nil")
    }

    /// The timeline-pack story relies on the model knowing the entries
    /// are listed chronologically (recent at the bottom). Pin the rule.
    func test_buildPrompt_includesChronologicalRule() {
        let prompt = AskService.buildPrompt(question: "x", entries: [], chunks: [])
        XCTAssertTrue(prompt.contains("chronologically"),
                      "Prompt must instruct the model on the timeline pack's ordering")
        XCTAssertTrue(prompt.contains("oldest"),
                      "Prompt must spell out the oldest → newest direction")
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
        XCTAssertTrue(out.documents.isEmpty)
    }

    func test_extractSurfacedIds_pullsDocumentRefs() {
        let docA = UUID()
        let docB = UUID()
        let toolResult = """
        Treffer (2):
        [D:\(docA.uuidString)#0] Entlassungsbericht UKE · befund: ANC 0.4 …
        [D:\(docB.uuidString)#7] Onkologie 2026-03-22 · medikation: Methotrexat 5 g/m²
        """
        let out = AskService.extractSurfacedIds(from: toolResult)
        XCTAssertEqual(out.documents, [
            DocumentChunkRef(docId: docA, chunkIndex: 0),
            DocumentChunkRef(docId: docB, chunkIndex: 7),
        ])
    }

    func test_extractSurfacedIds_dropsMalformedDocumentRef() {
        let goodDoc = UUID()
        let toolResult = """
        [D:not-a-uuid#0] junk
        [D:\(goodDoc.uuidString)] missing-hash junk
        [D:\(goodDoc.uuidString)#abc] non-int junk
        [D:\(goodDoc.uuidString)#5] ok
        """
        let out = AskService.extractSurfacedIds(from: toolResult)
        XCTAssertEqual(out.documents, [
            DocumentChunkRef(docId: goodDoc, chunkIndex: 5),
        ])
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
        XCTAssertTrue(instructions.contains("Tool budget exhausted"),
                      "force-final turn must tell the model to stop calling tools")
    }

    // MARK: - Filter extension for documents

    func test_filterAndWarn_dropsUnknownDocumentRefsKeepsClaim() {
        let validDoc = UUID()
        let fabricatedDoc = UUID()
        let claims = [
            AnswerClaim(text: "ok",        citations: [.document(docId: validDoc, chunkIndex: 1)]),
            AnswerClaim(text: "erfunden",  citations: [.document(docId: fabricatedDoc, chunkIndex: 0)]),
        ]
        let outcome = AskService.filterAndWarn(
            claims: claims,
            validEntryIds: [],
            validChunkIds: [],
            validDocumentRefs: [DocumentChunkRef(docId: validDoc, chunkIndex: 1)]
        )
        XCTAssertEqual(outcome.claims.count, 2)
        XCTAssertEqual(outcome.claims[0].citations,
                       [.document(docId: validDoc, chunkIndex: 1)])
        XCTAssertTrue(outcome.claims[1].citations.isEmpty)
        XCTAssertEqual(outcome.droppedCitations, 1)
    }

    func test_computeBasis_documentOnly() {
        let claims = [
            AnswerClaim(text: "x", citations: [.document(docId: UUID(), chunkIndex: 0)]),
        ]
        XCTAssertEqual(AskService.computeBasis(for: claims), .document)
    }

    func test_computeBasis_journalPlusDocument_returnsBoth() {
        let claims = [
            AnswerClaim(text: "a", citations: [.entry(UUID())]),
            AnswerClaim(text: "b", citations: [.document(docId: UUID(), chunkIndex: 0)]),
        ]
        XCTAssertEqual(AskService.computeBasis(for: claims), .both)
    }

    // MARK: - Stretch A: JSON tool declaration block

    /// Reviewer's recommendation: inject Gemma's tool declaration as a
    /// machine-readable block. We use OpenAI-shaped JSON (no
    /// speculative tag invention) because the model has seen this
    /// format in training. The output must be deterministic so a diff
    /// on the rendered prompt is human-readable, and so test fixtures
    /// can compare strings.
    func test_formatDeclarationBlock_isDeterministic() {
        let agentTools = AgentTools(
            retrieval: RetrievalService(),
            corpus: CorpusService.shared,
            entries: [],
            importedDocs: []
        )
        let first = AskService.formatDeclarationBlock(agentTools.schemas)
        let second = AskService.formatDeclarationBlock(agentTools.schemas)
        XCTAssertEqual(first, second,
                       "JSON declaration block must be byte-equal across renders")
        XCTAssertTrue(first.contains("\"type\""),
                      "block must include the OpenAI function-schema marker")
        XCTAssertTrue(first.contains("search_journal"),
                      "block must include each tool's name")
        XCTAssertTrue(first.contains("search_documents"),
                      "block must include the new search_documents tool")
        XCTAssertTrue(first.contains("```json"),
                      "block must be fenced as a JSON code block")
    }

    func test_buildCustomAgentSystemPrompt_carriesJSONDeclarationBlock() {
        let schemas = AgentTools(
            retrieval: RetrievalService(),
            corpus: CorpusService.shared,
            entries: [],
            importedDocs: []
        ).schemas
        let prompt = AskService.buildCustomAgentSystemPrompt(
            scope: .all,
            schemas: schemas
        )
        XCTAssertTrue(prompt.contains("Available tools (schema"),
                      "system prompt must label the declaration block")
        XCTAssertTrue(prompt.contains("search_documents"),
                      "5th tool must be advertised in the system prompt")
        XCTAssertTrue(prompt.contains("[D:<UUID>#<idx>]"),
                      "citation format for documents must be specified")
    }

    /// English control prompt; German output. Load-bearing clauses for
    /// the demo-critical agent prompt.
    func test_buildCustomAgentSystemPrompt_includesEnglishControlClauses() {
        let schemas = AgentTools(
            retrieval: RetrievalService(),
            corpus: CorpusService.shared,
            entries: [],
            importedDocs: []
        ).schemas
        let prompt = AskService.buildCustomAgentSystemPrompt(
            scope: .all,
            schemas: schemas
        )
        XCTAssertTrue(prompt.contains("Output in German"),
                      "custom-agent prompt must direct German output explicitly")
        XCTAssertTrue(prompt.contains("Never invent UUIDs"),
                      "custom-agent prompt must carry the no-hallucination citation rule")
        XCTAssertTrue(prompt.contains("No advice, diagnosis"),
                      "custom-agent prompt must carry the safety rule")
        XCTAssertTrue(prompt.contains("Max 4 calls"),
                      "tool-call budget must be stated up front")
        XCTAssertTrue(prompt.contains("<|tool_call>"),
                      "native Gemma tool-loop framing must remain advertised")
    }

    /// Budget guard. Static (boilerplate) size — excluding the JSON
    /// declaration block which is data-dependent — must stay under
    /// 2 400 chars (~600 tokens). The combined prompt including JSON
    /// is roughly ~3 500 chars but JSON is informationally dense and
    /// the token count comes in lower than chars suggest.
    func test_buildCustomAgentSystemPrompt_staticSizeBelowBudget() {
        let schemas = AgentTools(
            retrieval: RetrievalService(),
            corpus: CorpusService.shared,
            entries: [],
            importedDocs: []
        ).schemas
        let prompt = AskService.buildCustomAgentSystemPrompt(
            scope: .all,
            schemas: schemas
        )
        // Subtract the JSON declaration block to measure only the
        // hand-written prose budget; the JSON is its own contract
        // verified by `test_formatDeclarationBlock_isDeterministic`.
        let declaration = AskService.formatDeclarationBlock(schemas)
        let proseSize = prompt.count - declaration.count
        XCTAssertLessThan(proseSize, 2400,
                          "custom-agent prose prompt size budget: 2 400 chars (excluding JSON declaration)")
    }
}
